// ech-browser 是「点开即用」的通用 ECH 独立浏览器：flutter+webview 做外壳，
// go 内核（本 engine）在 webview 拦截层背后按 Host 全自动做 ECH/SNI 伪装直连。
// 可访问**任意 http(s) 网址**：无需修改系统 hosts、无需手动安装证书
// （webview 永远只与本地回环代理打交道；上游 TLS 由 go 内核用系统信任根完成）。
//
// 本文件是 go 内核的 c-shared 入口，导出面与 ech-proxy 仓库 flutter/main.go
// 的 Flutter FFI 契约保持一致（12 个 export），Dart 侧依赖齐全，缺一个即
// lookupFunction 抛 ArgumentError：
//
//   ECHSetDohURL / ECHInit / ECHInitWithBootstrap / ECHInitReady /
//   ECHInitLastError / ECHGetLogCount / ECHGetLog / FreeCString
//   StartProxy / StopProxy / GetProxyPort / IsEchReady
//
// 监听形态：只提供**明文 HTTP**，绑定 127.0.0.1（回环，优先 8443，占用则随机）。
// 回环地址无需 TLS；Dart 侧拦截桥把原始 URL 改写为 http://127.0.0.1:<port>/…，
// 并保留原始 Host 头，本内核按 Host 路由上游。
//
// 构建（CI 专用，本地禁止测试）：
//   Linux amd64： CGO_ENABLED=1 GOOS=linux   GOARCH=amd64  go build -buildmode=c-shared -o libechproxy.so ./engine/
//   Windows amd64：CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build -buildmode=c-shared -o echproxy.dll ./engine/
//   Android arm64：CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=aarch64-linux-android21-clang go build -buildmode=c-shared -o libechproxy.so ./engine/

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	_ "embed"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	cloudflare_ech "github.com/Hana-ame/ech-browser/engine/ech"
)

//go:embed status.html
var statusHTML string

// DoH 服务：固有配置，硬编码。bootstrapIP 由调用方运行时传入
// （DNS 解析 moonchan.xyz 得到），不硬编码。
const defaultDohHost = "moonchan.xyz"
const defaultDohURL = "https://moonchan.xyz/doh"

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
	// proxyGen：每次 StartProxy 进入 / StopProxy 各递增。StartProxy 的 ECH
	// 探测较慢且不持锁，期间 StopProxy 可能返回；靠这个代号在绑定端口前
	// 复查，避免"App 已退出但端口仍被绑上"。
	proxyGen uint64

	logMu      sync.RWMutex
	logBuffer  []string
	maxLogLines = 500
)

// hopByHop 逐跳头只描述"上一跳到下一跳"，绝不能转发给客户端连接。
var hopByHop = map[string]bool{
	"Connection": true, "Keep-Alive": true, "Proxy-Authenticate": true,
	"Proxy-Authorization": true, "Te": true, "Trailer": true,
	"Transfer-Encoding": true, "Upgrade": true,
}

type logWriter struct{}

func (w *logWriter) Write(p []byte) (int, error) {
	line := strings.TrimRight(string(p), "\n")
	fmt.Fprintln(os.Stderr, line)
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
	// 通用浏览器：不为单一站点做启动门禁（站点挂了浏览器必须照常打开）。
	// ECH/SNI 配置由 RoundTrip 在首个请求时懒初始化（见 ech/client.go
	// getECHClient：lastECHConfig 为空自动拉取）。ECHInit（App 启动时已调）
	// 只是预热，StartProxy 不依赖它。
	bootstrap := C.GoString(bootstrapIP)
	if bootstrap != "" {
		log.Printf("ECH: DoH=%s/doh, bootstrapIP=%s", defaultDohHost, bootstrap)
		cloudflare_ech.SetDoHConfig(defaultDohHost, bootstrap)
	} else {
		log.Printf("ECH: DoH=%s", defaultDohURL)
		cloudflare_ech.SetDohURL(defaultDohURL)
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
	mux.HandleFunc("/", router)

	proxyServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
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

// isLocalHost：Host 指向本机（回环 / 元数据 / localhost）→ 只提供状态页，
// 绝不转发，防代理环与 SSRF 打到自己。
func isLocalHost(host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	if i := strings.LastIndex(h, ":"); i >= 0 {
		// 去掉端口（IPv6 [::1]:8443 的 ]: 之后是端口）
		if strings.HasPrefix(h, "[") {
			if j := strings.Index(h, "]"); j >= 0 {
				h = h[1:j]
			}
		} else {
			h = h[:i]
		}
	}
	switch h {
	case "localhost", "127.0.0.1", "::1", "0.0.0.0", "::":
		return true
	}
	if ip := net.ParseIP(h); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

func router(w http.ResponseWriter, r *http.Request) {
	if isLocalHost(r.Host) {
		switch r.URL.Path {
		case "/", "/index.html":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, statusHTML)
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

// forward：把 webview 拦截来的请求按 Host 全自动 ECH/SNI 伪装直连上游。
// 浏览器侧 Cookie/登录态由 webview 自己维护（请求头 Cookie + 响应 Set-Cookie
// 原样透传），本内核是**无状态**转发层。
func forward(w http.ResponseWriter, r *http.Request) {
	target := "https://" + r.Host + r.URL.RequestURI()
	log.Printf("→ %s %s", r.Method, target)

	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, r.Body)
	if err != nil {
		errorPage(w, http.StatusBadRequest, "请求构建失败", err, target)
		return
	}
	req.ContentLength = r.ContentLength

	// 透传浏览器头（Host 由 req 的 URL 决定，需显式保留原始 Host）。
	req.Host = r.Host
	for k, vs := range r.Header {
		if hopByHop[k] {
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	if ua := r.Header.Get("User-Agent"); ua == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 (EchBrowser)")
	}

	// 全自动模式：ECH（Cloudflare 站点如 pixiv）↔ SNI 伪装直连（非 CF）↔ 直连兜底。
	resp, err := cloudflare_ech.RoundTrip(req, "", "")
	if err != nil {
		log.Printf("RoundTrip error: %v", err)
		errorPage(w, http.StatusBadGateway, "上游访问失败", err, target)
		return
	}
	defer resp.Body.Close()

	for k, vs := range resp.Header {
		if hopByHop[k] {
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

// errorPage 输出可读的错误页（替代裸 502 文本），与普通浏览器的错误页体验对齐。
func errorPage(w http.ResponseWriter, code int, title string, err error, target string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>%s</title>
<style>body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:2rem;max-width:42rem}
code{background:#000;border:1px solid #333;padding:2px 6px;border-radius:4px}
a{color:#7cb3ff}</style></head><body>
<h1>%s</h1>
<p>访问 <code>%s</code> 失败。</p>
<p>%v</p>
<p>诊断日志见应用内「日志」页或 <code>127.0.0.1:<a href="/logs">/logs</a></code>。
这是 ech-browser 内核错误页；普通站点直连不受影响。</p>
</body></html>`, title, title, target, err)
}
