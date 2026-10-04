//go:build linux

package main

import "testing"

func TestLinuxCommandMapping(t *testing.T) {
	for _, tc := range []struct {
		command, name, lastArg string
	}{
		{"shutdown", "systemctl", "poweroff"},
		{"restart", "systemctl", "reboot"},
		{"sleep", "systemctl", "suspend"},
		{"lock", "loginctl", "lock-sessions"},
	} {
		name, args, err := linuxCommand(tc.command)
		if err != nil || name != tc.name || len(args) == 0 || args[len(args)-1] != tc.lastArg {
			t.Fatalf("%s mapped to %s %v: %v", tc.command, name, args, err)
		}
	}
	if _, _, err := linuxCommand("shell"); err == nil {
		t.Fatal("unsupported command was accepted")
	}
}

func TestLinuxUptime(t *testing.T) {
	if uptime() == 0 {
		t.Fatal("expected positive host uptime from /proc/uptime")
	}
}
