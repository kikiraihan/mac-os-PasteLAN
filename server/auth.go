package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	maxDevices     = 20
	maxFailsPerIP  = 5                // salah password berturut-turut dari satu IP …
	ipLockout      = 15 * time.Minute // … → IP itu dikunci sementara
	maxFailsGlobal = 100              // total salah password per jam dari semua IP …
	globalLockout  = 15 * time.Minute // … → login baru ditutup sementara (perangkat yang sudah login tetap jalan)
	pairTTL        = 5 * time.Minute  // kode QR pairing berlaku 5 menit, sekali pakai
	maxPairCodes   = 10
)

var (
	errBadPassword = errors.New("password salah")
	errLocked      = errors.New("terlalu banyak percobaan, coba lagi nanti")
	errTooMany     = errors.New("terlalu banyak perangkat, cabut perangkat lama dulu")
	errBadPair     = errors.New("kode QR tidak berlaku (kedaluwarsa / sudah dipakai), minta QR baru atau masuk dengan password")
)

// device = satu perangkat yang sudah login. Token aslinya hanya dikirim sekali ke perangkat;
// server hanya menyimpan hash SHA-256-nya.
type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"tokenHash"`
	Created   time.Time `json:"created"`
	LastSeen  time.Time `json:"lastSeen"`
}

type failInfo struct {
	count int
	until time.Time
	last  time.Time
}

type auth struct {
	mu        sync.Mutex
	pwHash    [32]byte
	file      string
	devices   map[string]*device   // kunci: hash token
	pairs     map[string]time.Time // hash kode pairing → kedaluwarsa (hanya di memori)
	fails     map[string]*failInfo
	globalLog []time.Time // waktu salah password (1 jam terakhir)
	globalTil time.Time
}

func newAuth(password, file string) (*auth, error) {
	a := &auth{pwHash: sha256.Sum256([]byte(password)), file: file,
		devices: map[string]*device{}, fails: map[string]*failInfo{}, pairs: map[string]time.Time{}}
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return nil, err
	}
	var list []*device
	if err := json.Unmarshal(b, &list); err != nil {
		return nil, err
	}
	for _, d := range list {
		a.devices[d.TokenHash] = d
	}
	return a, nil
}

func randomString(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

// limitKey: IPv6 dibatasi per /64 (satu pelanggan biasanya punya satu /64 utuh)
func limitKey(ip string) string {
	p := net.ParseIP(ip)
	if p != nil && p.To4() == nil {
		return p.Mask(net.CIDRMask(64, 128)).String()
	}
	return ip
}

func cleanName(s string) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, s))
	if utf8.RuneCountInString(s) > 40 {
		s = string([]rune(s)[:40])
	}
	if s == "" {
		s = "Perangkat"
	}
	return s
}

// login memeriksa password lalu membuat token baru untuk perangkat ini
func (a *auth) login(ip, password, name string) (string, *device, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	key := limitKey(ip)
	if a.locked(key, now) {
		return "", nil, errLocked
	}
	h := sha256.Sum256([]byte(password))
	if subtle.ConstantTimeCompare(h[:], a.pwHash[:]) != 1 {
		a.recordFail(key, now)
		return "", nil, errBadPassword
	}
	delete(a.fails, key)
	return a.newDevice(name, now)
}

// newPair membuat kode pairing sekali pakai (untuk QR di Mac): perangkat baru bisa login tanpa mengetik password.
// Server hanya menyimpan hash kodenya.
func (a *auth) newPair() (string, time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	for h, exp := range a.pairs {
		if now.After(exp) {
			delete(a.pairs, h)
		}
	}
	for len(a.pairs) >= maxPairCodes { // buang yang paling cepat kedaluwarsa
		var oldest string
		for h, exp := range a.pairs {
			if oldest == "" || exp.Before(a.pairs[oldest]) {
				oldest = h
			}
		}
		delete(a.pairs, oldest)
	}
	code := randomString(32)
	exp := now.Add(pairTTL)
	a.pairs[hashToken(code)] = exp
	return code, exp
}

// claimPair menukar kode pairing dengan token perangkat baru. Kode salah dihitung seperti password salah.
func (a *auth) claimPair(ip, code, name string) (string, *device, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	key := limitKey(ip)
	if a.locked(key, now) {
		return "", nil, errLocked
	}
	h := hashToken(code)
	exp, ok := a.pairs[h]
	if !ok || now.After(exp) {
		delete(a.pairs, h)
		a.recordFail(key, now)
		return "", nil, errBadPair
	}
	delete(a.pairs, h) // sekali pakai
	delete(a.fails, key)
	return a.newDevice(name, now)
}

// locked: IP ini / semua login baru sedang dikunci (dipanggil dengan a.mu terkunci)
func (a *auth) locked(key string, now time.Time) bool {
	if now.Before(a.globalTil) {
		return true
	}
	f := a.fails[key]
	return f != nil && now.Before(f.until)
}

// newDevice membuat token baru untuk perangkat (dipanggil dengan a.mu terkunci)
func (a *auth) newDevice(name string, now time.Time) (string, *device, error) {
	if len(a.devices) >= maxDevices {
		return "", nil, errTooMany
	}
	token := randomString(32)
	d := &device{ID: randomString(9), Name: cleanName(name), TokenHash: hashToken(token), Created: now, LastSeen: now}
	a.devices[d.TokenHash] = d
	if err := a.save(); err != nil {
		delete(a.devices, d.TokenHash)
		return "", nil, err
	}
	return token, d, nil
}

func (a *auth) recordFail(key string, now time.Time) {
	f := a.fails[key]
	if f == nil {
		if len(a.fails) > 10000 { // jangan biarkan peta tumbuh tanpa batas
			for k, v := range a.fails {
				if now.Sub(v.last) > time.Hour {
					delete(a.fails, k)
				}
			}
		}
		f = &failInfo{}
		a.fails[key] = f
	}
	f.count++
	f.last = now
	if f.count >= maxFailsPerIP {
		f.count = 0
		f.until = now.Add(ipLockout)
	}
	cut := 0
	for cut < len(a.globalLog) && now.Sub(a.globalLog[cut]) > time.Hour {
		cut++
	}
	a.globalLog = append(a.globalLog[cut:], now)
	if len(a.globalLog) >= maxFailsGlobal {
		a.globalLog = nil
		a.globalTil = now.Add(globalLockout)
	}
}

// check mengembalikan perangkat pemilik token, atau nil
func (a *auth) check(token string) *device {
	if token == "" {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	d := a.devices[hashToken(token)] // kunci = hash → perbandingan tidak bergantung pada isi token
	if d == nil {
		return nil
	}
	d.LastSeen = time.Now()
	cp := *d
	return &cp
}

func (a *auth) revoke(id string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for h, d := range a.devices {
		if d.ID == id {
			delete(a.devices, h)
			_ = a.save()
			return true
		}
	}
	return false
}

func (a *auth) list() []device {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]device, 0, len(a.devices))
	for _, d := range a.devices {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created.Before(out[j].Created) })
	return out
}

// save menulis devices.json secara atomik dengan izin 0600 (dipanggil dengan a.mu terkunci)
func (a *auth) save() error {
	list := make([]*device, 0, len(a.devices))
	for _, d := range a.devices {
		list = append(list, d)
	}
	b, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	tmp := a.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.file)
}
