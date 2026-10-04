package main

import (
	"fmt"
	"os/exec"
	"syscall"
)

func uptime() uint64 {
	value, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("GetTickCount64").Call()
	return uint64(value) / 1000
}

func executeCommand(command string) error {
	switch command {
	case "shutdown", "restart":
		option := "/s"
		if command == "restart" {
			option = "/r"
		}
		// No force flag: applications can protect unsaved work.
		cmd := exec.Command("shutdown.exe", option, "/t", "0")
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		return cmd.Run()
	case "lock":
		result, _, err := syscall.NewLazyDLL("user32.dll").NewProc("LockWorkStation").Call()
		if result == 0 {
			return fmt.Errorf("LockWorkStation: %v", err)
		}
		return nil
	case "sleep":
		// PowerShell enables the suspend privilege through the Windows Forms API.
		cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", `Add-Type -AssemblyName System.Windows.Forms; if (-not [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)) { exit 1 }`)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		// The call may only finish on resume. Reap it in the background.
		if err := cmd.Start(); err != nil {
			return err
		}
		go func() { _ = cmd.Wait() }()
		return nil
	}
	return fmt.Errorf("unsupported command")
}
