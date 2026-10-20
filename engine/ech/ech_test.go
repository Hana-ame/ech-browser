package cloudflare_ech

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"testing"
)

func TestParseSVCBWire(t *testing.T) {
	wire := []byte{
		0x00, 0x01,
		0x00,
		0x00, 0x05,
		0x00, 0x04,
		0xde, 0xad, 0xbe, 0xef,
	}
	cfg, err := parseSVCBWire(wire)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !bytes.Equal(cfg, []byte{0xde, 0xad, 0xbe, 0xef}) {
		t.Fatalf("unexpected ECH config: %x", cfg)
	}

	if _, err := parseSVCBWire([]byte{0x00}); err == nil {
		t.Fatal("expected error on truncated wire")
	}
}

func TestIsRouteRejection(t *testing.T) {
	resp530 := &http.Response{StatusCode: 530}
	if !isRouteRejection(resp530, "ech") {
		t.Error("expected 530 to be rejected in ech mode")
	}
	resp421 := &http.Response{StatusCode: 421}
	if !isRouteRejection(resp421, "sni") {
		t.Error("expected 421 Misdirected Request to be rejected in sni mode")
	}
	resp200 := &http.Response{StatusCode: 200}
	if isRouteRejection(resp200, "ech") || isRouteRejection(resp200, "sni") {
		t.Error("expected 200 OK not to be rejected")
	}
}

func TestResolveHostIPsLiteral(t *testing.T) {
	ips, err := ResolveHostIPs(context.Background(), "210.140.139.130:443")
	if err != nil {
		t.Fatalf("unexpected error for IP literal: %v", err)
	}
	if len(ips) != 1 || ips[0] != "210.140.139.130" {
		t.Fatalf("expected [210.140.139.130], got %v", ips)
	}
}

func TestCloneRequestForAttemptReplayBody(t *testing.T) {
	payload := []byte(`{"illust_id":"12345"}`)
	req, err := http.NewRequest(http.MethodPost, "https://www.pixiv.net/rpc/index.php", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	req.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(payload)), nil
	}

	for i := 0; i < 3; i++ {
		cloned, err := cloneRequestForAttempt(req)
		if err != nil {
			t.Fatalf("attempt %d clone failed: %v", i, err)
		}
		got, err := io.ReadAll(cloned.Body)
		_ = cloned.Body.Close()
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("attempt %d body mismatch: got %q, err %v", i, got, err)
		}
	}
}
