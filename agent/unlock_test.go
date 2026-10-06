package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"path/filepath"
	"testing"
	"time"
)

func TestUnlockChallengeIsSignedAndConsumedOnce(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	m, err := newUnlockManager(filepath.Join(t.TempDir(), "unlock.json"))
	if err != nil {
		t.Fatal(err)
	}
	m.devices["phone-device-1234"] = unlockDevice{ID: "phone-device-1234", Name: "Phone", User: "alice", PublicKey: base64.RawStdEncoding.EncodeToString(publicKey)}
	c, err := m.challenge("phone-device-1234")
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, []byte(c.Message))
	if err := m.approveChallenge(c.ID, base64.RawStdEncoding.EncodeToString(signature)); err != nil {
		t.Fatal(err)
	}
	if err := m.approveChallenge(c.ID, base64.RawStdEncoding.EncodeToString(signature)); err == nil {
		t.Fatal("challenge replay succeeded")
	}
	if !m.consume("alice") {
		t.Fatal("valid approval was not consumed")
	}
	if m.consume("alice") {
		t.Fatal("approval was consumed twice")
	}
}

func TestUnlockRejectsWrongSignatureAndPersistsEnrollment(t *testing.T) {
	publicKey, _, _ := ed25519.GenerateKey(rand.Reader)
	_, wrongKey, _ := ed25519.GenerateKey(rand.Reader)
	path := filepath.Join(t.TempDir(), "unlock.json")
	m, _ := newUnlockManager(path)
	device := unlockDevice{ID: "phone-device-1234", Name: "Phone", User: "alice", PublicKey: base64.RawStdEncoding.EncodeToString(publicKey)}
	m.enrollments["request"] = unlockEnrollment{RequestID: "request", unlockDevice: device, Expires: time.Now().Add(time.Minute)}
	if err := m.approveEnrollment("request"); err != nil {
		t.Fatal(err)
	}
	reloaded, err := newUnlockManager(path)
	if err != nil {
		t.Fatal(err)
	}
	c, err := reloaded.challenge(device.ID)
	if err != nil {
		t.Fatal(err)
	}
	bad := ed25519.Sign(wrongKey, []byte(c.Message))
	if err := reloaded.approveChallenge(c.ID, base64.RawStdEncoding.EncodeToString(bad)); err == nil {
		t.Fatal("wrong key was accepted")
	}
}
