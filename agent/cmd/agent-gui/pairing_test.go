package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPairingPayload(t *testing.T) {
	cfg := configuration{Listen: "0.0.0.0:8787", Token: strings.Repeat("x", 44)}
	a := adapter{IP: "192.168.1.50", MAC: "AA:BB:CC:DD:EE:FF", Broadcast: "192.168.1.255"}
	raw, err := pairingPayload(cfg, a, "Office PC")
	if err != nil {
		t.Fatal(err)
	}
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		t.Fatal(err)
	}
	if data["type"] != "pc-control" || data["version"] != float64(1) || data["url"] != "http://192.168.1.50:8787" || data["token"] != cfg.Token || data["mac"] != a.MAC || data["broadcast"] != a.Broadcast || data["name"] != "Office PC" {
		t.Fatal("pairing fields mismatch")
	}
	im, err := pairingImage(raw)
	if err != nil || im.Bounds().Dx() < 200 {
		t.Fatal("QR image unavailable")
	}
	if _, err := pairingPayload(cfg, adapter{}, "PC"); err == nil {
		t.Fatal("missing adapter accepted")
	}
	cfg.Token = "short"
	if _, err := pairingPayload(cfg, a, "PC"); err == nil {
		t.Fatal("invalid config accepted")
	}
}
