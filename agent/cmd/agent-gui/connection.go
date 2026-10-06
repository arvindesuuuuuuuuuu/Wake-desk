package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type configuration struct {
	Listen string `json:"listen"`
	Token  string `json:"token"`
	Cert   string `json:"tls_cert,omitempty"`
	Key    string `json:"tls_key,omitempty"`
}

func newToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(bytes), nil
}

func validateConfig(c configuration) error {
	host, port, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return fmt.Errorf("listen address must be an IP and port, such as 0.0.0.0:8787")
	}
	if host != "" && net.ParseIP(host) == nil && host != "localhost" {
		return fmt.Errorf("use an IP address or localhost")
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return fmt.Errorf("port must be between 1 and 65535")
	}
	if len(c.Token) < 32 {
		return fmt.Errorf("access token must contain at least 32 characters")
	}
	if (c.Cert == "") != (c.Key == "") {
		return fmt.Errorf("TLS certificate and key must both be configured")
	}
	return nil
}

func readConfig(path string) (configuration, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return configuration{}, err
	}
	var cfg configuration
	err = json.Unmarshal([]byte(strings.TrimPrefix(string(raw), "\ufeff")), &cfg)
	if err != nil {
		return cfg, err
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:8787"
	}
	return cfg, validateConfig(cfg)
}

func agentURL(c configuration, address string) string {
	host, port, _ := net.SplitHostPort(c.Listen)
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = address
	}
	scheme := "http"
	if c.Cert != "" {
		scheme = "https"
	}
	return scheme + "://" + net.JoinHostPort(host, port)
}

type agentStatus struct {
	Name   string `json:"name"`
	Uptime uint64 `json:"uptime_seconds"`
}

func fetchStatus(c configuration) (agentStatus, error) {
	req, err := http.NewRequest("GET", agentURL(c, "127.0.0.1")+"/v1/status", nil)
	if err != nil {
		return agentStatus{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	client := http.Client{Timeout: 2 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return agentStatus{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return agentStatus{}, fmt.Errorf("agent returned HTTP %d", res.StatusCode)
	}
	var status agentStatus
	err = json.NewDecoder(res.Body).Decode(&status)
	return status, err
}

type adapter struct{ Name, Interface, IP, MAC, Broadcast string }

// Older agents lack this endpoint; callers can use their original launcher.
func requestAgentStop(c configuration) (bool, error) {
	req, err := http.NewRequest(http.MethodPost, agentURL(c, "127.0.0.1")+"/v1/agent/stop", nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	client := http.Client{Timeout: 5 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if res.StatusCode != http.StatusOK {
		return false, fmt.Errorf("agent stop returned HTTP %d", res.StatusCode)
	}
	return true, nil
}

func networkAdapters() []adapter {
	var result []adapter
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			ip, subnet, err := net.ParseCIDR(addr.String())
			if err != nil || ip.To4() == nil {
				continue
			}
			ipv4 := ip.To4()
			if ipv4.IsLinkLocalUnicast() {
				continue
			}
			broadcast := make(net.IP, 4)
			for i := range broadcast {
				broadcast[i] = ipv4[i] | ^subnet.Mask[i]
			}
			result = append(result, adapter{Name: iface.Name + " - " + ip.String(), Interface: iface.Name, IP: ip.String(), MAC: strings.ToUpper(iface.HardwareAddr.String()), Broadcast: broadcast.String()})
		}
	}
	return result
}
