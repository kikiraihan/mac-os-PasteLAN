package main

// Notifikasi Web Push ke PWA (RFC 8030 / 8291 / 8292), hanya standard library.
//   - Kunci VAPID (ECDSA P-256) dibuat sekali di folder data (push-key.pem, 0600); hanya kunci publiknya yang dikirim.
//   - Langganan push disimpan per perangkat di devices.json (perangkat dicabut → langganannya ikut hilang).
//   - Dikirim hanya untuk kiriman manual yang meminta notifikasi (?notify=1, ⇧ + klik di menu Mac), bukan autosync.
//   - Isi notifikasi terenkripsi end-to-end (aes128gcm) sehingga layanan push (Google / Apple / Mozilla) tidak bisa
//     membacanya. Hanya potongan pendek teks yang ikut; isi lengkap diambil PWA dari server setelah notifikasi diketuk.

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
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	pushTTL        = 3600 // detik: notifikasi yang belum terkirim (HP mati) dibuang layanan push setelah 1 jam
	pushPreview    = 60   // jumlah huruf potongan teks di notifikasi
	pushTimeout    = 15 * time.Second
	maxEndpointLen = 1024
)

// pushSub = langganan push satu perangkat (dari PushSubscription.toJSON() di browser)
type pushSub struct {
	Endpoint string `json:"endpoint"`
	P256dh   string `json:"p256dh"` // kunci publik ECDH browser (base64url, 65 byte)
	Auth     string `json:"auth"`   // rahasia autentikasi browser (base64url, 16 byte)
}

// pushHosts: layanan push yang boleh dihubungi server (mencegah server dipakai mengirim request ke alamat sembarang)
var pushHosts = []string{"fcm.googleapis.com", "updates.push.services.mozilla.com", ".push.apple.com", ".notify.windows.com"}

func allowedPushHost(host string) bool {
	for _, h := range pushHosts {
		if host == h || (strings.HasPrefix(h, ".") && strings.HasSuffix(host, h)) {
			return true
		}
	}
	return false
}

// validate memeriksa langganan dari browser sebelum disimpan
func (s pushSub) validate(allowHost func(string) bool) error {
	u, err := url.Parse(s.Endpoint)
	if err != nil || len(s.Endpoint) > maxEndpointLen || u.Scheme != "https" || u.User != nil || !allowHost(u.Hostname()) {
		return errors.New("alamat layanan push tidak didukung")
	}
	pub, err1 := base64.RawURLEncoding.DecodeString(strings.TrimRight(s.P256dh, "="))
	secret, err2 := base64.RawURLEncoding.DecodeString(strings.TrimRight(s.Auth, "="))
	if err1 != nil || err2 != nil || len(secret) != 16 {
		return errors.New("kunci langganan push tidak valid")
	}
	if _, err := ecdh.P256().NewPublicKey(pub); err != nil {
		return errors.New("kunci langganan push tidak valid")
	}
	return nil
}

type pusher struct {
	key       *ecdsa.PrivateKey
	pub       []byte // kunci publik VAPID, bentuk tak terkompresi (65 byte)
	subject   string // "sub" di JWT VAPID: kontak pemilik server untuk layanan push
	client    *http.Client
	allowHost func(string) bool
}

// loadPusher membaca kunci VAPID dari file, atau membuatnya kalau belum ada
func loadPusher(file, subject string) (*pusher, error) {
	var key *ecdsa.PrivateKey
	b, err := os.ReadFile(file)
	switch {
	case err == nil:
		blk, _ := pem.Decode(b)
		if blk == nil {
			return nil, errors.New(file + ": bukan PEM")
		}
		k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
		if err != nil {
			return nil, err
		}
		var ok bool
		if key, ok = k.(*ecdsa.PrivateKey); !ok || key.Curve != elliptic.P256() {
			return nil, errors.New(file + ": bukan kunci ECDSA P-256")
		}
	case errors.Is(err, os.ErrNotExist):
		if key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
			return nil, err
		}
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return nil, err
		}
		tmp := file + ".tmp"
		if err := os.WriteFile(tmp, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
			return nil, err
		}
		if err := os.Rename(tmp, file); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	ek, err := key.ECDH()
	if err != nil {
		return nil, err
	}
	return &pusher{key: key, pub: ek.PublicKey().Bytes(), subject: subject,
		client: &http.Client{Timeout: pushTimeout, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse // layanan push tidak perlu redirect; jangan ikuti ke alamat lain
		}},
		allowHost: allowedPushHost}, nil
}

func (p *pusher) publicKey() string { return base64.RawURLEncoding.EncodeToString(p.pub) }

// vapidJWT: token ES256 untuk satu layanan push (aud = origin endpoint), berlaku 12 jam
func (p *pusher) vapidJWT(aud string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding.EncodeToString
	head := enc([]byte(`{"typ":"JWT","alg":"ES256"}`))
	claims, _ := json.Marshal(map[string]any{"aud": aud, "exp": now.Add(12 * time.Hour).Unix(), "sub": p.subject})
	msg := head + "." + enc(claims)
	h := sha256.Sum256([]byte(msg))
	r, s, err := ecdsa.Sign(rand.Reader, p.key, h[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64) // r || s, masing-masing 32 byte
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return msg + "." + enc(sig), nil
}

// encryptPush: isi push terenkripsi untuk satu browser (RFC 8291, content-encoding aes128gcm, satu record)
func encryptPush(sub pushSub, plain []byte) ([]byte, error) {
	eph, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return encryptPushWith(sub, plain, eph, salt)
}

func encryptPushWith(sub pushSub, plain []byte, eph *ecdh.PrivateKey, salt []byte) ([]byte, error) {
	uaRaw, err1 := base64.RawURLEncoding.DecodeString(strings.TrimRight(sub.P256dh, "="))
	authSecret, err2 := base64.RawURLEncoding.DecodeString(strings.TrimRight(sub.Auth, "="))
	if err1 != nil || err2 != nil {
		return nil, errors.New("kunci langganan push tidak valid")
	}
	uaPub, err := ecdh.P256().NewPublicKey(uaRaw)
	if err != nil {
		return nil, err
	}
	shared, err := eph.ECDH(uaPub)
	if err != nil {
		return nil, err
	}
	asPub := eph.PublicKey().Bytes()
	// IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0x00 || ua_public || as_public, 32)
	info := append(append([]byte("WebPush: info\x00"), uaRaw...), asPub...)
	prkKey, err := hkdf.Extract(sha256.New, shared, authSecret)
	if err != nil {
		return nil, err
	}
	ikm, err := hkdf.Expand(sha256.New, prkKey, string(info), 32)
	if err != nil {
		return nil, err
	}
	prk, err := hkdf.Extract(sha256.New, ikm, salt)
	if err != nil {
		return nil, err
	}
	cek, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, err
	}
	nonce, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	// header: salt (16) || ukuran record (4) || panjang keyid (1) || keyid = kunci publik sementara server (65)
	var out bytes.Buffer
	out.Write(salt)
	_ = binary.Write(&out, binary.BigEndian, uint32(4096))
	out.WriteByte(byte(len(asPub)))
	out.Write(asPub)
	rec := append(append([]byte{}, plain...), 0x02) // 0x02 = record terakhir
	return gcm.Seal(out.Bytes(), nonce, rec, nil), nil
}

var errSubGone = errors.New("langganan push sudah tidak berlaku")

// send mengirim satu notifikasi. errSubGone → langganan dibuang (browser berhenti berlangganan / kunci VAPID berganti).
func (p *pusher) send(sub pushSub, payload []byte) error {
	u, err := url.Parse(sub.Endpoint)
	if err != nil || u.Scheme != "https" || !p.allowHost(u.Hostname()) {
		return errSubGone
	}
	body, err := encryptPush(sub, payload)
	if err != nil {
		return errSubGone
	}
	jwt, err := p.vapidJWT(u.Scheme+"://"+u.Host, time.Now())
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return errSubGone
	}
	req.Header.Set("Authorization", "vapid t="+jwt+", k="+p.publicKey())
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("TTL", "3600")
	req.Header.Set("Urgency", "high")
	res, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	switch {
	case res.StatusCode >= 200 && res.StatusCode < 300:
		return nil
	case res.StatusCode == http.StatusNotFound, res.StatusCode == http.StatusGone,
		res.StatusCode == http.StatusUnauthorized, res.StatusCode == http.StatusForbidden:
		return errSubGone
	}
	return errors.New("layanan push menjawab " + res.Status)
}

// pushMessage = isi notifikasi (dibaca service worker). Teks hanya potongan pendek; isi lengkap diambil dari server.
type pushMessage struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	From    string `json:"from"`
	Preview string `json:"preview,omitempty"`
}

// preview: satu baris pendek dari teks (spasi / baris baru diringkas), dipotong dengan "…"
func preview(s string) string {
	if len(s) > 4*pushPreview*4 { // cukup untuk potongan; jangan memproses teks 2 MB utuh
		s = s[:4*pushPreview*4]
		for !utf8.ValidString(s) {
			s = s[:len(s)-1]
		}
	}
	s = strings.Join(strings.FieldsFunc(s, unicode.IsSpace), " ")
	if r := []rune(s); len(r) > pushPreview {
		s = strings.TrimSpace(string(r[:pushPreview])) + "…"
	}
	return s
}

// notifyDevices mengirim notifikasi item ini ke semua perangkat berlangganan, kecuali pengirimnya (di latar belakang)
func (a *app) notifyDevices(it item, sender string) {
	if a.push == nil {
		return
	}
	msg := pushMessage{ID: it.ID, Kind: it.Kind, From: it.From}
	if it.Kind == "text" {
		msg.Preview = preview(it.Text)
	}
	payload, _ := json.Marshal(msg)
	for _, t := range a.auth.pushTargets(sender) {
		go func(id string, sub pushSub) {
			err := a.push.send(sub, payload)
			if errors.Is(err, errSubGone) {
				a.auth.setPush(id, nil, sub.Endpoint)
			} else if err != nil {
				log.Printf("notifikasi push gagal: %v", err) // tanpa isi clipboard / endpoint
			}
		}(t.id, t.sub)
	}
}

// defaultPushSubject: kontak di token VAPID (wajib untuk layanan push Apple); bisa diganti PASTELAN_PUSH_SUBJECT
const defaultPushSubject = "https://github.com/kikiraihan/mac-os-PasteLAN"

// pushOn: endpoint notifikasi hanya ada kalau kunci VAPID tersedia
func (a *app) pushOn(h authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, d *device) {
		if a.push == nil {
			jsonError(w, http.StatusServiceUnavailable, "notifikasi push nonaktif di server ini (lihat log server)")
			return
		}
		h(w, r, d)
	}
}

// pushKey: kunci publik VAPID untuk pushManager.subscribe() di PWA
func (a *app) pushKey(w http.ResponseWriter, r *http.Request, d *device) {
	writeJSON(w, http.StatusOK, map[string]any{"key": a.push.publicKey(), "subscribed": d.Push != nil})
}

func (a *app) pushSubscribe(w http.ResponseWriter, r *http.Request, d *device) {
	var req struct {
		Endpoint string
		Keys     struct{ P256dh, Auth string }
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "format salah")
		return
	}
	sub := pushSub{Endpoint: req.Endpoint, P256dh: req.Keys.P256dh, Auth: req.Keys.Auth}
	if err := sub.validate(a.push.allowHost); err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := a.auth.setPush(d.ID, &sub, ""); err != nil {
		jsonError(w, http.StatusInternalServerError, "gagal menyimpan langganan")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) pushUnsubscribe(w http.ResponseWriter, r *http.Request, d *device) {
	_ = a.auth.setPush(d.ID, nil, "")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
