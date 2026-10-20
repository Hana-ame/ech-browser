package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIsLocalHostAndSSRFProtection(t *testing.T) {
	localCases := []string{
		"localhost",
		"localhost:8443",
		"127.0.0.1",
		"127.0.0.1:8443",
		"127.0.0.2:80",
		"[::1]:8443",
		"0.0.0.0:8080",
		"169.254.169.254",
		"169.254.169.254:80",
		"sub.localhost",
		"",
	}
	for _, h := range localCases {
		if !isLocalHost(h) {
			t.Errorf("expected %q to be treated as local/restricted host", h)
		}
	}

	remoteCases := []string{
		"www.pixiv.net",
		"www.pixiv.net:443",
		"i.pximg.net",
		"github.com:8443",
	}
	for _, h := range remoteCases {
		if isLocalHost(h) {
			t.Errorf("expected %q NOT to be treated as local host", h)
		}
	}
}

func TestResolveTargetScheme(t *testing.T) {
	r1 := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8443/a", nil)
	r1.Header.Set("X-ECH-Scheme", "http")
	if got := resolveTargetScheme(r1); got != "http" {
		t.Fatalf("expected http, got %s", got)
	}

	r2 := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8443/a", nil)
	r2.Header.Set("X-ECH-Scheme", "https")
	if got := resolveTargetScheme(r2); got != "https" {
		t.Fatalf("expected https, got %s", got)
	}

	r3 := httptest.NewRequest(http.MethodGet, "/relative", nil)
	if got := resolveTargetScheme(r3); got != "https" {
		t.Fatalf("expected default https, got %s", got)
	}
}

func TestErrorPageEscapesXSS(t *testing.T) {
	rec := httptest.NewRecorder()
	maliciousTarget := "https://example.com/<script>alert(1)</script>"
	maliciousErr := errors.New(`<img src=x onerror=alert(2)>`)
	errorPage(rec, http.StatusBadGateway, "<b>Bad</b>", maliciousErr, maliciousTarget)

	body := rec.Body.String()
	if strings.Contains(body, "<script>alert(1)</script>") {
		t.Fatal("XSS vulnerability: raw <script> tag was not escaped in errorPage")
	}
	if strings.Contains(body, "<img src=x onerror=alert(2)>") {
		t.Fatal("XSS vulnerability: raw <img> tag in error message was not escaped")
	}
	if !strings.Contains(body, "&lt;script&gt;alert(1)&lt;/script&gt;") {
		t.Fatal("expected HTML-escaped script tag in output")
	}
}

func TestRouterStatusAndMetadataBlock(t *testing.T) {
	reqStatus := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8443/", nil)
	reqStatus.Host = "127.0.0.1:8443"
	recStatus := httptest.NewRecorder()
	router(recStatus, reqStatus)
	if recStatus.Code != http.StatusOK {
		t.Fatalf("expected 200 OK for status page, got %d", recStatus.Code)
	}

	reqHealth := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8443/health", nil)
	reqHealth.Host = "127.0.0.1:8443"
	recHealth := httptest.NewRecorder()
	router(recHealth, reqHealth)
	if recHealth.Code != http.StatusOK || !strings.Contains(recHealth.Body.String(), `"ok":true`) {
		t.Fatalf("expected 200 OK JSON health response, got %d %s", recHealth.Code, recHealth.Body.String())
	}

	reqMeta := httptest.NewRequest(http.MethodGet, "http://169.254.169.254/latest/meta-data/", nil)
	reqMeta.Host = "169.254.169.254"
	recMeta := httptest.NewRecorder()
	router(recMeta, reqMeta)
	if recMeta.Code != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden for metadata SSRF, got %d", recMeta.Code)
	}
}
