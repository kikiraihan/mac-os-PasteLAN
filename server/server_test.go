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

func newTestServer(t *testing.T) (*httptest.Server, *app) {
	t.Helper()
	a, err := newApp(testPassword, filepath.Join(t.TempDir(), "devices.json"))
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
	a2, err := newAuth(testPassword, a.auth.file)
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
	a, _ := newAuth(testPassword, filepath.Join(t.TempDir(), "d.json"))
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
	s := newStore()
	for i := 0; i < maxItems+5; i++ {
		s.add(&item{Kind: "text", Text: itoa(int64(i)), Size: 1, Device: "d"})
	}
	if _, l := s.after(0); len(l) != maxItems {
		t.Fatalf("maks item: %d", len(l))
	}
	s.mu.Lock()
	s.items[0].at = time.Now().Add(-itemTTL - time.Minute)
	s.mu.Unlock()
	if _, l := s.after(0); len(l) != maxItems-1 {
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
