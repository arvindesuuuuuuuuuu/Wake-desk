package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestConfigValidation(t *testing.T) {
	token := strings.Repeat("a", 32)
	for _, listen := range []string{"0.0.0.0:8787", "127.0.0.1:8787", "[::]:8787", "localhost:8787"} {
		if err := validateConfig(configuration{Listen: listen, Token: token}); err != nil {
			t.Errorf("%s: %v", listen, err)
		}
	}
	for _, listen := range []string{"bad", "0.0.0.0:0", "0.0.0.0:65536", "example.com:8787"} {
		if err := validateConfig(configuration{Listen: listen, Token: token}); err == nil {
			t.Errorf("accepted %s", listen)
		}
	}
	if err := validateConfig(configuration{Listen: "0.0.0.0:8787", Token: "short"}); err == nil {
		t.Fatal("accepted short token")
	}
	if err := validateConfig(configuration{Listen: "0.0.0.0:8787", Token: token, Cert: "cert.pem"}); err == nil {
		t.Fatal("accepted incomplete TLS")
	}
}

func TestAgentURL(t *testing.T) {
	for _, tc := range []struct {
		cfg           configuration
		address, want string
	}{
		{configuration{Listen: "0.0.0.0:8787"}, "192.168.1.50", "http://192.168.1.50:8787"},
		{configuration{Listen: "127.0.0.1:1234"}, "192.168.1.50", "http://127.0.0.1:1234"},
		{configuration{Listen: "[::]:8787", Cert: "cert"}, "::1", "https://[::1]:8787"},
	} {
		if got := agentURL(tc.cfg, tc.address); got != tc.want {
			t.Errorf("got %s want %s", got, tc.want)
		}
	}
}

func TestStatusAuthentication(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/status" || r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, "unauthorized", 401)
			return
		}
		w.Write([]byte(`{"name":"DESKTOP","uptime_seconds":123}`))
	}))
	defer server.Close()
	cfg := configuration{Listen: strings.TrimPrefix(server.URL, "http://"), Token: "test-token"}
	info, err := fetchStatus(cfg)
	if err != nil || info.Name != "DESKTOP" || info.Uptime != 123 {
		t.Fatalf("status=%+v err=%v", info, err)
	}
	cfg.Token = "wrong"
	if _, err := fetchStatus(cfg); err == nil {
		t.Fatal("authentication failure was ignored")
	}
}

func TestTokenGeneration(t *testing.T) {
	first, err := newToken()
	if err != nil {
		t.Fatal(err)
	}
	second, err := newToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(first) < 32 || first == second {
		t.Fatal("tokens must be long and distinct")
	}
}

func TestStopRequestAndLegacyFallback(t *testing.T) {
	for _, code := range []int{200, 404, 401} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "POST" || r.URL.Path != "/v1/agent/stop" || r.Header.Get("Authorization") != "Bearer test-token" {
				t.Error("incorrect stop request")
			}
			w.WriteHeader(code)
		}))
		cfg := configuration{Listen: strings.TrimPrefix(server.URL, "http://"), Token: "test-token"}
		supported, err := requestAgentStop(cfg)
		server.Close()
		if supported != (code == 200) || (err != nil) != (code == 401) {
			t.Errorf("HTTP %d: supported=%v err=%v", code, supported, err)
		}
	}
}
