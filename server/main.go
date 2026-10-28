// PasteLAN server — perantara clipboard antara Mac dan HP lewat internet.
//   - Satu password (PASTELAN_PASSWORD) → tiap perangkat login sekali dan mendapat token sendiri (bisa dicabut)
//   - Isi clipboard hanya di memori (maks 20 item, kedaluwarsa 24 jam), tidak pernah ditulis ke disk / log
//   - Halaman web (PWA) ditanam di binary, tanpa CDN
//   - HTTPS lewat reverse proxy (mis. Caddy) atau langsung dengan PASTELAN_TLS_CERT / PASTELAN_TLS_KEY
//
// Jalankan: PASTELAN_PASSWORD='…' go run .   (tanpa dependensi di luar standard library)
package main

import (
	"embed"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

//go:embed web
var webFiles embed.FS

type config struct {
	addr     string // alamat dengar; default hanya lokal (di belakang reverse proxy)
	password string
	dataDir  string // hanya berisi devices.json (token perangkat dalam bentuk hash), bukan isi clipboard
	tlsCert  string
	tlsKey   string
}

func loadConfig() config {
	c := config{
		addr:     env("PASTELAN_ADDR", "127.0.0.1:8080"),
		password: os.Getenv("PASTELAN_PASSWORD"),
		dataDir:  env("PASTELAN_DATA", "data"),
		tlsCert:  os.Getenv("PASTELAN_TLS_CERT"),
		tlsKey:   os.Getenv("PASTELAN_TLS_KEY"),
	}
	if len([]rune(c.password)) < 12 {
		log.Fatal("PASTELAN_PASSWORD wajib diisi, minimal 12 karakter")
	}
	return c
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
	a, err := newApp(cfg.password, filepath.Join(cfg.dataDir, "devices.json"))
	if err != nil {
		log.Fatal(err)
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
	log.Printf("PasteLAN server di %s", cfg.addr)
	if cfg.tlsCert != "" {
		err = srv.ListenAndServeTLS(cfg.tlsCert, cfg.tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	log.Fatal(err)
}
