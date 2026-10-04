package main

import (
	"encoding/json"
	"fmt"
	"image"
	"strings"

	"github.com/skip2/go-qrcode"
)

func pairingPayload(cfg configuration, a adapter, name string) (string, error) {
	if err := validateConfig(cfg); err != nil {
		return "", err
	}
	if a.IP == "" || a.MAC == "" || a.Broadcast == "" {
		return "", fmt.Errorf("select a network adapter with an IPv4 and MAC address")
	}
	if strings.TrimSpace(name) == "" {
		name = "Windows PC"
	}
	raw, err := json.Marshal(struct {
		Type      string `json:"type"`
		Version   int    `json:"version"`
		Name      string `json:"name"`
		URL       string `json:"url"`
		Token     string `json:"token"`
		MAC       string `json:"mac"`
		Broadcast string `json:"broadcast"`
	}{"pc-control", 1, name, agentURL(cfg, a.IP), cfg.Token, a.MAC, a.Broadcast})
	if err != nil {
		return "", err
	}
	if len(raw) > 4096 {
		return "", fmt.Errorf("connection details are too large for pairing")
	}
	return string(raw), nil
}

func pairingImage(payload string) (image.Image, error) {
	code, err := qrcode.New(payload, qrcode.Medium)
	if err != nil {
		return nil, fmt.Errorf("could not create connection QR code")
	}
	// Whole-pixel modules and the encoder's quiet zone keep scanning reliable.
	return code.Image(-4), nil
}
