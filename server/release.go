package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Aplikasi Android (PasteLAN.apk) ditawarkan di halaman web, halaman admin, & dialog "Tambah HP" di Mac.
// File-nya tetap di rilis GitHub (repo publik): server hanya membaca info rilis terbaru dari api.github.com
// (di-cache) lalu mengalihkan /unduh/PasteLAN.apk ke tautan github.com yang polanya dicek. Tidak ada isi
// clipboard / data perangkat yang dikirim ke GitHub. PASTELAN_RELEASE_REPO=off mematikan fitur ini.

const (
	defaultReleaseRepo = "kikiraihan/mac-os-PasteLAN"
	apkName            = "PasteLAN.apk"
	apkPath            = "/unduh/" + apkName
	releaseCacheOK     = 15 * time.Minute
	releaseCacheFail   = 2 * time.Minute
)

type apkInfo struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	URL       string `json:"url,omitempty"` // tautan unduh di server ini (bukan GitHub langsung)
	download  string // tautan github.com (tujuan pengalihan)
}

type apkRelease struct {
	repo   string // "owner/nama"; kosong = nonaktif
	api    string // https://api.github.com (diganti di tes)
	client *http.Client

	mu     sync.Mutex
	cached apkInfo
	until  time.Time
}

func newAPKRelease(repo string) *apkRelease {
	if repo == "off" || strings.Count(repo, "/") != 1 {
		repo = ""
	}
	return &apkRelease{repo: repo, api: "https://api.github.com", client: &http.Client{Timeout: 10 * time.Second,
		// jangan ikuti pengalihan ke host lain
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

// latest: info APK di rilis terbaru (di-cache; gagal menghubungi GitHub = "belum tersedia" sebentar)
func (r *apkRelease) latest(ctx context.Context) apkInfo {
	if r == nil || r.repo == "" {
		return apkInfo{}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if time.Now().Before(r.until) {
		return r.cached
	}
	info, err := r.fetch(context.WithoutCancel(ctx)) // klien menutup koneksi ≠ GitHub gagal (batas waktu di client)
	r.cached, r.until = info, time.Now().Add(releaseCacheOK)
	if err != nil {
		r.until = time.Now().Add(releaseCacheFail)
	}
	return info
}

func (r *apkRelease) fetch(ctx context.Context) (apkInfo, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", r.api+"/repos/"+r.repo+"/releases/latest", nil)
	if err != nil {
		return apkInfo{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "PasteLAN-server")
	res, err := r.client.Do(req)
	if err != nil {
		return apkInfo{}, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound { // belum ada rilis
		return apkInfo{}, nil
	}
	if res.StatusCode != http.StatusOK {
		return apkInfo{}, errStatus(res.StatusCode)
	}
	var rel struct {
		Tag    string `json:"tag_name"`
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&rel); err != nil {
		return apkInfo{}, err
	}
	prefix := "https://github.com/" + r.repo + "/releases/download/"
	for _, a := range rel.Assets {
		if a.Name == apkName && strings.HasPrefix(a.URL, prefix) && !strings.ContainsAny(a.URL, "\r\n") {
			return apkInfo{Available: true, Version: strings.TrimPrefix(rel.Tag, "v"), URL: apkPath, download: a.URL}, nil
		}
	}
	return apkInfo{Version: strings.TrimPrefix(rel.Tag, "v")}, nil // rilis tanpa APK (kunci Android belum diatur)
}

type errStatus int

func (e errStatus) Error() string { return http.StatusText(int(e)) }

// androidApp: info untuk tawaran aplikasi Android (tanpa login: dipakai juga di halaman masuk)
func (a *app) androidApp(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.apk.latest(r.Context()))
}

// downloadAPK: tautan unduh untuk browser (navigasi biasa, tanpa header X-PasteLAN) → dialihkan ke rilis GitHub.
// Tanpa login: HP baru perlu aplikasinya dulu sebelum bisa masuk (scan QR dari aplikasi).
func (a *app) downloadAPK(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	info := a.apk.latest(r.Context())
	if !info.Available {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, "Aplikasi Android belum tersedia di rilis PasteLAN terbaru.\n")
		return
	}
	http.Redirect(w, r, info.download, http.StatusFound)
}
