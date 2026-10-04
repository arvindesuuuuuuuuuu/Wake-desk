package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type config struct {
	Listen string `json:"listen"`
	Token  string `json:"token"`
	Cert   string `json:"tls_cert,omitempty"`
	Key    string `json:"tls_key,omitempty"`
}

type status struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
	Uptime    uint64   `json:"uptime_seconds"`
}

func handler(token string, info func() status, execute func(string) error, stop func()) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/agent/stop", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			http.Error(w, "method not allowed", 405)
			return
		}
		if stop == nil {
			http.Error(w, "agent stop unavailable", 503)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "stopping"})
		stop()
	})
	mux.HandleFunc("/v1/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "method not allowed", 405)
			return
		}
		json.NewEncoder(w).Encode(info())
	})
	mux.HandleFunc("/v1/commands", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			http.Error(w, "method not allowed", 405)
			return
		}
		var body struct {
			Command string `json:"command"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			http.Error(w, "invalid JSON", 400)
			return
		}
		if err := dec.Decode(new(any)); err != io.EOF {
			http.Error(w, "expected one JSON object", 400)
			return
		}
		switch body.Command {
		case "shutdown", "restart", "sleep", "lock":
		default:
			http.Error(w, "unknown command", 400)
			return
		}
		if err := execute(body.Command); err != nil {
			log.Printf("command %s failed: %v", body.Command, err)
			http.Error(w, "System rejected the command", 500)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "requested"})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || subtle.ConstantTimeCompare([]byte(auth), []byte(token)) != 1 {
			http.Error(w, "unauthorized", 401)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func systemStatus() status {
	name, _ := os.Hostname()
	result := status{Name: name, Addresses: []string{}, Uptime: uptime()}
	addrs, _ := net.InterfaceAddrs()
	for _, addr := range addrs {
		if ip, ok := addr.(*net.IPNet); ok && !ip.IP.IsLoopback() && ip.IP.To4() != nil {
			result.Addresses = append(result.Addresses, ip.IP.String())
		}
	}
	return result
}

func main() {
	path := flag.String("config", "config.json", "configuration file")
	flag.Parse()
	raw, err := os.ReadFile(*path)
	if err != nil {
		log.Fatal(err)
	}
	var cfg config
	if err = json.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	if len(cfg.Token) < 32 {
		log.Fatal("token must contain at least 32 characters")
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:8787"
	}
	if (cfg.Cert == "") != (cfg.Key == "") {
		log.Fatal("both TLS certificate and key are required")
	}
	server := &http.Server{Addr: cfg.Listen, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	stopped := make(chan struct{})
	var once sync.Once
	server.Handler = handler(cfg.Token, systemStatus, executeCommand, func() {
		once.Do(func() {
			go func() {
				defer close(stopped)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if err := server.Shutdown(ctx); err != nil {
					log.Printf("agent shutdown: %v", err)
				}
			}()
		})
	})
	fmt.Printf("WakeDesk agent listening on %s\n", cfg.Listen)
	if cfg.Cert != "" {
		err = server.ListenAndServeTLS(cfg.Cert, cfg.Key)
	} else {
		err = server.ListenAndServe()
	}
	if errors.Is(err, http.ErrServerClosed) {
		<-stopped
		return
	}
	log.Fatal(err)
}
