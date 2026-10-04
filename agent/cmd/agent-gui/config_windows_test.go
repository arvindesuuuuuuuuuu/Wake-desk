package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSaveReplacesConfigAndRejectsInvalidChanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings", "config.json")
	original := configuration{Listen: "0.0.0.0:8787", Token: strings.Repeat("a", 32)}
	if err := writeConfig(path, original); err != nil {
		t.Fatal(err)
	}
	replacement := configuration{Listen: "127.0.0.1:9999", Token: strings.Repeat("b", 32), Cert: "cert.pem", Key: "key.pem"}
	if err := writeConfig(path, replacement); err != nil {
		t.Fatal(err)
	}
	loaded, err := readConfig(path)
	if err != nil || loaded != replacement {
		t.Fatalf("replacement did not persist: %v", err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	invalid := replacement
	invalid.Token = "short"
	if err := writeConfig(path, invalid); err == nil {
		t.Fatal("invalid changes were accepted")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("invalid changes altered the saved config")
	}
}
