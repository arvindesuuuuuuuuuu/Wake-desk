#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo to configure Ubuntu phone sign-in." >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pam_file=/etc/pam.d/gdm-password
marker='# WakeDesk phone approval (password fallback remains below)'
rule='auth [success=done default=ignore] pam_exec.so quiet /usr/local/lib/wakedesk/pam-approve'

if [ "${1:-}" = "--remove" ]; then
  if [ -f "$pam_file" ]; then
    temporary=$(mktemp "${pam_file}.wakedesk.XXXXXX")
    awk -v marker="$marker" -v rule="$rule" '$0 != marker && $0 != rule' "$pam_file" > "$temporary"
    chmod --reference="$pam_file" "$temporary"
    chown --reference="$pam_file" "$temporary"
    mv "$temporary" "$pam_file"
  fi
  rm -f /usr/local/lib/wakedesk/pam-approve
  echo "WakeDesk phone sign-in removed; normal password sign-in is unchanged."
  exit 0
fi

if [ ! -f "$pam_file" ]; then
  echo "GDM password PAM configuration was not found at $pam_file." >&2
  exit 1
fi
install -d -m 0755 /usr/local/lib/wakedesk
install -m 0755 "$script_dir/pam-approve" /usr/local/lib/wakedesk/pam-approve
if ! grep -Fqx "$rule" "$pam_file"; then
  cp -a "$pam_file" "$pam_file.wakedesk-backup"
  temporary=$(mktemp "${pam_file}.wakedesk.XXXXXX")
  {
    head -n 1 "$pam_file"
    echo "$marker"
    echo "$rule"
    tail -n +2 "$pam_file"
  } > "$temporary"
  chmod --reference="$pam_file" "$temporary"
  chown --reference="$pam_file" "$temporary"
  mv "$temporary" "$pam_file"
fi
echo "WakeDesk phone sign-in enabled for GDM. Password sign-in remains available."
