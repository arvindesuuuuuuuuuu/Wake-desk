#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo to install the Linux control panel." >&2
  exit 1
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install -d -m 0755 /usr/local/lib/wakedesk /usr/local/share/applications
install -m 0644 "$script_dir/linux-ui/control.py" /usr/local/lib/wakedesk/control.py
install -m 0644 "$script_dir/linux-ui/panel.py" /usr/local/lib/wakedesk/panel.py
install -m 0755 "$script_dir/linux-ui/wakedesk-control" /usr/local/bin/wakedesk-control
install -m 0644 "$script_dir/linux-ui/wakedesk-control.desktop" /usr/local/share/applications/wakedesk-control.desktop
if [ -f "$script_dir/linux-ui/pairing-qr" ]; then
  install -m 0755 "$script_dir/linux-ui/pairing-qr" /usr/local/lib/wakedesk/pairing-qr
else
  echo "For QR pairing, run sh ./build-linux-ui.sh as your user, then reinstall the panel." >&2
fi
echo "Linux control panel installed. Open WakeDesk from your application menu."
if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "3.0")' >/dev/null 2>&1; then
  echo "Install Python GTK bindings first. Ubuntu/Debian: sudo apt install python3-gi gir1.2-gtk-3.0 pkexec iproute2" >&2
fi
