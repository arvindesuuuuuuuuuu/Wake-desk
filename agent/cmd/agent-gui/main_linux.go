package main

import (
	"encoding/json"
	"fmt"
	"image/png"
	"io"
	"os"
)

// The Linux GTK panel sends credentials through stdin and receives an in-memory
// PNG. Reuse the Windows pairing format and encoder without putting tokens in
// command-line arguments or temporary image files.
func renderPairing(input io.Reader, output io.Writer) error {
	var request struct {
		Config  configuration `json:"config"`
		Adapter adapter       `json:"adapter"`
		Name    string        `json:"name"`
	}
	decoder := json.NewDecoder(io.LimitReader(input, 8193))
	if err := decoder.Decode(&request); err != nil {
		return fmt.Errorf("invalid pairing request")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("expected one pairing request")
	}
	payload, err := pairingPayload(request.Config, request.Adapter, request.Name)
	if err != nil {
		return err
	}
	image, err := pairingImage(payload)
	if err != nil {
		return err
	}
	return png.Encode(output, image)
}

func main() {
	if err := renderPairing(os.Stdin, os.Stdout); err != nil {
		// Keep credentials and request bodies out of diagnostics.
		fmt.Fprintln(os.Stderr, "Could not generate the connection QR code.")
		os.Exit(1)
	}
}
