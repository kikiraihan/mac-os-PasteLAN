// PasteLAN server — perantara clipboard antara Mac dan HP lewat internet.
//   - Perangkat masuk lewat link setup / QR sekali pakai, atau password bersama (PASTELAN_PASSWORD, opsional)
//     → tiap perangkat mendapat token sendiri (bisa dicabut)
//   - Halaman admin (/admin, password PASTELAN_ADMIN_PASSWORD, bisa diganti dari halaman admin): link setup, perangkat,
//     password, batas riwayat
//   - Isi clipboard hanya di memori (default maks 20 item, kedaluwarsa 24 jam), tidak pernah ditulis ke disk / log
//   - Halaman web (PWA) ditanam di binary, tanpa CDN
//   - HTTPS lewat reverse proxy (mis. Caddy) atau langsung dengan PASTELAN_TLS_CERT / PASTELAN_TLS_KEY
//
// Jalankan: PASTELAN_ADMIN_PASSWORD='…' go run .   (tanpa dependensi di luar standard library)
package main

import (
	"embed"
	"errors"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"os"
	"time"
)

//go:embed web
var webFiles embed.FS

// version diisi saat build rilis: -ldflags "-X main.version=1.2.0"
var version = "dev"

type config struct {
	addr          string // alamat dengar; default hanya lokal (di belakang reverse proxy)
	password      string // opsional: password bersama untuk login perangkat
	adminPassword string // opsional: password halaman admin (kosong → admin nonaktif)
	dataDir       string // devices.json (token perangkat dalam bentuk hash) + settings.json, bukan isi clipboard
	tlsCert       string
	tlsKey        string
}

func loadConfig() config {
	c := config{
		addr:          env("PASTELAN_ADDR", "127.0.0.1:8080"),
		password:      os.Getenv("PASTELAN_PASSWORD"),
		adminPassword: os.Getenv("PASTELAN_ADMIN_PASSWORD"),
		dataDir:       env("PASTELAN_DATA", "data"),
		tlsCert:       os.Getenv("PASTELAN_TLS_CERT"),
		tlsKey:        os.Getenv("PASTELAN_TLS_KEY"),
	}
	if err := c.check(); err != nil && !errors.Is(err, errNoLogin) {
		log.Fatal(err)
	}
	return c
}

// errNoLogin: tidak ada password sama sekali. Masih boleh kalau password admin sudah diganti dari halaman admin
// (hash di settings.json) — diperiksa lagi di main setelah pengaturan dibaca.
var errNoLogin = errors.New("isi PASTELAN_ADMIN_PASSWORD (disarankan) dan/atau PASTELAN_PASSWORD, lihat deploy/pastelan.env.example")

// check: minimal satu cara masuk; password yang diisi minimal 12 karakter, bukan contoh template, dan berbeda
func (c config) check() error {
	if c.password == "" && c.adminPassword == "" {
		return errNoLogin
	}
	if c.adminPassword != "" {
		if err := checkNewPassword(c.adminPassword); err != nil {
			return errors.New("PASTELAN_ADMIN_PASSWORD: " + err.Error())
		}
	}
	if c.password != "" {
		if err := checkNewPassword(c.password); err != nil {
			return errors.New("PASTELAN_PASSWORD: " + err.Error())
		}
	}
	if c.password != "" && c.password == c.adminPassword {
		return errors.New("PASTELAN_ADMIN_PASSWORD harus berbeda dari PASTELAN_PASSWORD")
	}
	return nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	cfg := loadConfig()
	_ = mime.AddExtensionType(".webmanifest", "application/manifest+json")
	if err := os.MkdirAll(cfg.dataDir, 0o700); err != nil {
		log.Fatal(err)
	}
	a, err := newApp(cfg.password, cfg.adminPassword, cfg.dataDir)
	if err != nil {
		log.Fatal(err)
	}
	switch {
	case !a.auth.adminEnabled() && cfg.password == "":
		log.Fatal(errNoLogin)
	case a.settings.get().AdminPassword != "":
		log.Print("password admin diatur dari halaman admin (PASTELAN_ADMIN_PASSWORD tidak dipakai)")
	case cfg.adminPassword == "":
		log.Print("PASTELAN_ADMIN_PASSWORD kosong → halaman admin nonaktif")
	}
	web, _ := fs.Sub(webFiles, "web")
	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           a.routes(web),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute, // unggah gambar 30 MB di koneksi lambat
		WriteTimeout:      2 * time.Minute, // long-poll 25 detik + unduh gambar
		IdleTimeout:       time.Minute,
		MaxHeaderBytes:    32 << 10,
	}
	log.Printf("PasteLAN server %s di %s", version, cfg.addr)
	if cfg.tlsCert != "" {
		err = srv.ListenAndServeTLS(cfg.tlsCert, cfg.tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	log.Fatal(err)
}
