package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"sync"
	"time"
)

const unlockSocket = "/run/wakedesk/unlock.sock"

var unixUser = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
var unlockDeviceID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)
var unlockDeviceName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$`)

type unlockDevice struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	User      string `json:"user"`
	PublicKey string `json:"public_key"`
}
type unlockEnrollment struct {
	RequestID string `json:"request_id"`
	unlockDevice
	Expires time.Time `json:"-"`
}
type unlockChallenge struct {
	ID, DeviceID, User, Message string
	Expires                     time.Time
}
type unlockApproval struct {
	DeviceID string
	Expires  time.Time
}
type unlockManager struct {
	mu          sync.Mutex
	file        string
	devices     map[string]unlockDevice
	enrollments map[string]unlockEnrollment
	challenges  map[string]unlockChallenge
	approvals   map[string]unlockApproval
}

func randomID(size int) (string, error) {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func newUnlockManager(path string) (*unlockManager, error) {
	m := &unlockManager{file: path, devices: map[string]unlockDevice{}, enrollments: map[string]unlockEnrollment{}, challenges: map[string]unlockChallenge{}, approvals: map[string]unlockApproval{}}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	var saved struct {
		Devices []unlockDevice `json:"devices"`
	}
	if err := json.Unmarshal(raw, &saved); err != nil {
		return nil, fmt.Errorf("invalid unlock device file: %w", err)
	}
	for _, d := range saved.Devices {
		key, err := base64.RawStdEncoding.DecodeString(d.PublicKey)
		if err != nil || len(key) != ed25519.PublicKeySize || !unlockDeviceID.MatchString(d.ID) || !unlockDeviceName.MatchString(d.Name) || !unixUser.MatchString(d.User) || d.User == "root" {
			return nil, fmt.Errorf("invalid unlock device file")
		}
		m.devices[d.ID] = d
	}
	return m, nil
}

func (m *unlockManager) prune(now time.Time) {
	for id, v := range m.enrollments {
		if now.After(v.Expires) {
			delete(m.enrollments, id)
		}
	}
	for id, v := range m.challenges {
		if now.After(v.Expires) {
			delete(m.challenges, id)
		}
	}
	for name, v := range m.approvals {
		if now.After(v.Expires) {
			delete(m.approvals, name)
		}
	}
}

func (m *unlockManager) requestEnrollment(d unlockDevice) (string, error) {
	key, err := base64.RawStdEncoding.DecodeString(d.PublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize || !unlockDeviceID.MatchString(d.ID) || !unlockDeviceName.MatchString(d.Name) || !unixUser.MatchString(d.User) || d.User == "root" {
		return "", fmt.Errorf("invalid enrollment")
	}
	if _, err := user.Lookup(d.User); err != nil {
		return "", fmt.Errorf("unknown local user")
	}
	id, err := randomID(18)
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	if len(m.enrollments) >= 8 {
		return "", fmt.Errorf("too many pending enrollments")
	}
	m.enrollments[id] = unlockEnrollment{RequestID: id, unlockDevice: d, Expires: time.Now().Add(5 * time.Minute)}
	return id, nil
}

func (m *unlockManager) pending() []unlockEnrollment {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	out := make([]unlockEnrollment, 0, len(m.enrollments))
	for _, v := range m.enrollments {
		out = append(out, v)
	}
	return out
}

func (m *unlockManager) approveEnrollment(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	item, ok := m.enrollments[id]
	if !ok {
		return fmt.Errorf("enrollment not found or expired")
	}
	previous, replaced := m.devices[item.ID]
	m.devices[item.ID] = item.unlockDevice
	list := make([]unlockDevice, 0, len(m.devices))
	for _, d := range m.devices {
		list = append(list, d)
	}
	raw, err := json.MarshalIndent(struct {
		Devices []unlockDevice `json:"devices"`
	}{list}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(m.file), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(m.file), ".unlock-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err = tmp.Chmod(0600); err == nil {
		_, err = tmp.Write(append(raw, '\n'))
	}
	if err == nil {
		err = tmp.Sync()
	}
	if e := tmp.Close(); err == nil {
		err = e
	}
	if err == nil {
		err = os.Rename(name, m.file)
	}
	if err != nil {
		if replaced {
			m.devices[item.ID] = previous
		} else {
			delete(m.devices, item.ID)
		}
		return err
	}
	delete(m.enrollments, id)
	return nil
}

func (m *unlockManager) challenge(deviceID string) (unlockChallenge, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	if len(m.challenges) >= 64 {
		return unlockChallenge{}, fmt.Errorf("too many pending challenges")
	}
	for id, existing := range m.challenges {
		if existing.DeviceID == deviceID {
			delete(m.challenges, id)
		}
	}
	d, ok := m.devices[deviceID]
	if !ok {
		return unlockChallenge{}, fmt.Errorf("device is not enrolled")
	}
	id, err := randomID(18)
	if err != nil {
		return unlockChallenge{}, err
	}
	nonce, err := randomID(32)
	if err != nil {
		return unlockChallenge{}, err
	}
	expires := time.Now().Add(45 * time.Second).UTC()
	message := fmt.Sprintf("wakedesk-unlock-v1\n%s\n%s\n%s\n%s\n%d", id, nonce, d.ID, d.User, expires.Unix())
	c := unlockChallenge{ID: id, DeviceID: d.ID, User: d.User, Message: message, Expires: expires}
	m.challenges[id] = c
	return c, nil
}

func (m *unlockManager) approveChallenge(id, sigText string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	c, ok := m.challenges[id]
	if !ok {
		return fmt.Errorf("challenge not found or expired")
	}
	d := m.devices[c.DeviceID]
	key, _ := base64.RawStdEncoding.DecodeString(d.PublicKey)
	sig, err := base64.RawStdEncoding.DecodeString(sigText)
	if err != nil || len(sig) != ed25519.SignatureSize || !ed25519.Verify(key, []byte(c.Message), sig) {
		return fmt.Errorf("invalid signature")
	}
	delete(m.challenges, id)
	m.approvals[c.User] = unlockApproval{DeviceID: c.DeviceID, Expires: time.Now().Add(30 * time.Second)}
	return nil
}

func (m *unlockManager) consume(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(time.Now())
	_, ok := m.approvals[name]
	if ok {
		delete(m.approvals, name)
	}
	return ok
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		http.Error(w, "expected one JSON object", 400)
		return false
	}
	return true
}

func (m *unlockManager) publicHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/unlock/enrollments", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", 405)
			return
		}
		var b unlockDevice
		if !decodeJSON(w, r, &b) {
			return
		}
		id, err := m.requestEnrollment(b)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"request_id": id, "status": "pending-local-approval"})
	})
	mux.HandleFunc("/v1/unlock/challenges", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", 405)
			return
		}
		var b struct {
			DeviceID string `json:"device_id"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		c, err := m.challenge(b.DeviceID)
		if err != nil {
			http.Error(w, err.Error(), 404)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"challenge_id": c.ID, "message": c.Message, "user": c.User, "expires": c.Expires.Unix()})
	})
	mux.HandleFunc("/v1/unlock/approvals", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", 405)
			return
		}
		var b struct {
			ChallengeID string `json:"challenge_id"`
			Signature   string `json:"signature"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		if err := m.approveChallenge(b.ChallengeID, b.Signature); err != nil {
			http.Error(w, err.Error(), 403)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "approved"})
	})
	return mux
}

func (m *unlockManager) startLocalServer() (*http.Server, error) {
	if runtime.GOOS != "linux" {
		return nil, nil
	}
	if info, err := os.Lstat(unlockSocket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("refusing to replace non-socket %s", unlockSocket)
		}
		if err := os.Remove(unlockSocket); err != nil {
			return nil, err
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	l, err := net.Listen("unix", unlockSocket)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(unlockSocket, 0600); err != nil {
		l.Close()
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/pending", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"enrollments": m.pending()})
	})
	mux.HandleFunc("/approve", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var b struct {
			RequestID string `json:"request_id"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		if err := m.approveEnrollment(b.RequestID); err != nil {
			http.Error(w, err.Error(), 404)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "approved"})
	})
	mux.HandleFunc("/consume", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var b struct {
			User string `json:"user"`
		}
		if !decodeJSON(w, r, &b) {
			return
		}
		if !m.consume(b.User) {
			http.Error(w, "no approval", 403)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "approved"})
	})
	s := &http.Server{Handler: mux, ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second}
	go s.Serve(l)
	return s, nil
}
