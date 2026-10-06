package main

import (
	"bytes"
	"image/png"
	"strings"
	"testing"
)

func TestRenderLinuxPairing(t *testing.T) {
	input := `{"config":{"listen":"0.0.0.0:8787","token":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},"adapter":{"ip":"192.168.1.50","mac":"AA:BB:CC:DD:EE:FF","broadcast":"192.168.1.255"},"name":"Linux PC"}`
	var output bytes.Buffer
	if err := renderPairing(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	image, err := png.Decode(&output)
	if err != nil || image.Bounds().Dx() < 200 || image.Bounds().Dx() != image.Bounds().Dy() {
		t.Fatal("valid square QR PNG was not generated")
	}
	for _, bad := range []string{`{`, `{}`, input + `{}`, strings.Replace(input, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "short", 1)} {
		output.Reset()
		if err := renderPairing(strings.NewReader(bad), &output); err == nil || output.Len() != 0 {
			t.Fatal("invalid request generated an image")
		}
	}
}
