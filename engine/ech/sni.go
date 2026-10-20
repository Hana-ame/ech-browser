package cloudflare_ech

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Hana-ame/ech-browser/engine/netdial"
	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

const (
	routeCacheTTL = 30 * time.Minute
	maxRouteCache = 1024
	maxIPCache    = 1024
	maxTransCache = 256
)

type routeEntry struct {
	mode   string
	expiry time.Time
}

var (
	routeMu sync.RWMutex
	routes  = map[string]routeEntry{}
)

func getCachedRoute(host string) (string, bool) {
	routeMu.RLock()
	defer routeMu.RUnlock()
	e, ok := routes[host]
	if !ok || time.Now().After(e.expiry) {
		return "", false
	}
	return e.mode, true
}

func setCachedRoute(host, mode string) {
	routeMu.Lock()
	if len(routes) >= maxRouteCache {
		for k := range routes {
			delete(routes, k)
			break
		}
	}
	routes[host] = routeEntry{mode: mode, expiry: time.Now().Add(routeCacheTTL)}
	routeMu.Unlock()
}

func clearCachedRoute(host string) {
	routeMu.Lock()
	delete(routes, host)
	routeMu.Unlock()
}

// DetectTransportMode 全自动无干预判断目标主机首选传输模式：
//  1. 优先读取已验证成功的路由缓存；
//  2. 通过 DoH（或公共 DNS 回退）解析目标主机 IP，检查是否属于 Cloudflare 网段（netdial.IsCloudflareIP）：
//     - 属于 Cloudflare 网段 -> 返回 "ech"（走 Cloudflare ECH 加密 ClientHello）
//     - 不属于 Cloudflare 网段 -> 返回 "frag"（走 DoH 真实 IP + TCP ClientHello 分片 + 真实 SNI，兼容所有标准站点；失败再回退 "sni" 域前置）
func DetectTransportMode(ctx context.Context, host string) string {
	host = normalizeHostOnly(host)
	if cached, ok := getCachedRoute(host); ok {
		return cached
	}
	ips, err := ResolveHostIPs(ctx, host)
	if err == nil && len(ips) > 0 {
		for _, ipStr := range ips {
			if netdial.IsCloudflareIP(net.ParseIP(ipStr)) {
				return "ech"
			}
		}
		return "frag"
	}
	return "frag"
}

func normalizeHostOnly(host string) string {
	host = strings.ToLower(strings.TrimSpace(host))
	if h, _, err := net.SplitHostPort(host); err == nil {
		return strings.Trim(h, "[]")
	}
	return strings.Trim(host, "[]")
}

func extractHostAndPort(req *http.Request) (string, string) {
	rawHost := req.Host
	if rawHost == "" && req.URL != nil {
		rawHost = req.URL.Host
	}
	defaultPort := "443"
	if req.URL != nil && req.URL.Scheme == "http" {
		defaultPort = "80"
	}
	if h, p, err := net.SplitHostPort(rawHost); err == nil && p != "" {
		return strings.ToLower(strings.Trim(h, "[]")), p
	}
	return strings.ToLower(strings.Trim(rawHost, "[]")), defaultPort
}

// cloneRequestForAttempt 为每次回退尝试克隆请求并重置 Body（当 GetBody 可用时），避免前一次尝试消耗或篡改状态。
func cloneRequestForAttempt(req *http.Request) (*http.Request, error) {
	cloned := req.Clone(req.Context())
	if req.Body != nil && req.GetBody != nil {
		b, err := req.GetBody()
		if err != nil {
			return nil, err
		}
		cloned.Body = b
	}
	return cloned, nil
}

// RoundTrip 全自动无干预执行上游请求分发：
//   - "direct" 或明文 http://：走标准直连；
//   - 其他情况（"" / "auto" / "ech" / "frag" / "sni"）：
//     自动根据目标 IP 是否属于 Cloudflare 构造最优回退链：
//     * Cloudflare 站点：ech -> frag -> sni -> direct
//     * 非 Cloudflare 站点：frag（DoH 真实 IP + 分片真实 SNI）-> sni（无/伪造 SNI 域前置）-> direct -> ech
//     且对每一次尝试均做网关拒绝检查（isRouteRejection），彻底修复非 CF 站点被错误路由到 CF 返回 530 的问题。
func RoundTrip(req *http.Request, mode, ipMode string) (*http.Response, error) {
	if mode == "direct" || (req.URL != nil && req.URL.Scheme == "http") {
		return netdial.ClientWithIPMode(ipMode, netdial.OpTimeout).Do(req)
	}

	host, _ := extractHostAndPort(req)

	primary := mode
	if primary == "" || primary == "auto" {
		primary = DetectTransportMode(req.Context(), host)
	} else if cached, ok := getCachedRoute(host); ok {
		primary = cached
	}

	var chain []string
	switch primary {
	case "ech":
		chain = []string{"ech", "frag", "sni", "direct"}
	case "sni":
		chain = []string{"sni", "frag", "direct", "ech"}
	default:
		chain = []string{"frag", "sni", "direct", "ech"}
	}

	var firstErr error
	var lastResp *http.Response
	for _, m := range chain {
		attemptReq, cerr := cloneRequestForAttempt(req)
		if cerr != nil {
			return nil, cerr
		}
		resp, err := doSingleMode(attemptReq, m, ipMode)
		if err == nil && resp != nil {
			if !isRouteRejection(resp, m) {
				if m != "direct" {
					setCachedRoute(host, m)
				}
				if lastResp != nil {
					lastResp.Body.Close()
				}
				return resp, nil
			}
			// 保留最后一次收到的响应以防所有模式均被拒，但先关闭上一次被拒响应
			if lastResp != nil {
				lastResp.Body.Close()
			}
			lastResp = resp
			clearCachedRoute(host)
			continue
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
		clearCachedRoute(host)
	}

	if lastResp != nil {
		return lastResp, nil
	}
	return nil, firstErr
}

func doSingleMode(req *http.Request, mode, ipMode string) (*http.Response, error) {
	switch mode {
	case "frag":
		return FragTLSDo(req, ipMode)
	case "sni":
		return SNIFrontDo(req, ipMode)
	case "direct":
		return netdial.ClientWithIPMode(ipMode, netdial.OpTimeout).Do(req)
	default:
		return Do(req, ipMode)
	}
}

// isRouteRejection 判断当前传输模式的响应是否为 CDN 边缘/虚拟主机因路由或 SNI 不匹配而返回的拒绝状态码。
func isRouteRejection(resp *http.Response, mode string) bool {
	if resp == nil {
		return true
	}
	switch mode {
	case "ech", "":
		// Cloudflare 边缘拒绝未托管在 CF 的域名或源站不可达（403 Error 1003, 421 Misdirected, 520-530）
		switch resp.StatusCode {
		case 400, 421, 520, 521, 522, 523, 524, 525, 526, 530:
			return true
		}
	case "sni":
		// 伪造 SNI 连接非 CF 站点时，若源站因 SNI!=Host 返回 400/421/502/503/52x，则视为拒绝并切换下一模式
		switch resp.StatusCode {
		case 400, 421, 502, 503, 520, 521, 522, 523, 525, 526, 530:
			return true
		}
	}
	return false
}

type ipCacheEntry struct {
	ips    []string
	expiry time.Time
}

var (
	ipCacheMu     sync.Mutex
	ipCache       = map[string]ipCacheEntry{}
	sniTransMu    sync.Mutex
	sniH2Trans    = map[string]*http2.Transport{}
	sniH1Clients  = map[string]*http.Client{}
	fragH2Trans   = map[string]*http2.Transport{}
	fragH1Clients = map[string]*http.Client{}
)

// ResolveHostIPs 通过 DoH（及公共 DNS 兜底）查询目标域名的 A/AAAA 记录并按 TTL 缓存。
func ResolveHostIPs(ctx context.Context, host string) ([]string, error) {
	host = normalizeHostOnly(host)
	if host == "" {
		return nil, fmt.Errorf("empty host")
	}
	// 若输入本身已是 IP 字面量，直接返回，避免向 DoH 发起无效查询。
	if ip := net.ParseIP(host); ip != nil {
		return []string{ip.String()}, nil
	}

	mode := currentConfig().ipMode
	cacheKey := host + "|" + mode

	ipCacheMu.Lock()
	if e, ok := ipCache[cacheKey]; ok && time.Now().Before(e.expiry) {
		ips := e.ips
		ipCacheMu.Unlock()
		return ips, nil
	}
	ipCacheMu.Unlock()

	qtype := 1 // A
	if mode == "v6" {
		qtype = 28 // AAAA
	}

	resp, err := netdial.Retry(ctx, 2, netdial.RetryBackoff, func() (*http.Response, error) {
		r, e := QueryDoH(ctx, host, qtype)
		if e != nil && r != nil {
			r.Body.Close()
		}
		return r, e
	})
	var ips []string
	ttl := 300
	if err == nil && resp != nil {
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			var d dohResponse
			if json.NewDecoder(resp.Body).Decode(&d) == nil {
				seen := make(map[string]bool)
				for _, ans := range d.Answer {
					if (ans.Type == 1 || ans.Type == 28) && net.ParseIP(ans.Data) != nil && !seen[ans.Data] {
						seen[ans.Data] = true
						ips = append(ips, ans.Data)
						if ans.TTL > 0 && ans.TTL < ttl {
							ttl = ans.TTL
						}
					}
				}
			}
		}
	}

	// 若 DoH 未返回结果，回退使用 netdial 公共 DNS 解析器
	if len(ips) == 0 {
		pref := "v4"
		if mode == "v6" {
			pref = "v6"
		}
		if ipStr, rerr := netdial.ResolvePreferredIP(ctx, host, pref); rerr == nil && ipStr != "" {
			ips = append(ips, ipStr)
		} else if ipStr2, rerr2 := netdial.ResolvePreferredIP(ctx, host, ""); rerr2 == nil && ipStr2 != "" {
			ips = append(ips, ipStr2)
		} else {
			return nil, fmt.Errorf("no DNS record for %s", host)
		}
	}

	if ttl < minTTL {
		ttl = minTTL
	} else if ttl > maxTTL {
		ttl = maxTTL
	}
	ipCacheMu.Lock()
	if len(ipCache) >= maxIPCache {
		for k := range ipCache {
			delete(ipCache, k)
			break
		}
	}
	ipCache[cacheKey] = ipCacheEntry{ips: ips, expiry: time.Now().Add(time.Duration(ttl) * time.Second)}
	ipCacheMu.Unlock()
	return ips, nil
}

// verifyPeerCert 校验服务端证书链是否由系统信任根签发（并优先校验 targetHost 主机名匹配，杜绝自签名 MITM）。
func verifyPeerCert(targetHost string, strictHost bool) func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return fmt.Errorf("tls: empty peer certificate chain")
		}
		certs := make([]*x509.Certificate, len(rawCerts))
		for i, asn1Data := range rawCerts {
			c, err := x509.ParseCertificate(asn1Data)
			if err != nil {
				return fmt.Errorf("tls: failed to parse certificate: %w", err)
			}
			certs[i] = c
		}
		intermediates := x509.NewCertPool()
		for _, ic := range certs[1:] {
			intermediates.AddCert(ic)
		}
		opts := x509.VerifyOptions{
			DNSName:       targetHost,
			Intermediates: intermediates,
			Roots:         netdial.RootPool(),
		}
		if _, err := certs[0].Verify(opts); err == nil {
			return nil
		} else if strictHost {
			return err
		}
		// 在 SNI 伪装模式下，部分 CDN 返回边缘共享证书（主机名可能为 CDN 域名），但仍必须由受信任 CA 签发！
		chainOnlyOpts := x509.VerifyOptions{
			Intermediates: intermediates,
			Roots:         netdial.RootPool(),
		}
		_, err := certs[0].Verify(chainOnlyOpts)
		return err
	}
}

// dialFragUTLS 使用 DoH 解析出的真实 IP + TCP ClientHello 分片 + 真实 ServerName 建立受证书校验保护的 uTLS 连接。
func dialFragUTLS(ctx context.Context, ip, port, targetHost string, nextProtos []string) (*utls.UConn, error) {
	rawConn, err := netdial.Dialer().DialContext(ctx, "tcp", net.JoinHostPort(ip, port))
	if err != nil {
		return nil, err
	}
	fragConn := netdial.WrapFragmentedConn(rawConn)
	uConn := utls.UClient(fragConn, &utls.Config{
		ServerName:            targetHost,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: verifyPeerCert(targetHost, true),
		NextProtos:            nextProtos,
	}, utls.HelloChrome_120)
	hCtx, cancel := context.WithTimeout(ctx, netdial.TLSHandshakeTimeout)
	err = uConn.HandshakeContext(hCtx)
	cancel()
	if err != nil {
		rawConn.Close()
		return nil, err
	}
	return uConn, nil
}

// dialSNIFrontUTLS 使用伪造/空 SNI + TCP ClientHello 分片建立连接，但依然校验服务端证书由系统信任根签发。
func dialSNIFrontUTLS(ctx context.Context, ip, port, targetHost string, nextProtos []string) (*utls.UConn, error) {
	rawConn, err := netdial.Dialer().DialContext(ctx, "tcp", net.JoinHostPort(ip, port))
	if err != nil {
		return nil, err
	}
	fragConn := netdial.WrapFragmentedConn(rawConn)
	uConn := utls.UClient(fragConn, &utls.Config{
		ServerName:            shellDomain,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: verifyPeerCert(targetHost, false),
		NextProtos:            nextProtos,
	}, utls.HelloChrome_120)
	hCtx, cancel := context.WithTimeout(ctx, netdial.TLSHandshakeTimeout)
	err = uConn.HandshakeContext(hCtx)
	cancel()
	if err != nil {
		rawConn.Close()
		return nil, err
	}
	return uConn, nil
}

func getFragH2Transport(ip, port, host string) *http2.Transport {
	key := ip + ":" + port + "|" + host
	sniTransMu.Lock()
	defer sniTransMu.Unlock()
	if t, ok := fragH2Trans[key]; ok {
		return t
	}
	t := &http2.Transport{
		AllowHTTP: false,
		DialTLSContext: func(ctx context.Context, _, _ string, _ *tls.Config) (net.Conn, error) {
			uConn, err := dialFragUTLS(ctx, ip, port, host, []string{"h2", "http/1.1"})
			if err != nil {
				return nil, err
			}
			if uConn.ConnectionState().NegotiatedProtocol != "h2" {
				uConn.Close()
				return nil, fmt.Errorf("upstream negotiated %q, not h2", uConn.ConnectionState().NegotiatedProtocol)
			}
			return uConn, nil
		},
	}
	if len(fragH2Trans) >= maxTransCache {
		for k, old := range fragH2Trans {
			old.CloseIdleConnections()
			delete(fragH2Trans, k)
			break
		}
	}
	fragH2Trans[key] = t
	return t
}

func getFragH1Client(ip, port, host string) *http.Client {
	key := ip + ":" + port + "|" + host
	sniTransMu.Lock()
	defer sniTransMu.Unlock()
	if c, ok := fragH1Clients[key]; ok {
		return c
	}
	tr := &http.Transport{
		DialTLSContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialFragUTLS(ctx, ip, port, host, []string{"http/1.1"})
		},
		ResponseHeaderTimeout: netdial.ResponseHeaderTimeout,
		MaxIdleConns:          32,
		IdleConnTimeout:       90 * time.Second,
	}
	c := &http.Client{
		Transport: tr,
		Timeout:   0,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	if len(fragH1Clients) >= maxTransCache {
		for k := range fragH1Clients {
			delete(fragH1Clients, k)
			break
		}
	}
	fragH1Clients[key] = c
	return c
}

func getSNIH2Transport(ip, port, host string) *http2.Transport {
	key := ip + ":" + port + "|" + host
	sniTransMu.Lock()
	defer sniTransMu.Unlock()
	if t, ok := sniH2Trans[key]; ok {
		return t
	}
	t := &http2.Transport{
		AllowHTTP: false,
		DialTLSContext: func(ctx context.Context, _, _ string, _ *tls.Config) (net.Conn, error) {
			uConn, err := dialSNIFrontUTLS(ctx, ip, port, host, []string{"h2", "http/1.1"})
			if err != nil {
				return nil, err
			}
			if uConn.ConnectionState().NegotiatedProtocol != "h2" {
				uConn.Close()
				return nil, fmt.Errorf("upstream negotiated %q, not h2", uConn.ConnectionState().NegotiatedProtocol)
			}
			return uConn, nil
		},
	}
	if len(sniH2Trans) >= maxTransCache {
		for k, old := range sniH2Trans {
			old.CloseIdleConnections()
			delete(sniH2Trans, k)
			break
		}
	}
	sniH2Trans[key] = t
	return t
}

func getSNIH1Client(ip, port, host string) *http.Client {
	key := ip + ":" + port + "|" + host
	sniTransMu.Lock()
	defer sniTransMu.Unlock()
	if c, ok := sniH1Clients[key]; ok {
		return c
	}
	tr := &http.Transport{
		DialTLSContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialSNIFrontUTLS(ctx, ip, port, host, []string{"http/1.1"})
		},
		ResponseHeaderTimeout: netdial.ResponseHeaderTimeout,
		MaxIdleConns:          32,
		IdleConnTimeout:       90 * time.Second,
	}
	c := &http.Client{
		Transport: tr,
		Timeout:   0,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	if len(sniH1Clients) >= maxTransCache {
		for k := range sniH1Clients {
			delete(sniH1Clients, k)
			break
		}
	}
	sniH1Clients[key] = c
	return c
}

// FragTLSDo 使用 DoH 解析真实 IP + TCP ClientHello 分片 + 真实 SNI 直连目标主机（兼容 HTTP/2 与 HTTP/1.1）。
func FragTLSDo(req *http.Request, _ ...string) (*http.Response, error) {
	host, port := extractHostAndPort(req)
	ips, err := ResolveHostIPs(req.Context(), host)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, ip := range ips {
		key := ip + ":" + port + "|" + host
		r2, cerr := cloneRequestForAttempt(req)
		if cerr != nil {
			return nil, cerr
		}
		resp, err := getFragH2Transport(ip, port, host).RoundTrip(r2)
		if err == nil {
			return resp, nil
		}
		if strings.Contains(err.Error(), "not h2") {
			r1, cerr1 := cloneRequestForAttempt(req)
			if cerr1 != nil {
				return nil, cerr1
			}
			if resp1, err1 := getFragH1Client(ip, port, host).Do(r1); err1 == nil {
				return resp1, nil
			} else {
				err = err1
			}
		}
		lastErr = err
		sniTransMu.Lock()
		if old, ok := fragH2Trans[key]; ok {
			old.CloseIdleConnections()
			delete(fragH2Trans, key)
		}
		sniTransMu.Unlock()
	}
	return nil, fmt.Errorf("frag TLS failed for %s: %w", host, lastErr)
}

// SNIFrontDo 使用 SNI 伪装直连目标主机（同时兼容 HTTP/2 与 HTTP/1.1 源站）。
func SNIFrontDo(req *http.Request, _ ...string) (*http.Response, error) {
	host, port := extractHostAndPort(req)
	ips, err := ResolveHostIPs(req.Context(), host)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, ip := range ips {
		key := ip + ":" + port + "|" + host
		r2, cerr := cloneRequestForAttempt(req)
		if cerr != nil {
			return nil, cerr
		}
		resp, err := getSNIH2Transport(ip, port, host).RoundTrip(r2)
		if err == nil {
			return resp, nil
		}
		// 若源站仅支持 HTTP/1.1，自动回退至 uTLS HTTP/1.1 传输
		if strings.Contains(err.Error(), "not h2") {
			r1, cerr1 := cloneRequestForAttempt(req)
			if cerr1 != nil {
				return nil, cerr1
			}
			if resp1, err1 := getSNIH1Client(ip, port, host).Do(r1); err1 == nil {
				return resp1, nil
			} else {
				err = err1
			}
		}
		lastErr = err
		sniTransMu.Lock()
		if old, ok := sniH2Trans[key]; ok {
			old.CloseIdleConnections()
			delete(sniH2Trans, key)
		}
		sniTransMu.Unlock()
	}
	ipCacheMu.Lock()
	delete(ipCache, host+"|"+currentConfig().ipMode)
	ipCacheMu.Unlock()
	return nil, fmt.Errorf("all IPs failed for %s: %w", host, lastErr)
}
