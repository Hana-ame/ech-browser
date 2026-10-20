package netdial

import (
	"bytes"
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func TestIsCloudflareIP(t *testing.T) {
	cfIPs := []string{
		"104.16.132.229",
		"172.67.150.10",
		"162.158.1.1",
		"2606:4700::6810:84e5",
	}
	for _, s := range cfIPs {
		if !IsCloudflareIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be recognized as Cloudflare IP", s)
		}
	}

	nonCFIPs := []string{
		"8.8.8.8",
		"140.82.121.4",
		"210.140.139.130",
		"127.0.0.1",
	}
	for _, s := range nonCFIPs {
		if IsCloudflareIP(net.ParseIP(s)) {
			t.Errorf("expected %s NOT to be Cloudflare IP", s)
		}
	}
	if IsCloudflareIP(nil) {
		t.Error("expected nil IP to return false")
	}
}

func TestIsLocalOrLinkLocalIP(t *testing.T) {
	locals := []string{
		"127.0.0.1",
		"127.0.0.2",
		"::1",
		"0.0.0.0",
		"::",
		"169.254.169.254",
		"fe80::1",
	}
	for _, s := range locals {
		if !IsLocalOrLinkLocalIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be detected as local/link-local", s)
		}
	}
	if IsLocalOrLinkLocalIP(net.ParseIP("104.16.0.1")) {
		t.Error("expected public IP not to be local")
	}
}

func TestSplitClientHelloChunks(t *testing.T) {
	httpReq := []byte("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
	chunks := SplitClientHelloChunks(httpReq)
	if len(chunks) != 1 || !bytes.Equal(chunks[0], httpReq) {
		t.Fatalf("expected non-TLS data to remain 1 chunk, got %d", len(chunks))
	}

	clientHello := make([]byte, 240)
	clientHello[0] = 0x16
	clientHello[1] = 0x03
	clientHello[2] = 0x01
	for i := 3; i < len(clientHello); i++ {
		clientHello[i] = byte(i)
	}
	tlsChunks := SplitClientHelloChunks(clientHello)
	if len(tlsChunks) != 4 {
		t.Fatalf("expected 4 chunks for TLS ClientHello, got %d", len(tlsChunks))
	}
	rebuilt := bytes.Join(tlsChunks, nil)
	if !bytes.Equal(rebuilt, clientHello) {
		t.Fatal("rejoined chunks do not match original ClientHello")
	}
}

func TestRetry(t *testing.T) {
	calls := 0
	val, err := Retry(context.Background(), 3, 5*time.Millisecond, func() (int, error) {
		calls++
		if calls < 3 {
			return 0, errors.New("temporary error")
		}
		return 42, nil
	})
	if err != nil || val != 42 || calls != 3 {
		t.Fatalf("expected val=42 calls=3 err=nil, got val=%d calls=%d err=%v", val, calls, err)
	}
}
