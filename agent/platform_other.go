//go:build !windows && !linux

package main

import "fmt"

func uptime() uint64              { return 0 }
func executeCommand(string) error { return fmt.Errorf("Windows or Linux is required") }
