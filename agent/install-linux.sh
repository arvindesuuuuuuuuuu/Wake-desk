#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo after building pc-agent-linux." >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$script_dir/pc-agent-linux"
if [ ! -f "$binary" ]; then
  echo "Missing $binary. Build it with: go build -o pc-agent-linux ." >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "A systemd system manager is required." >&2
  exit 1
fi

install -d -m 0700 /etc/wakedesk
if [ ! -e /etc/wakedesk/config.json ]; then
  token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  umask 077
  printf '{"listen":"0.0.0.0:8787","token":"%s"}\n' "$token" > /etc/wakedesk/config.json
fi
chmod 0600 /etc/wakedesk/config.json
install -m 0755 "$binary" /usr/local/bin/wakedesk-agent
install -m 0644 "$script_dir/wakedesk-agent.service" /etc/systemd/system/wakedesk-agent.service
systemctl daemon-reload
systemctl enable wakedesk-agent.service
systemctl restart wakedesk-agent.service
echo "WakeDesk agent installed. Read the phone access token from /etc/wakedesk/config.json using sudo."
