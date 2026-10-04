package main

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAPI(t *testing.T) {
	for _, tc := range []struct {
		name, method, path, token, body string
		want, calls                     int
	}{
		{"unauthenticated", "POST", "/v1/commands", "", `{"command":"shutdown"}`, 401, 0},
		{"incorrect token", "GET", "/v1/status", "wrong", "", 401, 0},
		{"status", "GET", "/v1/status", "secret", "", 200, 0},
		{"wrong method", "GET", "/v1/commands", "secret", "", 405, 0},
		{"unknown command", "POST", "/v1/commands", "secret", `{"command":"shell"}`, 400, 0},
		{"extra field", "POST", "/v1/commands", "secret", `{"command":"lock","args":"x"}`, 400, 0},
		{"trailing JSON", "POST", "/v1/commands", "secret", `{"command":"lock"}{}`, 400, 0},
		{"valid", "POST", "/v1/commands", "secret", `{"command":"lock"}`, 200, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			h := handler("secret", func() status { return status{Name: "test-pc", Uptime: 123} }, func(string) error { calls++; return nil }, nil)
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			if tc.token != "" {
				r.Header.Set("Authorization", "Bearer "+tc.token)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want || calls != tc.calls {
				t.Fatalf("status=%d calls=%d", w.Code, calls)
			}
		})
	}
}

func TestCommandFailure(t *testing.T) {
	h := handler("secret", func() status { return status{} }, func(string) error { return errors.New("denied") }, nil)
	r := httptest.NewRequest("POST", "/v1/commands", strings.NewReader(`{"command":"lock"}`))
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 500 {
		t.Fatalf("status=%d", w.Code)
	}
}

func TestAgentStopIsAuthenticatedAndDoesNotExecutePowerCommands(t *testing.T) {
	for _, tc := range []struct {
		method, token string
		want, calls   int
	}{
		{"POST", "", 401, 0}, {"POST", "wrong", 401, 0}, {"GET", "secret", 405, 0}, {"POST", "secret", 200, 1},
	} {
		stops := 0
		h := handler("secret", func() status { return status{} }, func(string) error { t.Fatal("agent stop must not execute a PC power command"); return nil }, func() { stops++ })
		r := httptest.NewRequest(tc.method, "/v1/agent/stop", nil)
		if tc.token != "" {
			r.Header.Set("Authorization", "Bearer "+tc.token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want || stops != tc.calls {
			t.Fatalf("status=%d stops=%d", w.Code, stops)
		}
	}
}
