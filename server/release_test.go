package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestAndroidAPK(t *testing.T) {
	ts, a := newTestServer(t)
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path string, hdr bool) (*http.Response, string) {
		req, _ := http.NewRequest("GET", ts.URL+path, nil)
		if hdr {
			req.Header.Set("X-PasteLAN", "1")
		}
		res, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		return res, readAll(res)
	}

	// fitur dimatikan → belum tersedia, unduh 404
	if _, b := get("/api/app/android", true); !strings.Contains(b, `"available":false`) {
		t.Fatalf("nonaktif: %s", b)
	}
	if res, _ := get(apkPath, false); res.StatusCode != 404 {
		t.Fatalf("unduh saat nonaktif: %d", res.StatusCode)
	}

	var calls atomic.Int32
	var body atomic.Value
	body.Store(`{"tag_name":"v1.15.0","assets":[{"name":"PasteLAN.zip","browser_download_url":"https://github.com/o/r/releases/download/v1.15.0/PasteLAN.zip"}]}`)
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/repos/o/r/releases/latest" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, body.Load())
	}))
	defer gh.Close()
	newRel := func() {
		a.apk = newAPKRelease("o/r")
		a.apk.api = gh.URL
	}

	// rilis tanpa APK (kunci Android belum diatur)
	newRel()
	if _, b := get("/api/app/android", true); !strings.Contains(b, `"available":false`) || !strings.Contains(b, `"version":"1.15.0"`) {
		t.Fatalf("rilis tanpa APK: %s", b)
	}

	// APK ada → info + pengalihan ke github.com, tanpa login & tanpa header X-PasteLAN (tautan biasa)
	body.Store(`{"tag_name":"v1.15.0","assets":[{"name":"PasteLAN.apk","browser_download_url":"https://github.com/o/r/releases/download/v1.15.0/PasteLAN.apk"}]}`)
	newRel()
	_, b := get("/api/app/android", true)
	var info struct {
		Available bool
		Version   string
		URL       string
	}
	_ = json.Unmarshal([]byte(b), &info)
	if !info.Available || info.Version != "1.15.0" || info.URL != apkPath || strings.Contains(b, "github.com") {
		t.Fatalf("info APK: %s", b)
	}
	res, _ := get(apkPath, false)
	if res.StatusCode != http.StatusFound || res.Header.Get("Location") != "https://github.com/o/r/releases/download/v1.15.0/PasteLAN.apk" {
		t.Fatalf("unduh APK: %d %q", res.StatusCode, res.Header.Get("Location"))
	}
	// /api/ tetap wajib header X-PasteLAN
	if res, _ := get("/api/app/android", false); res.StatusCode != http.StatusForbidden {
		t.Fatalf("tanpa header: %d", res.StatusCode)
	}
	// di-cache: GitHub tidak dihubungi lagi
	before := calls.Load()
	get("/api/app/android", true)
	get(apkPath, false)
	if calls.Load() != before {
		t.Fatal("info rilis tidak di-cache")
	}

	// tautan dari host / repo lain tidak pernah dipakai sebagai tujuan pengalihan
	body.Store(`{"tag_name":"v9","assets":[{"name":"PasteLAN.apk","browser_download_url":"https://jahat.example/PasteLAN.apk"}]}`)
	newRel()
	if res, _ := get(apkPath, false); res.StatusCode != 404 {
		t.Fatalf("tautan asing harus ditolak: %d %q", res.StatusCode, res.Header.Get("Location"))
	}
}

func readAll(res *http.Response) string {
	var b strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := res.Body.Read(buf)
		b.Write(buf[:n])
		if err != nil {
			return b.String()
		}
	}
}
