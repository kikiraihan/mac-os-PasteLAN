package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// templatePassword = contoh di deploy/pastelan.env.example. Server menolak berjalan kalau password ini dipakai apa adanya.
const templatePassword = "GANTI-dengan-password-acak"

const pbkdf2Iter = 600_000

// settings = konfigurasi yang bisa diubah dari halaman admin. Disimpan di settings.json (0600, tanpa isi clipboard).
type settings struct {
	PasswordLogin    bool   `json:"passwordLogin"`            // perangkat boleh login dengan password bersama
	DevicePassword   string `json:"devicePassword,omitempty"` // hash PBKDF2 password bersama (kosong → PASTELAN_PASSWORD)
	AdminPassword    string `json:"adminPassword,omitempty"`  // hash PBKDF2 password admin (kosong → PASTELAN_ADMIN_PASSWORD)
	AutoClear        bool   `json:"autoClear"`                // hapus isi clipboard otomatis setelah RetentionMinutes
	RetentionMinutes int    `json:"retentionMinutes"`
	MaxItems         int    `json:"maxItems"`
	MaxTotalMB       int    `json:"maxTotalMB"`
	SetupLinkMinutes int    `json:"setupLinkMinutes"` // masa berlaku link setup dari admin
}

func defaultSettings(envPassword bool) settings {
	return settings{PasswordLogin: envPassword, AutoClear: true, RetentionMinutes: 24 * 60,
		MaxItems: defaultMaxItems, MaxTotalMB: defaultMaxTotalMB, SetupLinkMinutes: 10}
}

// validate memeriksa batas nilai yang boleh diatur admin
func (s settings) validate() error {
	switch {
	case s.RetentionMinutes < 1 || s.RetentionMinutes > 30*24*60:
		return errors.New("lama penyimpanan harus 1 menit – 30 hari")
	case s.MaxItems < 1 || s.MaxItems > 200:
		return errors.New("jumlah item harus 1–200")
	case s.MaxTotalMB < 1 || s.MaxTotalMB > 1024:
		return errors.New("total memori harus 1–1024 MB")
	case s.SetupLinkMinutes < 1 || s.SetupLinkMinutes > 60:
		return errors.New("masa berlaku link setup harus 1–60 menit")
	}
	return nil
}

func (s settings) limits() limits {
	l := limits{maxItems: s.MaxItems, maxTotal: s.MaxTotalMB << 20}
	if s.AutoClear {
		l.ttl = time.Duration(s.RetentionMinutes) * time.Minute
	}
	return l
}

type settingsStore struct {
	mu   sync.Mutex
	file string
	cur  settings
}

func loadSettings(file string, envPassword bool) (*settingsStore, error) {
	st := &settingsStore{file: file, cur: defaultSettings(envPassword)}
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &st.cur); err != nil {
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	if err := st.cur.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	return st, nil
}

func (st *settingsStore) get() settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.cur
}

// update menyimpan perubahan secara atomik (izin 0600); gagal simpan → nilai lama tetap dipakai
func (st *settingsStore) update(f func(*settings) error) (settings, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	next := st.cur
	if err := f(&next); err != nil {
		return st.cur, err
	}
	if err := next.validate(); err != nil {
		return st.cur, err
	}
	b, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return st.cur, err
	}
	tmp := st.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return st.cur, err
	}
	if err := os.Rename(tmp, st.file); err != nil {
		return st.cur, err
	}
	st.cur = next
	return next, nil
}

// hashPassword: PBKDF2-SHA256 dengan salt acak, format "pbkdf2-sha256$iter$salt$hash" (base64)
func hashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	k, err := pbkdf2.Key(sha256.New, pw, salt, pbkdf2Iter, 32)
	if err != nil {
		return "", err
	}
	enc := base64.RawStdEncoding.EncodeToString
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iter, enc(salt), enc(k)), nil
}

func checkPasswordHash(pw, stored string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	var iter int
	if _, err := fmt.Sscanf(parts[1], "%d", &iter); err != nil || iter < 1 || iter > 10_000_000 {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(parts[2])
	want, err2 := base64.RawStdEncoding.DecodeString(parts[3])
	if err1 != nil || err2 != nil || len(want) == 0 {
		return false
	}
	k, err := pbkdf2.Key(sha256.New, pw, salt, iter, len(want))
	return err == nil && subtle.ConstantTimeCompare(k, want) == 1
}

// checkNewPassword: aturan password admin / perangkat
func checkNewPassword(pw string) error {
	switch {
	case len([]rune(pw)) < 12:
		return errors.New("password minimal 12 karakter")
	case pw == templatePassword:
		return errors.New("password masih contoh dari pastelan.env.example, ganti dengan password acak")
	}
	return nil
}
