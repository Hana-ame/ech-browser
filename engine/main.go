// ech-browser 是「点开即用」的通用 ECH 独立浏览器：flutter+webview 做外壳，
// go 内核（本 engine）在 webview 拦截层背后按 Host 全自动做 ECH/分片TLS/SNI 伪装直连。
// 可访问**任意 http(s) 网址**：无需修改系统 hosts、无需手动安装证书
// （webview 永远只与本地回环代理打交道；上游 TLS 由 go 内核用系统信任根完成）。
//
// 本文件是 go 内核的 c-shared 入口，导出面与 Flutter FFI 契约保持一致（12 个 export）：
//
//   ECHSetDohURL / ECHInit / ECHInitWithBootstrap / ECHInitReady /
//   ECHInitLastError / ECHGetLogCount / ECHGetLog / FreeCString
//   StartProxy / StopProxy / GetProxyPort / IsEchReady
//
// 监听形态：只提供**明文 HTTP**，绑定 127.0.0.1（回环，优先 8443，占用则随机）。
// 回环地址无需 TLS；Dart 侧拦截桥把原始 URL 改写为 http://127.0.0.1:<port>/…，
// 并保留原始 Host 头及 X-ECH-Scheme 头，本内核按 Host 与协议路由上游。

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	cloudflare_ech "github.com/Hana-ame/ech-browser/engine/ech"
	"github.com/Hana-ame/ech-browser/engine/netdial"
)

//go:embed status.html
var statusHTML string

const (
	defaultDohHost   = "moonchan.xyz"
	defaultDohURL    = "https://moonchan.xyz/doh"
	maxBufferedBody  = 16 << 20 // 16 MiB 请求体缓冲上限（支持 POST/PUT/PATCH 回退重试）
)

// ─── 状态 ────────────────────────────────────────────────────────────────────

var (
	initMu   sync.Mutex
	initing  bool
	initDone atomic.Bool
	initErr  atomic.Value

	proxyMu     sync.Mutex
	proxyServer *http.Server
	proxyPort   uint16
	echReady    bool
	// proxyGen：每次 StartProxy 进入 / StopProxy 各递增。
	proxyGen uint64

	logMu       sync.RWMutex
	logBuffer   []string
	maxLogLines = 500
)

// hopByHop 逐跳头只描述"上一跳到下一跳"，绝不能转发给客户端连接。
var hopByHop = map[string]bool{
	"Connection":          true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
	"X-Ech-Scheme":        true,
}

type logWriter struct{}

var kernelLogPathOnce sync.Once
var kernelLogPath string

// kernelLogFilePath 返回持久化日志路径（~/.ech-browser/kernel.log）。
// 闪退/abort 后进程内环形缓冲会一起消失，落盘日志是唯一可回传的证据。
func kernelLogFilePath() string {
	kernelLogPathOnce.Do(func() {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return
		}
		dir := filepath.Join(home, ".ech-browser")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return
		}
		kernelLogPath = filepath.Join(dir, "kernel.log")
	})
	return kernelLogPath
}

func (w *logWriter) Write(p []byte) (int, error) {
	line := strings.TrimRight(string(p), "\n")
	fmt.Fprintln(os.Stderr, line)
	if os.Getenv("ECH_NO_LOGFILE") != "1" {
		if path := kernelLogFilePath(); path != "" {
		// 简单轮转：超过 4 MiB 备份为 .1 再重开
		if fi, err := os.Stat(path); err == nil && fi.Size() > 4<<20 {
			_ = os.Rename(path, path+".1")
		}
		if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, _ = f.WriteString(line + "\n")
			_ = f.Close()
		}
		}
	}
	logMu.Lock()
	logBuffer = append(logBuffer, line)
	if len(logBuffer) > maxLogLines {
		logBuffer = logBuffer[len(logBuffer)-maxLogLines:]
	}
	logMu.Unlock()
	return len(p), nil
}

func init() {
	log.SetOutput(&logWriter{})
	log.SetFlags(log.Ltime | log.Lmicroseconds)
}

// guardPanic：所有 cgo 导出入口都必须包一层——Go panic 无法被 C/Dart 捕获，
// 会直接 abort 整个进程。配合命名返回值：panic 回滚时未赋值的命名结果为零值。
func guardPanic(where string) {
	if r := recover(); r != nil {
		log.Printf("PANIC in %s: %v\n%s", where, r, debug.Stack())
	}
}

// ─── ECH 初始化接口（Dart proxy_manager 依赖）─────────────────────────────

//export ECHSetDohURL
func ECHSetDohURL(url *C.char) {
	defer guardPanic("ECHSetDohURL")
	cloudflare_ech.SetDohURL(C.GoString(url))
}

//export ECHInit
func ECHInit() {
	defer guardPanic("ECHInit")
	if initDone.Load() {
		return
	}
	initMu.Lock()
	if initDone.Load() || initing {
		initMu.Unlock()
		return
	}
	initing = true
	initMu.Unlock()

	log.Printf("ECHInit: starting goroutine")
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in ECHInit goroutine: %v\n%s", r, debug.Stack())
				initErr.Store(fmt.Sprintf("panic: %v", r))
				initMu.Lock()
				initing = false
				initMu.Unlock()
			}
		}()
		if err := cloudflare_ech.InitDefault(); err != nil {
			log.Printf("ECHInit error: %v", err)
			initErr.Store(err.Error())
			initMu.Lock()
			initing = false
			initMu.Unlock()
			return
		}
		initErr.Store("")
		initDone.Store(true)
		initMu.Lock()
		initing = false
		initMu.Unlock()
		log.Printf("ECHInit: success")
	}()
}

//export ECHInitWithBootstrap
func ECHInitWithBootstrap(cHost, cIP *C.char) {
	defer guardPanic("ECHInitWithBootstrap")
	host := C.GoString(cHost)
	ip := C.GoString(cIP)
	if host != "" {
		cloudflare_ech.SetDoHConfig(host, ip)
	}
	ECHInit()
}

//export ECHInitReady
func ECHInitReady() (ret C.int) {
	defer guardPanic("ECHInitReady")
	if initDone.Load() {
		return 1
	}
	if v := initErr.Load(); v != nil {
		if s, ok := v.(string); ok && s != "" {
			return -1
		}
	}
	return 0
}

//export ECHInitLastError
func ECHInitLastError() (out *C.char) {
	defer guardPanic("ECHInitLastError")
	if v := initErr.Load(); v != nil {
		s, ok := v.(string)
		if !ok || s == "" {
			return nil
		}
		return C.CString(s)
	}
	return nil
}

// ─── 日志接口 ────────────────────────────────────────────────────────────────

//export ECHGetLogCount
func ECHGetLogCount() (ret C.int) {
	defer guardPanic("ECHGetLogCount")
	logMu.RLock()
	n := len(logBuffer)
	logMu.RUnlock()
	return C.int(n)
}

//export ECHGetLog
func ECHGetLog(i C.int) (out *C.char) {
	defer guardPanic("ECHGetLog")
	logMu.RLock()
	defer logMu.RUnlock()
	n := int(i)
	if n < 0 || n >= len(logBuffer) {
		return nil
	}
	return C.CString(logBuffer[n])
}

//export FreeCString
func FreeCString(s *C.char) {
	defer guardPanic("FreeCString")
	if s == nil {
		return
	}
	C.free(unsafe.Pointer(s))
}

// ─── 代理启停接口 ────────────────────────────────────────────────────────────

//export StartProxy
func StartProxy(bootstrapIP *C.char) (port uint16) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in StartProxy: %v\n%s", r, debug.Stack())
			port = 0
		}
	}()

	// ── 阶段 0：清状态 + 领代号（持锁，瞬时）──────────────────────────
	proxyMu.Lock()
	proxyGen++
	myGen := proxyGen

	logMu.Lock()
	logBuffer = nil
	logMu.Unlock()
	log.Printf("=== Starting proxy ===")

	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
	}
	echReady = false
	proxyPort = 0
	proxyMu.Unlock()

	// ── 阶段 1：配置 DoH（不持锁，不探测任何站点）──────────────────────
	bootstrap := ""
	if bootstrapIP != nil {
		bootstrap = C.GoString(bootstrapIP)
	}
	if bootstrap != "" {
		log.Printf("ECH: DoH=%s, bootstrapIP=%s", defaultDohHost, bootstrap)
		cloudflare_ech.SetDoHConfig(defaultDohURL, bootstrap)
	} else {
		log.Printf("ECH: DoH=%s (with automatic multi-DoH failover)", defaultDohURL)
	}

	// ── 阶段 2：绑定端口 + 启动（持锁，瞬时）─────────────────────────────
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if proxyGen != myGen {
		log.Printf("StartProxy aborted: stopped mid-probe")
		return 0
	}

	ln, err := net.Listen("tcp4", "127.0.0.1:8443")
	if err != nil {
		log.Printf("Port 8443 in use, trying random port...")
		ln, err = net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			log.Printf("listen failed: %v", err)
			return 0
		}
	}
	proxyPort = uint16(ln.Addr().(*net.TCPAddr).Port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", safeHandler(router))

	proxyServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		defer guardPanic("Serve")
		if err := proxyServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("server error: %v", err)
		}
	}()

	echReady = true
	log.Printf("Proxy started on port %d", proxyPort)
	return proxyPort
}

//export StopProxy
func StopProxy() {
	defer guardPanic("StopProxy")
	proxyMu.Lock()
	defer proxyMu.Unlock()

	proxyGen++
	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
		proxyPort = 0
		echReady = false
		log.Printf("Proxy stopped")
	}
}

//export GetProxyPort
func GetProxyPort() (port uint16) {
	defer guardPanic("GetProxyPort")
	proxyMu.Lock()
	defer proxyMu.Unlock()
	return proxyPort
}

//export IsEchReady
func IsEchReady() (ret C.int) {
	defer guardPanic("IsEchReady")
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if echReady {
		return 1
	}
	return 0
}

// ─── 路由 ────────────────────────────────────────────────────────────────────

// isLocalHost：Host 指向本机（回环 / 未指定 / 链路本地元数据 / localhost）→ 只提供状态页或拒绝转发，
// 绝不转发到上游，防代理环与 SSRF。
func isLocalHost(host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	if h == "" {
		return true
	}
	if strings.HasPrefix(h, "[") {
		if j := strings.Index(h, "]"); j >= 0 {
			h = h[1:j]
		}
	} else if i := strings.LastIndex(h, ":"); i >= 0 {
		h = h[:i]
	}
	switch h {
	case "localhost", "localhost.localdomain", "127.0.0.1", "::1", "0.0.0.0", "::", "169.254.169.254":
		return true
	}
	if strings.HasSuffix(h, ".localhost") {
		return true
	}
	if ip := net.ParseIP(h); ip != nil {
		return netdial.IsLocalOrLinkLocalIP(ip)
	}
	return false
}

// resolveTargetScheme 根据请求头 X-ECH-Scheme / X-Forwarded-Proto 或代理 URL 推断原始协议（"http" 或 "https"）。
func resolveTargetScheme(r *http.Request) string {
	for _, hdr := range []string{"X-ECH-Scheme", "X-Forwarded-Proto"} {
		if v := strings.ToLower(strings.TrimSpace(r.Header.Get(hdr))); v == "http" || v == "https" {
			return v
		}
	}
	if r.URL != nil {
		if s := strings.ToLower(r.URL.Scheme); s == "http" || s == "https" {
			return s
		}
	}
	return "https"
}

// safeHandler 在请求处理链最外层兜底 recover。
// 关键：Go 的 panic 若发生在 net/http 的 handler goroutine 里且无人 recover，
// 会直接 abort **整个进程** —— 在浏览器里就是"页面一加载就闪退"。
// 这里把任何 handler panic 转成 500 错误页并落盘，进程继续存活。
func safeHandler(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("PANIC in handler %s %s: %v\n%s", r.Method, r.URL.Path, rec, debug.Stack())
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusInternalServerError)
				fmt.Fprint(w, `<!DOCTYPE html><html lang="zh"><body>
<h1>内核已捕获请求异常（进程未退出）</h1>
<p>已记录到 &lt;用户目录&gt;/.ech-browser/kernel.log，可回传该文件定位。</p>
</body></html>`)
			}
		}()
		h(w, r)
	}
}

func router(w http.ResponseWriter, r *http.Request) {
	// 若客户端未传 X-Ech-Scheme 且 Host 是本机回环，则提供内置状态/诊断接口。
	if isLocalHost(r.Host) {
		// 阻止云元数据 IP（169.254.x.x）SSRF
		if strings.HasPrefix(strings.TrimSpace(r.Host), "169.254.") {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/", "/index.html":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, statusHTML)
		case "/health":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok":       true,
				"port":     GetProxyPort(),
				"echReady": IsEchReady() == 1,
				"initDone": ECHInitReady() == 1,
			})
		case "/__panic":
			// 自检路由：验证 recover 中间件生效（CI smoke 使用；仅本机回环可达）。
			log.Printf("SELF-TEST: /__panic requested, panicking now")
			panic("smoke-test panic")
		case "/logs":
			logMu.RLock()
			logs := strings.Join(logBuffer, "\n")
			logMu.RUnlock()
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			fmt.Fprint(w, logs)
		default:
			http.NotFound(w, r)
		}
		return
	}

	forward(w, r)
}

// forward：把 webview 拦截来的请求按 Host 与原始协议全自动 ECH/分片TLS/SNI 伪装直连上游。
// 浏览器侧 Cookie/登录态由 webview 维护（请求头 Cookie + 响应 Set-Cookie 原样透传），本内核是无状态转发层。
func forward(w http.ResponseWriter, r *http.Request) {
	scheme := resolveTargetScheme(r)
	reqURI := r.URL.RequestURI()
	if strings.HasPrefix(reqURI, "http://") || strings.HasPrefix(reqURI, "https://") {
		if r.URL.Path != "" {
			reqURI = r.URL.Path
			if r.URL.RawQuery != "" {
				reqURI += "?" + r.URL.RawQuery
			}
		} else {
			reqURI = "/"
		}
	}
	target := scheme + "://" + r.Host + reqURI
	log.Printf("→ %s %s", r.Method, target)

	// 缓冲可读请求体（<= maxBufferedBody），以便 RoundTrip 在多模式回退重试时重放 Body。
	var bodyReader io.Reader
	var getBody func() (io.ReadCloser, error)
	if r.Body != nil && r.Body != http.NoBody {
		buf, err := io.ReadAll(io.LimitReader(r.Body, maxBufferedBody+1))
		_ = r.Body.Close()
		if err != nil {
			errorPage(w, http.StatusBadRequest, "请求体读取失败", err, target)
			return
		}
		if len(buf) > maxBufferedBody {
			errorPage(w, http.StatusRequestEntityTooLarge, "请求体过大", fmt.Errorf("exceeds %d bytes", maxBufferedBody), target)
			return
		}
		if len(buf) > 0 {
			bodyReader = bytes.NewReader(buf)
			getBody = func() (io.ReadCloser, error) {
				return io.NopCloser(bytes.NewReader(buf)), nil
			}
		}
	}

	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, bodyReader)
	if err != nil {
		errorPage(w, http.StatusBadRequest, "请求构建失败", err, target)
		return
	}
	if getBody != nil {
		req.GetBody = getBody
		if bodyReader != nil {
			req.ContentLength = int64(bodyReader.(*bytes.Reader).Len())
		}
	} else {
		req.ContentLength = 0
	}

	// 透传浏览器头（Host 由 req 的 URL 决定，需显式保留原始 Host）。
	req.Host = r.Host
	for k, vs := range r.Header {
		if hopByHop[http.CanonicalHeaderKey(k)] || hopByHop[k] {
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	if ua := req.Header.Get("User-Agent"); ua == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
	}

	mode := ""
	if scheme == "http" {
		mode = "direct"
	}
	resp, err := cloudflare_ech.RoundTrip(req, mode, "")
	if err != nil {
		log.Printf("RoundTrip error: %v", err)
		errorPage(w, http.StatusBadGateway, "上游访问失败", err, target)
		return
	}
	defer resp.Body.Close()

	for k, vs := range resp.Header {
		if hopByHop[http.CanonicalHeaderKey(k)] || hopByHop[k] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}
	if w.Header().Get("Accept-Ranges") == "" {
		w.Header().Set("Accept-Ranges", "bytes")
	}

	w.WriteHeader(resp.StatusCode)
	if r.Method == http.MethodHead {
		log.Printf("← %d %s (HEAD)", resp.StatusCode, target)
		return
	}

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				log.Printf("← %d %s (client closed)", resp.StatusCode, target)
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			log.Printf("← %d %s", resp.StatusCode, target)
			return
		}
	}
}

func main() {}

// errorPage 输出经 HTML 转义的安全可读错误页（消除反射型 XSS，替代裸 502 文本）。
func errorPage(w http.ResponseWriter, code int, title string, err error, target string) {
	safeTitle := html.EscapeString(title)
	safeTarget := html.EscapeString(target)
	errMsg := ""
	if err != nil {
		errMsg = html.EscapeString(err.Error())
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>%s</title>
<style>body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:2rem;max-width:42rem}
code{background:#000;border:1px solid #333;padding:2px 6px;border-radius:4px;word-break:break-all}
a{color:#7cb3ff}</style></head><body>
<h1>%s</h1>
<p>访问 <code>%s</code> 失败。</p>
<p>%s</p>
<p>诊断日志见应用内「日志」页或 <code>127.0.0.1:<a href="/logs">/logs</a></code>。
这是 ech-browser 内核错误页；普通站点直连不受影响。</p>
</body></html>`, safeTitle, safeTitle, safeTarget, errMsg)
}
