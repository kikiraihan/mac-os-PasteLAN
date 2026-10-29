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
	adminTTL       = 12 * time.Hour // sesi admin (hanya di memori; server restart → login admin lagi)
	maxAdminSess   = 10
)

var (
	errBadPassword = errors.New("password salah")
	errLocked      = errors.New("terlalu banyak percobaan, coba lagi nanti")
	errTooMany     = errors.New("terlalu banyak perangkat, cabut perangkat lama dulu")
	errBadPair     = errors.New("kode QR / link setup tidak berlaku (kedaluwarsa / sudah dipakai), minta yang baru")
	errPwDisabled  = errors.New("login dengan password dimatikan admin, minta link setup / scan QR dari perangkat yang sudah masuk")
	errNoAdmin     = errors.New("halaman admin belum aktif: isi PASTELAN_ADMIN_PASSWORD di server lalu restart")
)

// hashSlots membatasi hitungan PBKDF2 yang berjalan bersamaan (mahal, ±0,2 detik) → tebakan beruntun tidak menghabiskan CPU
var hashSlots = make(chan struct{}, 2)

// device = satu perangkat yang sudah login. Token aslinya hanya dikirim sekali ke perangkat;
// server hanya menyimpan hash SHA-256-nya.
type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Kind      string    `json:"kind,omitempty"` // "mac" (aplikasi menu bar), "hp", "browser"; kosong = belum diketahui
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
	pwHash    [32]byte // SHA-256 PASTELAN_PASSWORD (hanya di memori); dipakai kalau admin belum mengganti password
	hasEnvPw  bool
	adminHash [32]byte // SHA-256 PASTELAN_ADMIN_PASSWORD (hanya di memori); kalah oleh hash dari halaman admin
	hasAdmin  bool
	admins    map[string]time.Time // hash token sesi admin → kedaluwarsa (hanya di memori)
	settings  *settingsStore
	file      string
	devices   map[string]*device   // kunci: hash token
	pairs     map[string]time.Time // hash kode pairing → kedaluwarsa (hanya di memori)
	fails     map[string]*failInfo
	globalLog []time.Time // waktu salah password (1 jam terakhir)
	globalTil time.Time
}

func newAuth(password, adminPassword, file string, st *settingsStore) (*auth, error) {
	a := &auth{pwHash: sha256.Sum256([]byte(password)), hasEnvPw: password != "",
		adminHash: sha256.Sum256([]byte(adminPassword)), hasAdmin: adminPassword != "",
		admins: map[string]time.Time{}, settings: st, file: file,
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

func sha256Equal(s string, h [32]byte) bool {
	x := sha256.Sum256([]byte(s))
	return subtle.ConstantTimeCompare(x[:], h[:]) == 1
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

// clientKind: jenis perangkat. Klien baru menyebutnya sendiri ("mac" dari aplikasi menu bar, "hp" / "browser"
// dari halaman web); klien lama ditebak dari User-Agent (aplikasi Mac = URLSession → "CFNetwork" tanpa "Mozilla").
func clientKind(claimed, ua string) string {
	switch claimed {
	case "mac", "hp", "browser":
		return claimed
	}
	switch {
	case ua == "":
		return ""
	case strings.Contains(ua, "CFNetwork") && !strings.Contains(ua, "Mozilla"):
		return "mac"
	case strings.Contains(ua, "iPhone"), strings.Contains(ua, "iPad"), strings.Contains(ua, "Android"),
		strings.Contains(ua, "Mobile"):
		return "hp"
	}
	return "browser"
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

// isLocked: IP ini / semua login baru sedang dikunci
func (a *auth) isLocked(key string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.locked(key, time.Now())
}

// devicePasswordOK: password bersama perangkat (hash dari admin, atau PASTELAN_PASSWORD). Dipanggil tanpa a.mu.
func (a *auth) devicePasswordOK(set settings, password string) bool {
	if set.DevicePassword != "" {
		hashSlots <- struct{}{}
		defer func() { <-hashSlots }()
		return checkPasswordHash(password, set.DevicePassword)
	}
	h := sha256.Sum256([]byte(password))
	return a.hasEnvPw && subtle.ConstantTimeCompare(h[:], a.pwHash[:]) == 1
}

// passwordLoginAvailable: login perangkat dengan password diizinkan admin dan passwordnya sudah ada
func (a *auth) passwordLoginAvailable() bool {
	set := a.settings.get()
	return set.PasswordLogin && (set.DevicePassword != "" || a.hasEnvPw)
}

// login memeriksa password lalu membuat token baru untuk perangkat ini
func (a *auth) login(ip, password, name, kind string) (string, *device, error) {
	key := limitKey(ip)
	if a.isLocked(key) {
		return "", nil, errLocked
	}
	if !a.passwordLoginAvailable() {
		return "", nil, errPwDisabled
	}
	ok := a.devicePasswordOK(a.settings.get(), password) // di luar a.mu: PBKDF2 lambat
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if a.locked(key, now) {
		return "", nil, errLocked
	}
	if !ok {
		a.recordFail(key, now)
		return "", nil, errBadPassword
	}
	delete(a.fails, key)
	return a.newDevice(name, kind, now)
}

// adminEnabled: halaman admin aktif kalau ada PASTELAN_ADMIN_PASSWORD atau password admin dari halaman admin
func (a *auth) adminEnabled() bool {
	return a.hasAdmin || a.settings.get().AdminPassword != ""
}

// adminPasswordOK: hash dari halaman admin (PBKDF2) didahulukan, kalau belum ada pakai PASTELAN_ADMIN_PASSWORD.
// Dipanggil tanpa a.mu (PBKDF2 lambat).
func (a *auth) adminPasswordOK(password string) bool {
	if h := a.settings.get().AdminPassword; h != "" {
		hashSlots <- struct{}{}
		defer func() { <-hashSlots }()
		return checkPasswordHash(password, h)
	}
	return a.hasAdmin && sha256Equal(password, a.adminHash)
}

// adminLogin memeriksa password admin lalu membuat sesi admin. Salah password dihitung bersama login perangkat.
func (a *auth) adminLogin(ip, password string) (string, error) {
	if !a.adminEnabled() {
		return "", errNoAdmin
	}
	key := limitKey(ip)
	if a.isLocked(key) {
		return "", errLocked
	}
	ok := a.adminPasswordOK(password) // di luar a.mu
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if a.locked(key, now) {
		return "", errLocked
	}
	if !ok {
		a.recordFail(key, now)
		return "", errBadPassword
	}
	delete(a.fails, key)
	for t, exp := range a.admins {
		if now.After(exp) {
			delete(a.admins, t)
		}
	}
	for len(a.admins) >= maxAdminSess { // buang sesi yang paling cepat kedaluwarsa
		var oldest string
		for t, exp := range a.admins {
			if oldest == "" || exp.Before(a.admins[oldest]) {
				oldest = t
			}
		}
		delete(a.admins, oldest)
	}
	token := randomString(32)
	a.admins[hashToken(token)] = now.Add(adminTTL)
	return token, nil
}

// checkAdminPassword: konfirmasi password admin sekarang (mis. sebelum menggantinya). Salah → dihitung seperti login.
func (a *auth) checkAdminPassword(ip, password string) error {
	key := limitKey(ip)
	if a.isLocked(key) {
		return errLocked
	}
	ok := a.adminPasswordOK(password)
	a.mu.Lock()
	defer a.mu.Unlock()
	if !ok {
		a.recordFail(key, time.Now())
		return errBadPassword
	}
	return nil
}

// keepOnlyAdmin: setelah password admin diganti, semua sesi admin lain (perangkat / browser lain) dikeluarkan
func (a *auth) keepOnlyAdmin(token string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	keep := hashToken(token)
	for t := range a.admins {
		if t != keep {
			delete(a.admins, t)
		}
	}
}

func (a *auth) checkAdmin(token string) bool {
	if token == "" {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	h := hashToken(token)
	exp, ok := a.admins[h]
	if ok && time.Now().After(exp) {
		delete(a.admins, h)
		return false
	}
	return ok
}

func (a *auth) adminLogout(token string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.admins, hashToken(token))
}

// newPair membuat kode pairing sekali pakai (QR dari Mac / link setup dari admin): perangkat baru bisa login tanpa
// mengetik password. Server hanya menyimpan hash kodenya.
func (a *auth) newPair(ttl time.Duration) (string, time.Time) {
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
	exp := now.Add(ttl)
	a.pairs[hashToken(code)] = exp
	return code, exp
}

// claimPair menukar kode pairing dengan token perangkat baru. Kode salah dihitung seperti password salah.
func (a *auth) claimPair(ip, code, name, kind string) (string, *device, error) {
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
	return a.newDevice(name, kind, now)
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
func (a *auth) newDevice(name, kind string, now time.Time) (string, *device, error) {
	if len(a.devices) >= maxDevices {
		return "", nil, errTooMany
	}
	token := randomString(32)
	d := &device{ID: randomString(9), Name: cleanName(name), Kind: kind, TokenHash: hashToken(token), Created: now, LastSeen: now}
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

// check mengembalikan perangkat pemilik token, atau nil. Perangkat lama (sebelum ada jenis perangkat) diberi jenis
// dari request ini; tersimpan ke devices.json saat file itu ditulis berikutnya.
func (a *auth) check(token, kind string) *device {
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
	if d.Kind == "" {
		d.Kind = kind
	}
	cp := *d
	return &cp
}

// revokeAll mencabut semua perangkat (dari halaman admin)
func (a *auth) revokeAll() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	old := a.devices
	a.devices = map[string]*device{}
	if err := a.save(); err != nil {
		a.devices = old
		return err
	}
	return nil
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
