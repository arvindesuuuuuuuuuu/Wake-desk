//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func uptime() uint64 {
	raw, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(raw))
	if len(fields) == 0 {
		return 0
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || seconds < 0 {
		return 0
	}
	return uint64(seconds)
}

func linuxCommand(command string) (string, []string, error) {
	switch command {
	case "shutdown":
		return "systemctl", []string{"--no-ask-password", "--no-block", "poweroff"}, nil
	case "restart":
		return "systemctl", []string{"--no-ask-password", "--no-block", "reboot"}, nil
	case "sleep":
		return "systemctl", []string{"--no-ask-password", "--no-block", "suspend"}, nil
	case "lock":
		return "loginctl", []string{"--no-ask-password", "lock-sessions"}, nil
	default:
		return "", nil, fmt.Errorf("unsupported command")
	}
}

func executeCommand(command string) error {
	name, args, err := linuxCommand(command)
	if err != nil {
		return err
	}
	output, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s failed: %w: %s", name, err, strings.TrimSpace(string(output)))
	}
	return nil
}
