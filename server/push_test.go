package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var b64 = base64.RawURLEncoding

// Contoh resmi RFC 8291 Appendix A: hasil enkripsi harus sama persis
func TestEncryptPushRFC8291(t *testing.T) {
	asPriv, _ := b64.DecodeString("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw") // ggignore: contoh publik RFC 8291
	eph, err := ecdh.P256().NewPrivateKey(asPriv)
	if err != nil {
		t.Fatal(err)
	}
	salt, _ := b64.DecodeString("DGv6ra1nlYgDCS1FRnbzlw")
	sub := pushSub{
		P256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
		Auth:   "BTBZMqHH6r4Tts7J_aSIgg", // ggignore: contoh publik RFC 8291, bukan rahasia
	}
	got, err := encryptPushWith(sub, []byte("When I grow up, I want to be a watermelon"), eph, salt)
	if err != nil {
		t.Fatal(err)
	}
	want := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
	if b64.EncodeToString(got) != want {
		t.Fatalf("hasil enkripsi beda dari RFC 8291:\n%s", b64.EncodeToString(got))
	}
}

// decryptPush = sisi browser (untuk tes)
func decryptPush(t *testing.T, ua *ecdh.PrivateKey, authSecret, body []byte) []byte {
	t.Helper()
	salt, idLen := body[:16], int(body[20])
	asRaw, ct := body[21:21+idLen], body[21+idLen:]
	asPub, err := ecdh.P256().NewPublicKey(asRaw)
	if err != nil {
		t.Fatal(err)
	}
	shared, _ := ua.ECDH(asPub)
	prkKey, _ := hkdf.Extract(sha256.New, shared, authSecret)
	info := append(append([]byte("WebPush: info\x00"), ua.PublicKey().Bytes()...), asRaw...)
	ikm, _ := hkdf.Expand(sha256.New, prkKey, string(info), 32)
	prk, _ := hkdf.Extract(sha256.New, ikm, salt)
	cek, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	block, _ := aes.NewCipher(cek)
	gcm, _ := cipher.NewGCM(block)
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	if plain[len(plain)-1] != 0x02 {
		t.Fatal("penanda record terakhir hilang")
	}
	return plain[:len(plain)-1]
}

// checkVAPID memeriksa header Authorization: tanda tangan ES256 sah dengan kunci k, aud = origin layanan push
func checkVAPID(t *testing.T, h, aud string) {
	t.Helper()
	tok, ok := strings.CutPrefix(h, "vapid t=")
	if !ok {
		t.Fatalf("header Authorization: %q", h)
	}
	jwt, k, _ := strings.Cut(tok, ", k=")
	pubRaw, _ := b64.DecodeString(k)
	x, y := new(big.Int).SetBytes(pubRaw[1:33]), new(big.Int).SetBytes(pubRaw[33:])
	parts := strings.Split(jwt, ".")
	sig, _ := b64.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	pub := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	if len(sig) != 64 || !ecdsa.Verify(pub, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("tanda tangan VAPID tidak sah")
	}
	claims, _ := b64.DecodeString(parts[1])
	var c struct {
		Aud, Sub string
		Exp      int64
	}
	_ = json.Unmarshal(claims, &c)
	if c.Aud != aud || c.Sub == "" || c.Exp <= time.Now().Unix() || c.Exp > time.Now().Add(24*time.Hour).Unix() {
		t.Fatalf("klaim VAPID salah: %+v", c)
	}
}

// fakePushService = layanan push palsu (HTTPS) + kunci browser untuk mendekripsi isi notifikasi
type fakePushService struct {
	ts     *httptest.Server
	ua     *ecdh.PrivateKey
	secret []byte
	status int
	mu     sync.Mutex
	got    chan []byte
}

func newFakePush(t *testing.T) *fakePushService {
	f := &fakePushService{status: 201, got: make(chan []byte, 10), secret: make([]byte, 16)}
	f.ua, _ = ecdh.P256().GenerateKey(rand.Reader)
	_, _ = rand.Read(f.secret)
	f.ts = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Encoding") != "aes128gcm" || r.Header.Get("TTL") == "" {
			t.Errorf("header push salah: %v", r.Header)
		}
		checkVAPID(t, r.Header.Get("Authorization"), f.ts.URL)
		body, _ := io.ReadAll(r.Body)
		f.got <- decryptPush(t, f.ua, f.secret, body)
		f.mu.Lock()
		defer f.mu.Unlock()
		w.WriteHeader(f.status)
	}))
	t.Cleanup(f.ts.Close)
	return f
}

func (f *fakePushService) subscription(path string) map[string]any {
	return map[string]any{"endpoint": f.ts.URL + path,
		"keys": map[string]string{"p256dh": b64.EncodeToString(f.ua.PublicKey().Bytes()), "auth": b64.EncodeToString(f.secret)}}
}

func (f *fakePushService) next(t *testing.T) pushMessage {
	t.Helper()
	select {
	case b := <-f.got:
		var m pushMessage
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatal(err)
		}
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("notifikasi tidak terkirim")
	}
	return pushMessage{}
}

func (f *fakePushService) none(t *testing.T) {
	t.Helper()
	select {
	case <-f.got:
		t.Fatal("notifikasi terkirim padahal tidak diminta")
	case <-time.After(300 * time.Millisecond):
	}
}

func TestPushNotify(t *testing.T) {
	ts, a := newTestServer(t)
	f := newFakePush(t)
	a.push.client = f.ts.Client()
	a.push.allowHost = func(string) bool { return true }
	_, mac, _ := login(t, ts, testPassword, "MacBook") // ggignore: password tes
	_, hp, _ := login(t, ts, testPassword, "HP")

	res, b := do(t, ts, "GET", "/api/push/key", hp, nil, nil)
	var k struct {
		Key        string
		Subscribed bool
	}
	_ = json.Unmarshal(b, &k)
	if raw, _ := b64.DecodeString(k.Key); res.StatusCode != 200 || len(raw) != 65 || k.Subscribed {
		t.Fatalf("kunci VAPID: %d %s", res.StatusCode, b)
	}

	sub, _ := json.Marshal(f.subscription("/kirim/hp"))
	if res, b := do(t, ts, "POST", "/api/push/subscribe", hp, bytes.NewReader(sub), nil); res.StatusCode != 200 {
		t.Fatalf("subscribe: %d %s", res.StatusCode, b)
	}
	// Mac juga berlangganan → pengirim tidak menerima notifikasinya sendiri
	if res, _ := do(t, ts, "POST", "/api/push/subscribe", mac, bytes.NewReader(sub), nil); res.StatusCode != 200 {
		t.Fatal("subscribe Mac")
	}

	// autosync (tanpa notify=1) → tidak ada notifikasi
	do(t, ts, "POST", "/api/text", mac, strings.NewReader("dari autosync"), nil)
	f.none(t)

	text := "  Halo   dari Mac\n" + strings.Repeat("panjang ", 30)
	res, b = do(t, ts, "POST", "/api/text?notify=1", mac, strings.NewReader(text), nil)
	var sent struct{ ID int64 }
	_ = json.Unmarshal(b, &sent)
	m := f.next(t)
	if res.StatusCode != 200 || m.ID != sent.ID || m.Kind != "text" || m.From != "MacBook" ||
		!strings.HasPrefix(m.Preview, "Halo dari Mac panjang") || !strings.HasSuffix(m.Preview, "…") ||
		len([]rune(m.Preview)) > pushPreview+1 {
		t.Fatalf("isi notifikasi: %+v", m)
	}
	f.none(t) // hanya satu (HP), bukan Mac pengirim

	do(t, ts, "POST", "/api/image?notify=1", mac, bytes.NewReader(pngBytes(t)), nil)
	if m := f.next(t); m.Kind != "image" || m.Preview != "" {
		t.Fatalf("notifikasi gambar: %+v", m)
	}

	// layanan push menjawab 410 (browser berhenti berlangganan) → langganan dibuang
	f.mu.Lock()
	f.status = http.StatusGone
	f.mu.Unlock()
	do(t, ts, "POST", "/api/text?notify=1", mac, strings.NewReader("lagi"), nil)
	f.next(t)
	deadline := time.Now().Add(3 * time.Second)
	for len(a.auth.pushTargets("")) > 1 {
		if time.Now().After(deadline) {
			t.Fatal("langganan 410 tidak dibuang")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, b := do(t, ts, "GET", "/api/push/key", hp, nil, nil); !strings.Contains(string(b), `"subscribed":false`) {
		t.Fatalf("status langganan HP: %s", b)
	}

	// berhenti berlangganan dari PWA
	if res, _ := do(t, ts, "DELETE", "/api/push/subscribe", mac, nil, nil); res.StatusCode != 200 || len(a.auth.pushTargets("")) != 0 {
		t.Fatal("unsubscribe")
	}
}

func TestPushSubscribeValidation(t *testing.T) {
	ts, _ := newTestServer(t)
	_, hp, _ := login(t, ts, testPassword, "HP")
	ua, _ := ecdh.P256().GenerateKey(rand.Reader)
	key := b64.EncodeToString(ua.PublicKey().Bytes())
	secret := b64.EncodeToString(make([]byte, 16))
	for _, c := range []struct {
		endpoint, p256dh, auth string
		ok                     bool
	}{
		{"https://fcm.googleapis.com/fcm/send/abc", key, secret, true},
		{"https://web.push.apple.com/QGx", key, secret, true},
		{"https://updates.push.services.mozilla.com/wpush/v2/x", key, secret, true},
		{"http://fcm.googleapis.com/fcm/send/abc", key, secret, false},    // bukan HTTPS
		{"https://127.0.0.1/admin", key, secret, false},                   // bukan layanan push
		{"https://evil.example/fcm.googleapis.com", key, secret, false},   // host lain
		{"https://fcm.googleapis.com.evil.example/x", key, secret, false}, // akhiran palsu
		{"https://user@fcm.googleapis.com/x", key, secret, false},         // userinfo
		{"https://fcm.googleapis.com/x", "AAAA", secret, false},           // kunci rusak
		{"https://fcm.googleapis.com/x", key, b64.EncodeToString([]byte("pendek")), false},
	} {
		body, _ := json.Marshal(map[string]any{"endpoint": c.endpoint, "keys": map[string]string{"p256dh": c.p256dh, "auth": c.auth}})
		res, b := do(t, ts, "POST", "/api/push/subscribe", hp, bytes.NewReader(body), nil)
		if (res.StatusCode == 200) != c.ok {
			t.Errorf("%s: %d %s", c.endpoint, res.StatusCode, b)
		}
	}
	if res, _ := do(t, ts, "GET", "/api/push/key", "", nil, nil); res.StatusCode != 401 {
		t.Fatal("kunci push tanpa login")
	}
}

// kunci VAPID dibuat sekali lalu dipakai lagi setelah restart
func TestPushKeyPersists(t *testing.T) {
	file := filepath.Join(t.TempDir(), "push-key.pem")
	p1, err := loadPusher(file, "https://contoh")
	if err != nil {
		t.Fatal(err)
	}
	p2, err := loadPusher(file, "https://contoh")
	if err != nil || p1.publicKey() != p2.publicKey() {
		t.Fatal("kunci VAPID berubah setelah restart")
	}
}

func TestPreview(t *testing.T) {
	for in, want := range map[string]string{
		"pendek":                      "pendek",
		"  a\n\tb  ":                  "a b",
		strings.Repeat("é", 70):       strings.Repeat("é", 60) + "…",
		strings.Repeat("kata ", 1000): strings.TrimSpace(strings.Repeat("kata ", 12)) + "…",
		strings.Repeat("ü", 2<<20/2):  strings.Repeat("ü", 60) + "…",
	} {
		if got := preview(in); got != want {
			t.Errorf("preview(%.20q) = %q", in, got)
		}
	}
}
