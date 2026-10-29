# AGENTS.md

Panduan untuk agen AI (Claude, dll.) yang bekerja di repo ini.

## Versioning

Format versi: **`va.b.c`** (tanpa `v` di `Info.plist`, mis. `0.1.0`; tag rilis jadi `v0.1.0`).

| Bagian | Naik ketika | Contoh |
|---|---|---|
| **a** (major) | perubahan besar (sangat jarang) atau ada *breaking change* | `0.7.3` → `1.0.0` |
| **b** (minor) | ada fitur baru, atau perubahan style mayor | `0.7.3` → `0.8.0` |
| **c** (patch) | perbaikan bug, atau perubahan style minor | `0.7.3` → `0.7.4` |

Aturan:

- Saat `a` naik, `b` dan `c` di-reset ke 0. Saat `b` naik, `c` di-reset ke 0.
- **Setiap PR yang mengubah aplikasi wajib menaikkan versi** di `Resources/Info.plist`:
  - `CFBundleShortVersionString` → versi baru sesuai tabel di atas.
  - `CFBundleVersion` → naik 1 (nomor build, selalu bertambah).
- Kalau satu PR berisi beberapa jenis perubahan, ambil kenaikan yang **tertinggi**
  (mis. fitur baru + bug fix → naikkan `b`).
- PR yang hanya mengubah dokumentasi, README, CI, atau berkas agen (tanpa mengubah aplikasi)
  **tidak** menaikkan versi.
- Hitung versi baru dari versi di branch `main` terbaru, bukan dari branch lama.
- Versi lama dua bagian (mis. `0.6`) dianggap `0.6.0`.
- Sebutkan versi lama → baru di deskripsi PR (mis. `Versi: 0.6.0 → 0.7.0 (fitur baru)`).

Merge ke `main` dengan versi yang belum punya tag akan otomatis membuat tag `v<versi>` dan rilis
(lihat `.github/workflows/build.yml`).

## Struktur & catatan proyek

- Dua komponen, keduanya tanpa dependensi:
  - Aplikasi Mac: satu file `Sources/PasteLAN/main.swift` (Swift + AppKit). Dua metode, dipilih di menu
    (`mode` di UserDefaults, default `server`; hanya satu yang jalan):
    - Server: klien `PasteServer` (hanya Foundation), token di Keychain.
    - Riwayat menu (gaya CopyClip): `ClipHistory` (hanya Foundation, bisa diuji di Linux) = semua copy di Mac +
      kiriman perangkat lain, disimpan di `~/Library/Application Support/PasteLAN/History`.
    - Wi-Fi lokal: `LANServer` + `HTTPServer` (Network.framework) + halaman HP `enum Page`. Isi `/api/` dienkripsi
      ChaCha20-Poly1305 (Swift `CryptoKit` ⇄ JS `AEAD` di `enum Page`, format `nonce + ciphertext + tag`,
      AAD `PL1|req|…`, `PL1|body|…`, `PL1|resp|…`). Ubah format di kedua sisi sekaligus.
  - Server: `server/` (Go, standard library saja). Halaman web / PWA di `server/web/` (HTML/CSS/JS biasa,
    tanpa framework / CDN, di-`embed` ke binary). Cek: `cd server && gofmt -l . && go vet ./... && go test -race ./...`.
    Halaman admin `/admin` (`web/admin.html` + `admin.css` + `admin.js`, password `PASTELAN_ADMIN_PASSWORD` atau hash
    PBKDF2 `adminPassword` di `settings.json` bila diganti dari halaman admin): link setup, perangkat, password perangkat
    (opsional, hash PBKDF2 di `settings.json`), ganti password admin, batas riwayat. Tanpa database: `settings.json`
    + `devices.json` cukup (dibaca sekali saat start, ditulis atomik). Agen yang memasang server: baca
    `server/AGENTS.md` (jangan salin password contoh dari `deploy/pastelan.env.example`).
    CI/CD server: `server-ci.yml` (cek + build) dan `deploy-server.yml` (push `main` yang mengubah `server/` → SSH →
    `server/deploy/deploy.sh`: backup, health check, rollback otomatis). Panduan: `server/CICD.md`.
- Versi di `Resources/Info.plist` berlaku untuk keduanya (satu rilis = aplikasi Mac + binary server).
- Rencana kerja ada di `_todo/` (satu folder per inisiatif: file sprint + `00-tracker.md`).
  Perbarui tracker setiap kali tugas selesai.
- Ide yang ditunda / utang teknis ada di `_techdebt/`.
- Keamanan (jangan dilonggarkan): HTTPS lewat reverse proxy; link setup / QR / password → token per perangkat
  (server hanya simpan hash); password admin & perangkat min. 12 karakter, bukan template; semua `/api/` wajib
  header `X-PasteLAN: 1`; cookie `HttpOnly` + `Secure` + `SameSite=Strict`;
  CSP tanpa `unsafe-*` (jangan tambah script / style inline atau CDN); isi clipboard hanya di memori server dan
  selalu ditampilkan lewat `textContent`; jenis gambar dicek dari isi (tanpa SVG).
  Auto-update wajib tanda tangan Ed25519 (`scripts/sign-release.swift`). Jangan pernah meminta / menyimpan kunci privat.
  Catatan keamanan di `_techdebt/keamanan.md`.
- Tidak ada Mac di lingkungan agen cloud: cek sintaks dengan `swiftc -parse Sources/PasteLAN/main.swift`
  (toolchain Swift Linux), build sebenarnya dicek oleh GitHub Actions (macOS). Bagian `PasteServer` hanya memakai
  Foundation, jadi bisa dikompilasi & diuji di Linux terhadap server Go.
