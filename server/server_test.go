package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testPassword = "rahasia-panjang-123"
const testAdminPassword = "admin-rahasia-panjang-456"

// testAuth: auth dengan pengaturan default di folder sementara
func testAuth(t *testing.T) *auth {
	t.Helper()
	dir := t.TempDir()
	st, err := loadSettings(filepath.Join(dir, "settings.json"), true)
	if err != nil {
		t.Fatal(err)
	}
	a, err := newAuth(testPassword, testAdminPassword, filepath.Join(dir, "d.json"), st)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func newTestServer(t *testing.T) (*httptest.Server, *app) {
	t.Helper()
	a, err := newApp(testPassword, testAdminPassword, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	web, _ := fs.Sub(webFiles, "web")
	ts := httptest.NewServer(a.routes(web))
	t.Cleanup(ts.Close)
	return ts, a
}

func do(t *testing.T, ts *httptest.Server, method, path, token string, body io.Reader, hdr map[string]string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(method, ts.URL+path, body)
	req.Header.Set("X-PasteLAN", "1")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range hdr {
		if v == "" {
			req.Header.Del(k)
		} else {
			req.Header.Set(k, v)
		}
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	return res, b
}

func login(t *testing.T, ts *httptest.Server, password, name string) (int, string, *http.Response) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"password": password, "name": name})
	res, b := do(t, ts, "POST", "/api/login", "", bytes.NewReader(body), nil)
	var j struct{ Token string }
	_ = json.Unmarshal(b, &j)
	return res.StatusCode, j.Token, res
}

func pngBytes(t *testing.T) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.Set(1, 1, color.RGBA{255, 0, 0, 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestLoginAndAuth(t *testing.T) {
	ts, a := newTestServer(t)
	if code, _, _ := login(t, ts, "salah", "HP"); code != 401 {
		t.Fatalf("password salah: %d", code)
	}
	code, token, res := login(t, ts, testPassword, "HP <b>Kiki</b>")
	if code != 200 || len(token) < 40 {
		t.Fatalf("login: %d %q", code, token)
	}
	c := res.Cookies()
	if len(c) != 1 || !c[0].HttpOnly || !c[0].Secure || c[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("cookie tidak aman: %+v", c)
	}
	if res, _ := do(t, ts, "GET", "/api/items", "", nil, nil); res.StatusCode != 401 {
		t.Fatalf("tanpa token: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "GET", "/api/items", "token-palsu", nil, nil); res.StatusCode != 401 {
		t.Fatalf("token palsu: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "GET", "/api/items", token, nil, nil); res.StatusCode != 200 {
		t.Fatalf("token benar: %d", res.StatusCode)
	}
	// token asli tidak pernah disimpan di disk, hanya hash-nya
	b, _ := os.ReadFile(a.auth.file)
	if bytes.Contains(b, []byte(token)) || !bytes.Contains(b, []byte(hashToken(token))) {
		t.Fatal("devices.json harus berisi hash token, bukan token")
	}
	if st, _ := os.Stat(a.auth.file); st.Mode().Perm() != 0o600 {
		t.Fatalf("izin devices.json %v", st.Mode().Perm())
	}
	// token tetap berlaku setelah server restart
	a2, err := newAuth(testPassword, testAdminPassword, a.auth.file, a.settings)
	if err != nil || a2.check(token) == nil {
		t.Fatal("token hilang setelah restart")
	}
}

func TestCSRFHeaderRequired(t *testing.T) {
	ts, _ := newTestServer(t)
	_, token, _ := login(t, ts, testPassword, "HP")
	res, _ := do(t, ts, "POST", "/api/text", token, strings.NewReader("halo"), map[string]string{"X-PasteLAN": ""})
	if res.StatusCode != 403 {
		t.Fatalf("tanpa X-PasteLAN: %d", res.StatusCode)
	}
}

func TestRateLimit(t *testing.T) {
	ts, _ := newTestServer(t)
	for i := 0; i < maxFailsPerIP; i++ {
		login(t, ts, "salah", "x")
	}
	// IP terkunci: password benar pun ditolak
	if code, _, res := login(t, ts, testPassword, "x"); code != 429 || res.Header.Get("Retry-After") == "" {
		t.Fatalf("setelah %d gagal: %d", maxFailsPerIP, code)
	}
}

func TestGlobalLockout(t *testing.T) {
	a := testAuth(t)
	for i := 0; i < maxFailsGlobal; i++ {
		a.login(fmt.Sprintf("10.0.%d.%d", i/250, i%250), "salah", "x")
	}
	if _, _, err := a.login("192.0.2.1", testPassword, "x"); err != errLocked {
		t.Fatalf("login baru harus ditutup sementara: %v", err)
	}
}

func TestIPv6LimitPer64(t *testing.T) {
	if limitKey("2001:db8:1:2:aaaa::1") != limitKey("2001:db8:1:2:bbbb::9") {
		t.Fatal("IPv6 dalam /64 yang sama harus dihitung satu")
	}
	if limitKey("2001:db8:1:3::1") == limitKey("2001:db8:1:2::1") {
		t.Fatal("/64 berbeda harus dihitung terpisah")
	}
}

func TestClientIPBehindProxy(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:5555"
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 203.0.113.9") // entri pertama dipalsukan klien
	if ip := clientIP(r); ip != "203.0.113.9" {
		t.Fatalf("di belakang proxy: %s", ip)
	}
	r.RemoteAddr = "198.51.100.7:5555" // bukan dari proxy lokal → header diabaikan
	if ip := clientIP(r); ip != "198.51.100.7" {
		t.Fatalf("langsung: %s", ip)
	}
}

func TestTextAndLongPoll(t *testing.T) {
	ts, _ := newTestServer(t)
	_, mac, _ := login(t, ts, testPassword, "Mac")
	_, hp, _ := login(t, ts, testPassword, "HP")

	_, b := do(t, ts, "GET", "/api/items", mac, nil, nil)
	var first struct{ Session string }
	_ = json.Unmarshal(b, &first)

	got := make(chan []byte, 1)
	go func() {
		_, b := do(t, ts, "GET", "/api/items?after=0&wait=1&s="+first.Session, mac, nil, nil)
		got <- b
	}()
	time.Sleep(200 * time.Millisecond) // long-poll sedang menunggu
	start := time.Now()
	if res, _ := do(t, ts, "POST", "/api/text", hp, strings.NewReader("halo ✓"), nil); res.StatusCode != 200 {
		t.Fatalf("kirim teks: %d", res.StatusCode)
	}
	select {
	case b := <-got:
		var j struct {
			Items []struct{ Text, From, Kind string }
		}
		_ = json.Unmarshal(b, &j)
		if len(j.Items) != 1 || j.Items[0].Text != "halo ✓" || j.Items[0].From != "HP" {
			t.Fatalf("isi long-poll: %s", b)
		}
		if time.Since(start) > 2*time.Second {
			t.Fatal("long-poll terlambat bangun")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long-poll tidak bangun")
	}
	if res, _ := do(t, ts, "POST", "/api/text", hp, strings.NewReader("   "), nil); res.StatusCode != 400 {
		t.Fatalf("teks kosong: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "POST", "/api/text", hp, bytes.NewReader([]byte{0xff, 0xfe}), nil); res.StatusCode != 400 {
		t.Fatalf("UTF-8 rusak: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "POST", "/api/text", hp, bytes.NewReader(make([]byte, maxText+1)), nil); res.StatusCode != 413 {
		t.Fatalf("teks terlalu besar: %d", res.StatusCode)
	}
}

func TestImages(t *testing.T) {
	ts, _ := newTestServer(t)
	_, tok, _ := login(t, ts, testPassword, "HP")
	img := pngBytes(t)
	res, b := do(t, ts, "POST", "/api/image", tok, bytes.NewReader(img), map[string]string{"Content-Type": "image/svg+xml"})
	if res.StatusCode != 200 {
		t.Fatalf("kirim PNG: %d %s", res.StatusCode, b)
	}
	var j struct{ ID int64 }
	_ = json.Unmarshal(b, &j)
	res, got := do(t, ts, "GET", "/api/image/"+itoa(j.ID), tok, nil, nil)
	if res.StatusCode != 200 || !bytes.Equal(got, img) || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("ambil gambar: %d %s", res.StatusCode, res.Header.Get("Content-Type")) // jenis dari isi, bukan header klien
	}
	svg := []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`)
	if res, _ := do(t, ts, "POST", "/api/image", tok, bytes.NewReader(svg), map[string]string{"Content-Type": "image/svg+xml"}); res.StatusCode != 415 {
		t.Fatalf("SVG harus ditolak: %d", res.StatusCode)
	}
	if imageType(append([]byte{0, 0, 0, 24}, []byte("ftypheic0000")...)) != "image/heic" {
		t.Fatal("HEIC tidak dikenali")
	}
}

func TestRevokeAndLogout(t *testing.T) {
	ts, _ := newTestServer(t)
	_, mac, _ := login(t, ts, testPassword, "Mac")
	_, hp, _ := login(t, ts, testPassword, "HP")
	_, b := do(t, ts, "GET", "/api/devices", mac, nil, nil)
	var j struct {
		Devices []struct {
			ID, Name string
			Current  bool
		}
	}
	_ = json.Unmarshal(b, &j)
	if len(j.Devices) != 2 || bytes.Contains(b, []byte("tokenHash")) {
		t.Fatalf("daftar perangkat: %s", b)
	}
	var hpID string
	for _, d := range j.Devices {
		if d.Name == "HP" {
			hpID = d.ID
		}
	}
	if res, _ := do(t, ts, "DELETE", "/api/devices/"+hpID, mac, nil, nil); res.StatusCode != 200 {
		t.Fatalf("cabut: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "GET", "/api/items", hp, nil, nil); res.StatusCode != 401 {
		t.Fatalf("token yang dicabut masih jalan: %d", res.StatusCode)
	}
	do(t, ts, "POST", "/api/logout", mac, nil, nil)
	if res, _ := do(t, ts, "GET", "/api/items", mac, nil, nil); res.StatusCode != 401 {
		t.Fatalf("token setelah logout masih jalan: %d", res.StatusCode)
	}
}

func TestSecurityHeadersAndStatic(t *testing.T) {
	ts, _ := newTestServer(t)
	for _, p := range []string{"/", "/app.js", "/sw.js", "/manifest.webmanifest", "/icon-192.png"} {
		res, err := http.Get(ts.URL + p)
		if err != nil || res.StatusCode != 200 {
			t.Fatalf("%s: %v %v", p, err, res.StatusCode)
		}
		res.Body.Close()
		csp := res.Header.Get("Content-Security-Policy")
		if !strings.Contains(csp, "script-src 'self'") || strings.Contains(csp, "unsafe") ||
			res.Header.Get("X-Content-Type-Options") != "nosniff" || res.Header.Get("X-Frame-Options") != "DENY" {
			t.Fatalf("%s: header keamanan kurang: %v", p, res.Header)
		}
	}
	res, _ := do(t, ts, "GET", "/api/items", "x", nil, nil)
	if res.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("API harus no-store")
	}
}

func TestStoreLimits(t *testing.T) {
	s := newStore(defaultSettings(true).limits())
	maxItems, itemTTL := s.lim.maxItems, s.lim.ttl
	for i := 0; i < maxItems+5; i++ {
		s.add(&item{Kind: "text", Text: itoa(int64(i)), Size: 1, Device: "d"})
	}
	if l := s.after(0).items; len(l) != maxItems {
		t.Fatalf("maks item: %d", len(l))
	}
	s.mu.Lock()
	s.items[0].at = time.Now().Add(-itemTTL - time.Minute)
	s.mu.Unlock()
	if l := s.after(0).items; len(l) != maxItems-1 {
		t.Fatalf("item kedaluwarsa tidak dibuang: %d", len(l))
	}
	// isi yang sama berturut-turut dari perangkat yang sama → tidak dobel
	a := s.add(&item{Kind: "text", Text: "x", Size: 1, Device: "d"})
	b := s.add(&item{Kind: "text", Text: "x", Size: 1, Device: "d"})
	if a.ID != b.ID {
		t.Fatal("duplikat tidak digabung")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func claim(t *testing.T, ts *httptest.Server, code, name string) (int, string, *http.Response) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"code": code, "name": name})
	res, b := do(t, ts, "POST", "/api/pair/claim", "", bytes.NewReader(body), nil)
	var j struct{ Token string }
	_ = json.Unmarshal(b, &j)
	return res.StatusCode, j.Token, res
}

func TestUnknownAPI(t *testing.T) {
	ts, _ := newTestServer(t)
	for _, m := range []string{"GET", "POST", "DELETE"} {
		res, b := do(t, ts, m, "/api/tidak-ada", "", nil, nil)
		if res.StatusCode != 404 || !strings.Contains(string(b), `"error"`) {
			t.Fatalf("%s /api/ tidak dikenal: %d %s", m, res.StatusCode, b)
		}
	}
	if res, _ := do(t, ts, "GET", "/", "", nil, nil); res.StatusCode != 200 {
		t.Fatalf("halaman utama: %d", res.StatusCode)
	}
}

func TestPairing(t *testing.T) {
	ts, _ := newTestServer(t)
	if res, _ := do(t, ts, "POST", "/api/pair", "", nil, nil); res.StatusCode != 401 {
		t.Fatalf("kode QR tanpa login: %d", res.StatusCode)
	}
	_, mac, _ := login(t, ts, testPassword, "Mac")
	_, b := do(t, ts, "POST", "/api/pair", mac, nil, nil)
	var p struct {
		Code    string
		Expires int64
	}
	_ = json.Unmarshal(b, &p)
	if len(p.Code) < 40 || time.UnixMilli(p.Expires).Sub(time.Now()) > pairTTL {
		t.Fatalf("kode pairing: %s", b)
	}
	code, token, res := claim(t, ts, p.Code, "HP scan")
	if code != 200 || token == "" || len(res.Cookies()) != 1 || !res.Cookies()[0].HttpOnly {
		t.Fatalf("klaim: %d", code)
	}
	if res, _ := do(t, ts, "GET", "/api/items", token, nil, nil); res.StatusCode != 200 {
		t.Fatalf("token dari QR: %d", res.StatusCode)
	}
	if code, _, _ := claim(t, ts, p.Code, "HP lain"); code != 401 {
		t.Fatalf("kode dipakai dua kali: %d", code)
	}
}

func TestPairingExpiredAndGuessing(t *testing.T) {
	a := testAuth(t)
	c, _ := a.newPair(pairTTL)
	a.mu.Lock()
	a.pairs[hashToken(c)] = time.Now().Add(-time.Second)
	a.mu.Unlock()
	if _, _, err := a.claimPair("192.0.2.1", c, "x"); err != errBadPair {
		t.Fatalf("kode kedaluwarsa: %v", err)
	}
	// kode tebakan dihitung seperti password salah → IP terkunci
	for i := 0; i < maxFailsPerIP; i++ {
		a.claimPair("192.0.2.9", "tebakan", "x")
	}
	good, _ := a.newPair(pairTTL)
	if _, _, err := a.claimPair("192.0.2.9", good, "x"); err != errLocked {
		t.Fatalf("setelah banyak tebakan: %v", err)
	}
	for i := 0; i < maxPairCodes+5; i++ {
		a.newPair(pairTTL)
	}
	if len(a.pairs) > maxPairCodes {
		t.Fatalf("kode aktif tidak dibatasi: %d", len(a.pairs))
	}
}

// adminLogin mengembalikan cookie sesi admin (dikirim manual: cookie Secure tidak dikirim client ke http://)
func adminLogin(t *testing.T, ts *httptest.Server, password string) (int, map[string]string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"password": password})
	res, _ := do(t, ts, "POST", "/api/admin/login", "", bytes.NewReader(body), nil)
	for _, c := range res.Cookies() {
		if c.Name == adminCookie {
			if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode || c.Path != "/api/admin" {
				t.Fatalf("cookie admin kurang aman: %+v", c)
			}
			return res.StatusCode, map[string]string{"Cookie": adminCookie + "=" + c.Value}
		}
	}
	return res.StatusCode, nil
}

func TestAdminLoginAndSetupLink(t *testing.T) {
	ts, _ := newTestServer(t)
	if res, _ := do(t, ts, "GET", "/api/admin/status", "", nil, nil); res.StatusCode != 401 {
		t.Fatalf("status tanpa login admin: %d", res.StatusCode)
	}
	if code, _ := adminLogin(t, ts, testPassword); code != 401 {
		t.Fatalf("password perangkat bukan password admin: %d", code)
	}
	// token perangkat tidak berlaku untuk admin
	_, token, _ := login(t, ts, testPassword, "HP")
	if res, _ := do(t, ts, "GET", "/api/admin/status", token, nil, nil); res.StatusCode != 401 {
		t.Fatalf("token perangkat di admin: %d", res.StatusCode)
	}
	code, ck := adminLogin(t, ts, testAdminPassword)
	if code != 200 || ck == nil {
		t.Fatalf("login admin: %d", code)
	}
	res, b := do(t, ts, "GET", "/api/admin/status", "", nil, ck)
	if res.StatusCode != 200 || !strings.Contains(string(b), `"maxItems":20`) || strings.Contains(string(b), "pbkdf2") {
		t.Fatalf("status admin: %d %s", res.StatusCode, b)
	}
	// link setup → perangkat baru masuk tanpa password, sekali pakai
	_, b = do(t, ts, "POST", "/api/admin/setup-link", "", nil, ck)
	var p struct {
		Code    string
		Expires int64
	}
	_ = json.Unmarshal(b, &p)
	if d := time.Until(time.UnixMilli(p.Expires)); d < 9*time.Minute || d > 10*time.Minute {
		t.Fatalf("masa berlaku link setup: %v", d)
	}
	if code, tok, _ := claim(t, ts, p.Code, "Mac"); code != 200 || tok == "" {
		t.Fatalf("klaim link setup: %d", code)
	}
	if code, _, _ := claim(t, ts, p.Code, "Mac lagi"); code != 401 {
		t.Fatalf("link setup dipakai dua kali: %d", code)
	}
	// keluar admin → sesi tidak berlaku lagi
	do(t, ts, "POST", "/api/admin/logout", "", nil, ck)
	if res, _ := do(t, ts, "GET", "/api/admin/status", "", nil, ck); res.StatusCode != 401 {
		t.Fatalf("sesi admin setelah keluar: %d", res.StatusCode)
	}
	// halaman admin tersedia
	if res, b := do(t, ts, "GET", "/admin", "", nil, nil); res.StatusCode != 200 || !strings.Contains(string(b), "admin.js") {
		t.Fatalf("halaman admin: %d", res.StatusCode)
	}
}

func TestAdminSettingsAndPassword(t *testing.T) {
	ts, a := newTestServer(t)
	_, ck := adminLogin(t, ts, testAdminPassword)
	put := func(body string) (int, string) {
		res, b := do(t, ts, "PUT", "/api/admin/settings", "", strings.NewReader(body), ck)
		return res.StatusCode, string(b)
	}
	if code, _ := put(`{"maxItems":0}`); code != 400 {
		t.Fatalf("maxItems 0 harus ditolak: %d", code)
	}
	if code, b := put(`{"maxItems":3,"autoClear":false,"retentionMinutes":5}`); code != 200 || !strings.Contains(b, `"maxItems":3`) {
		t.Fatalf("ubah pengaturan: %d %s", code, b)
	}
	if l := a.store.lim; l.maxItems != 3 || l.ttl != 0 {
		t.Fatalf("batas store tidak ikut berubah: %+v", l)
	}
	// tersimpan di disk (0600) dan terbaca lagi saat restart
	st, err := loadSettings(a.settings.file, true)
	if err != nil || st.get().MaxItems != 3 || st.get().AutoClear {
		t.Fatalf("pengaturan setelah restart: %+v %v", st.get(), err)
	}
	if fi, _ := os.Stat(a.settings.file); fi.Mode().Perm() != 0o600 {
		t.Fatalf("izin settings.json %v", fi.Mode().Perm())
	}

	// login dengan password dimatikan → 403, halaman login diberi tahu lewat /api/config
	put(`{"passwordLogin":false}`)
	if code, _, _ := login(t, ts, testPassword, "HP"); code != 403 {
		t.Fatalf("login password saat dimatikan: %d", code)
	}
	if _, b := do(t, ts, "GET", "/api/config", "", nil, nil); !strings.Contains(string(b), `"passwordLogin":false`) {
		t.Fatalf("config publik: %s", b)
	}
	put(`{"passwordLogin":true}`)

	// ganti password perangkat: disimpan sebagai hash PBKDF2, password lama tidak berlaku
	pw := func(p string) int {
		body, _ := json.Marshal(map[string]string{"password": p})
		res, _ := do(t, ts, "POST", "/api/admin/password", "", bytes.NewReader(body), ck)
		return res.StatusCode
	}
	if pw("pendek") != 400 || pw(templatePassword) != 400 || pw(testAdminPassword) != 400 {
		t.Fatal("password lemah / contoh / sama dengan admin harus ditolak")
	}
	if pw("password-perangkat-baru") != 200 {
		t.Fatal("ganti password perangkat gagal")
	}
	if code, _, _ := login(t, ts, "password-perangkat-baru", "HP"); code != 200 {
		t.Fatalf("login password baru: %d", code)
	}
	if code, _, _ := login(t, ts, testPassword, "HP"); code != 401 {
		t.Fatalf("password lama masih berlaku: %d", code)
	}
	b, _ := os.ReadFile(a.settings.file)
	if strings.Contains(string(b), "password-perangkat-baru") || !strings.Contains(string(b), "pbkdf2-sha256$") {
		t.Fatalf("settings.json harus berisi hash: %s", b)
	}

	// cabut semua perangkat & hapus riwayat dari admin
	_, token, _ := login(t, ts, "password-perangkat-baru", "HP")
	if res, _ := do(t, ts, "DELETE", "/api/admin/devices", "", nil, ck); res.StatusCode != 200 {
		t.Fatalf("cabut semua: %d", res.StatusCode)
	}
	if res, _ := do(t, ts, "GET", "/api/items", token, nil, nil); res.StatusCode != 401 {
		t.Fatalf("token setelah cabut semua: %d", res.StatusCode)
	}
}

func TestDeleteItem(t *testing.T) {
	ts, _ := newTestServer(t)
	_, token, _ := login(t, ts, testPassword, "HP")
	do(t, ts, "POST", "/api/text", token, strings.NewReader("satu"), nil)
	do(t, ts, "POST", "/api/text", token, strings.NewReader("dua"), nil)
	type reply struct {
		Session string
		Rev     int64
		Items   []struct{ ID int64 }
		IDs     []int64 `json:"ids"`
	}
	get := func(q string) reply {
		_, b := do(t, ts, "GET", "/api/items"+q, token, nil, nil)
		var r reply
		_ = json.Unmarshal(b, &r)
		return r
	}
	r := get("")
	if len(r.IDs) != 2 {
		t.Fatalf("ids: %+v", r)
	}
	// long-poll klien baru (mengirim r=) bangun saat ada item yang dihapus
	done := make(chan reply, 1)
	go func() { done <- get(fmt.Sprintf("?after=%d&s=%s&r=%d&wait=1", r.Items[1].ID, r.Session, r.Rev)) }()
	time.Sleep(200 * time.Millisecond)
	if res, _ := do(t, ts, "DELETE", fmt.Sprintf("/api/items/%d", r.Items[0].ID), token, nil, nil); res.StatusCode != 200 {
		t.Fatalf("hapus item: %d", res.StatusCode)
	}
	select {
	case r2 := <-done:
		if len(r2.IDs) != 1 || r2.IDs[0] != r.Items[1].ID || r2.Rev == r.Rev || r2.Session != r.Session {
			t.Fatalf("setelah hapus: %+v", r2)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long-poll tidak bangun setelah item dihapus")
	}
	if res, _ := do(t, ts, "DELETE", fmt.Sprintf("/api/items/%d", r.Items[0].ID), token, nil, nil); res.StatusCode != 404 {
		t.Fatalf("hapus item yang sudah hilang: %d", res.StatusCode)
	}
}

func TestConfigCheck(t *testing.T) {
	ok := "password-yang-panjang-1"
	cases := []struct {
		c    config
		good bool
	}{
		{config{}, false},
		{config{adminPassword: ok}, true},
		{config{password: ok}, true},
		{config{adminPassword: templatePassword}, false},
		{config{adminPassword: "pendek"}, false},
		{config{adminPassword: ok, password: ok}, false},
		{config{adminPassword: ok, password: "lain-yang-panjang-2"}, true},
	}
	for i, c := range cases {
		if err := c.c.check(); (err == nil) != c.good {
			t.Fatalf("kasus %d: %v", i, err)
		}
	}
	// tanpa PASTELAN_PASSWORD → login password tidak tersedia sampai admin membuat password
	a, err := newApp("", ok, t.TempDir())
	if err != nil || a.auth.passwordLoginAvailable() {
		t.Fatalf("tanpa password perangkat: %v", err)
	}
	if _, _, err := a.auth.login("192.0.2.1", "", "x"); err != errPwDisabled {
		t.Fatalf("login tanpa password perangkat: %v", err)
	}
	// template di pastelan.env.example harus sama dengan yang ditolak server
	b, err := os.ReadFile("deploy/pastelan.env.example")
	if err != nil || !strings.Contains(string(b), "PASTELAN_ADMIN_PASSWORD="+templatePassword+"\n") {
		t.Fatalf("pastelan.env.example harus memakai templatePassword: %v", err)
	}
}
