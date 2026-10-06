#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"
go build -o linux-ui/pairing-qr ./cmd/agent-gui
echo "Linux QR helper built. Install the panel with: sudo sh ./install-linux-ui.sh"
