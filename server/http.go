package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

const cookieName = "pl_token"

type app struct {
	auth     *auth
	store    *store
	settings *settingsStore
	push     *pusher // nil = notifikasi push nonaktif (kunci VAPID gagal dibuat / dibaca)
}

func newApp(password, adminPassword, dataDir string) (*app, error) {
	st, err := loadSettings(filepath.Join(dataDir, "settings.json"), password != "")
	if err != nil {
		return nil, err
	}
	a, err := newAuth(password, adminPassword, filepath.Join(dataDir, "devices.json"), st)
	if err != nil {
		return nil, err
	}
	p, err := loadPusher(filepath.Join(dataDir, "push-key.pem"), env("PASTELAN_PUSH_SUBJECT", defaultPushSubject))
	if err != nil {
		log.Printf("notifikasi push nonaktif: %v", err)
		p = nil
	}
	return &app{auth: a, store: newStore(st.get().limits()), settings: st, push: p}, nil
}

func (a *app) routes(web fs.FS) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(web))
	mux.HandleFunc("GET /admin", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFileFS(w, r, web, "admin.html")
	})
	mux.HandleFunc("GET /api/config", a.publicConfig)
	mux.HandleFunc("POST /api/login", a.login)
	mux.HandleFunc("POST /api/logout", a.authed(a.logout))
	mux.HandleFunc("POST /api/pair", a.authed(a.newPair))
	mux.HandleFunc("POST /api/pair/claim", a.claimPair)
	mux.HandleFunc("GET /api/items", a.authed(a.items))
	mux.HandleFunc("DELETE /api/items", a.authed(a.clearItems))
	mux.HandleFunc("DELETE /api/items/{id}", a.authed(a.deleteItem))
	mux.HandleFunc("POST /api/text", a.authed(a.postText))
	mux.HandleFunc("POST /api/image", a.authed(a.postImage))
	mux.HandleFunc("GET /api/image/{id}", a.authed(a.getImage))
	mux.HandleFunc("GET /api/push/key", a.authed(a.pushOn(a.pushKey)))
	mux.HandleFunc("POST /api/push/subscribe", a.authed(a.pushOn(a.pushSubscribe)))
	mux.HandleFunc("DELETE /api/push/subscribe", a.authed(a.pushOn(a.pushUnsubscribe)))
	mux.HandleFunc("GET /api/devices", a.authed(a.devices))
	mux.HandleFunc("DELETE /api/devices/{id}", a.authed(a.revokeDevice))
	a.adminRoutes(mux)
	// /api/ yang tidak dikenal → 404 JSON (bukan 405 dari "GET /"), supaya klien bisa memberi pesan yang jelas
	for _, m := range []string{"GET", "POST", "PUT", "PATCH", "DELETE"} {
		mux.HandleFunc(m+" /api/", func(w http.ResponseWriter, r *http.Request) {
			jsonError(w, http.StatusNotFound, "endpoint tidak dikenal (server PasteLAN mungkin versi lama / berbeda)")
		})
	}
	return secure(mux)
}

// secure memasang header keamanan di semua jawaban, dan mewajibkan header X-PasteLAN di /api/
// (header khusus tidak bisa dikirim situs lain tanpa izin CORS → perlindungan CSRF, selain cookie SameSite=Strict)
func secure(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "+
			"connect-src 'self'; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		if isHTTPS(r) {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
			if r.Header.Get("X-PasteLAN") != "1" {
				jsonError(w, http.StatusForbidden, "header X-PasteLAN wajib")
				return
			}
		} else {
			h.Set("Cache-Control", "no-cache") // halaman selalu dicek ulang → update server langsung terpakai
		}
		next.ServeHTTP(w, r)
	})
}

func fromProxy(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func isHTTPS(r *http.Request) bool {
	return r.TLS != nil || (fromProxy(r) && r.Header.Get("X-Forwarded-Proto") == "https")
}

// clientIP: di belakang reverse proxy lokal, IP asli = entri terakhir X-Forwarded-For (ditambahkan proxy itu sendiri,
// jadi tidak bisa dipalsukan klien); selain itu alamat koneksi
func clientIP(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if fromProxy(r) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	return host
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func tokenFrom(r *http.Request) string {
	if t, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
		return strings.TrimSpace(t)
	}
	if c, err := r.Cookie(cookieName); err == nil {
		return c.Value
	}
	return ""
}

type authedHandler func(w http.ResponseWriter, r *http.Request, d *device)

func (a *app) authed(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		d := a.auth.check(tokenFrom(r), clientKind("", r.UserAgent()))
		if d == nil {
			jsonError(w, http.StatusUnauthorized, "belum login")
			return
		}
		h(w, r, d)
	}
}

func setCookie(w http.ResponseWriter, value string, maxAge int) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: value, Path: "/", MaxAge: maxAge,
		HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode})
}

func (a *app) login(w http.ResponseWriter, r *http.Request) {
	var req struct{ Password, Name, Client string }
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "format salah")
		return
	}
	token, d, err := a.auth.login(clientIP(r), req.Password, req.Name, clientKind(req.Client, r.UserAgent()))
	a.loginResult(w, token, d, err)
}

// newPair: perangkat yang sudah login (Mac) meminta kode QR untuk menambah perangkat baru
func (a *app) newPair(w http.ResponseWriter, r *http.Request, d *device) {
	code, exp := a.auth.newPair(pairTTL)
	writeJSON(w, http.StatusOK, map[string]any{"code": code, "expires": exp.UnixMilli()})
}

// claimPair: perangkat baru (HP yang scan QR) menukar kode dengan token sendiri
func (a *app) claimPair(w http.ResponseWriter, r *http.Request) {
	var req struct{ Code, Name, Client string }
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		jsonError(w, http.StatusBadRequest, "format salah")
		return
	}
	token, d, err := a.auth.claimPair(clientIP(r), req.Code, req.Name, clientKind(req.Client, r.UserAgent()))
	a.loginResult(w, token, d, err)
}

func (a *app) loginResult(w http.ResponseWriter, token string, d *device, err error) {
	switch {
	case errors.Is(err, errLocked):
		w.Header().Set("Retry-After", strconv.Itoa(int(ipLockout.Seconds())))
		jsonError(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, errBadPassword), errors.Is(err, errBadPair):
		jsonError(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, errPwDisabled):
		jsonError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, errTooMany):
		jsonError(w, http.StatusConflict, err.Error())
	case err != nil:
		jsonError(w, http.StatusInternalServerError, "gagal menyimpan perangkat")
	default:
		setCookie(w, token, 400*24*3600) // batas maksimal browser ±400 hari; bisa dicabut kapan saja
		writeJSON(w, http.StatusOK, map[string]any{"token": token, "device": map[string]string{"id": d.ID, "name": d.Name, "kind": d.Kind}})
	}
}

func (a *app) logout(w http.ResponseWriter, r *http.Request, d *device) {
	a.auth.revoke(d.ID)
	setCookie(w, "", -1)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// publicConfig: info untuk halaman login (tanpa rahasia) → form password disembunyikan kalau dimatikan admin
func (a *app) publicConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"passwordLogin": a.auth.passwordLoginAvailable()})
}

// items: jawaban polling. ids = semua item yang masih ada (klien membuang yang sudah dihapus / kedaluwarsa),
// rev = penanda penghapusan (klien mengirimnya balik sebagai r=), max = batas jumlah item.
func (a *app) items(w http.ResponseWriter, r *http.Request, d *device) {
	q := r.URL.Query()
	after, _ := strconv.ParseInt(q.Get("after"), 10, 64)
	rev := int64(-1)
	if v, err := strconv.ParseInt(q.Get("r"), 10, 64); err == nil {
		rev = v
	}
	snap := a.store.poll(r.Context(), q.Get("s"), after, rev, q.Get("wait") == "1")
	writeJSON(w, http.StatusOK, map[string]any{"session": snap.session, "you": d.ID, "items": snap.items,
		"ids": snap.ids, "rev": snap.rev, "max": a.settings.get().MaxItems})
}

func (a *app) clearItems(w http.ResponseWriter, r *http.Request, d *device) {
	a.store.clear()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) deleteItem(w http.ResponseWriter, r *http.Request, d *device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if !a.store.remove(id) {
		jsonError(w, http.StatusNotFound, "item tidak ada lagi di riwayat")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func readBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, bool) {
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		jsonError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("terlalu besar (maks %d MB)", limit>>20))
		return nil, false
	}
	if err != nil {
		jsonError(w, http.StatusBadRequest, "gagal membaca isi")
		return nil, false
	}
	return b, true
}

func (a *app) postText(w http.ResponseWriter, r *http.Request, d *device) {
	b, ok := readBody(w, r, maxText)
	if !ok {
		return
	}
	if len(bytes.TrimSpace(b)) == 0 || !utf8.Valid(b) {
		jsonError(w, http.StatusBadRequest, "teks kosong / tidak valid")
		return
	}
	it := a.store.add(&item{Kind: "text", Text: string(b), Size: len(b), From: d.Name, Device: d.ID})
	if r.URL.Query().Get("notify") == "1" {
		a.notifyDevices(it, d.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": it.ID})
}

// imageType: jenis gambar dari isi file (bukan dari header klien). SVG & format lain ditolak.
func imageType(b []byte) string {
	switch ct := http.DetectContentType(b); ct {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return ct
	}
	// HEIC/HEIF (foto iPhone): kotak "ftyp" dengan brand heic/heix/mif1/msf1
	if len(b) >= 12 && string(b[4:8]) == "ftyp" {
		switch string(b[8:12]) {
		case "heic", "heix", "heim", "heis", "mif1", "msf1":
			return "image/heic"
		}
	}
	return ""
}

func (a *app) postImage(w http.ResponseWriter, r *http.Request, d *device) {
	b, ok := readBody(w, r, maxImage)
	if !ok {
		return
	}
	mime := imageType(b)
	if mime == "" {
		jsonError(w, http.StatusUnsupportedMediaType, "bukan gambar yang didukung (PNG, JPEG, GIF, WebP, HEIC)")
		return
	}
	it := a.store.add(&item{Kind: "image", Mime: mime, Size: len(b), From: d.Name, Device: d.ID, data: b})
	if r.URL.Query().Get("notify") == "1" {
		a.notifyDevices(it, d.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": it.ID})
}

func (a *app) getImage(w http.ResponseWriter, r *http.Request, d *device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	it := a.store.image(id)
	if it == nil {
		jsonError(w, http.StatusNotFound, "gambar tidak ada lagi di riwayat")
		return
	}
	ext := strings.TrimPrefix(it.Mime, "image/")
	w.Header().Set("Content-Type", it.Mime)
	w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=\"pastelan-%d.%s\"", it.ID, strings.Replace(ext, "jpeg", "jpg", 1)))
	w.Header().Set("Content-Length", strconv.Itoa(len(it.data)))
	_, _ = w.Write(it.data)
}

func (a *app) devices(w http.ResponseWriter, r *http.Request, d *device) {
	type out struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		Kind     string `json:"kind"`
		Created  int64  `json:"created"`
		LastSeen int64  `json:"lastSeen"`
		Current  bool   `json:"current"`
		Push     bool   `json:"push"`
	}
	list := []out{}
	for _, x := range a.auth.list() {
		list = append(list, out{x.ID, x.Name, x.Kind, x.Created.UnixMilli(), x.LastSeen.UnixMilli(), x.ID == d.ID, x.Push != nil})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": list})
}

func (a *app) revokeDevice(w http.ResponseWriter, r *http.Request, d *device) {
	if !a.auth.revoke(r.PathValue("id")) {
		jsonError(w, http.StatusNotFound, "perangkat tidak ditemukan")
		return
	}
	if r.PathValue("id") == d.ID {
		setCookie(w, "", -1)
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
