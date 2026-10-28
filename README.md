# PasteLAN

Berbagi **copy-paste teks & gambar** antara Mac dan HP lewat **server PasteLAN milik Anda sendiri**.
Ringan dan sederhana: aplikasi menu bar macOS (Swift, satu file) + server kecil (Go, satu binary, tanpa dependensi)
+ halaman web yang bisa di-**install sebagai aplikasi (PWA)** di HP. Mac dan HP **tidak perlu di Wi-Fi yang sama**.

```
 ┌──────── Mac ────────┐            ┌──── Server Anda ────┐            ┌──── HP (PWA) ────────────┐
 │  ⌘C  ───────────────┼── HTTPS ──▶│  isi hanya di RAM,  │── HTTPS ──▶│  muncul otomatis → Salin │
 │  ⌘V  ◀──────────────┼────────────┤  maks 20 item / 24j │◀───────────┤  tempel / gambar → Kirim │
 └─────────────────────┘            └─────────────────────┘            └──────────────────────────┘
```

<p align="center">
  <img src="docs/screenshots/hp-light.png" width="260" alt="PasteLAN di HP (terang)">
  <img src="docs/screenshots/hp-dark.png" width="260" alt="PasteLAN di HP (gelap)">
</p>

## Fitur

- **HP → Mac**: tempel teks atau pilih gambar (bisa beberapa sekaligus), tekan **Kirim**, lalu ⌘V di Mac.
  Gambar juga bisa ditempel langsung di kotak teks
- **Mac → HP**: setiap ⌘C di Mac (teks, screenshot, gambar dari browser, file gambar di Finder)
  **muncul otomatis** di HP dalam ±1 detik. Tekan **Salin** / **Salin gambar**
- **PWA**: install di iPhone & Android ("Install" / "Tambahkan ke Layar Utama"), tampil seperti aplikasi biasa
- Bisa dipakai dari **banyak perangkat** sekaligus (HP, tablet, laptop lain); tiap perangkat login sekali
- **Riwayat 20 item terakhir**; klik item di menu Mac untuk menyalinnya lagi
- Mode **otomatis** atau **manual** ("Kirim clipboard Mac sekarang") di Mac
- Opsi menyimpan gambar dari HP ke folder **Unduhan**
- Buka saat login, update dari menu (bertanda tangan), uninstall dari menu

## Cara pakai

1. **Pasang server** di VPS Anda (sekali saja), lihat [Server](#server).
2. **Mac**: klik ikon **⇄** di menu bar → **Atur server & login…** → isi alamat server dan password.
3. **HP**: scan QR code di menu Mac (atau buka alamat server), login dengan password yang sama, lalu
   **Install** / **Tambahkan ke Layar Utama**.
4. **HP → Mac**: tempel teks / pilih gambar, tekan **Kirim**, lalu ⌘V di Mac.
   **Mac → HP**: copy apa saja di Mac, isinya muncul di HP.

### Keterbatasan

- Arah HP → Mac selalu butuh satu ketukan (**Kirim**): Android dan iOS tidak mengizinkan web/aplikasi
  membaca clipboard HP secara otomatis.
- Halaman HP harus terbuka supaya menerima item baru dari Mac (setelah dibuka lagi, item yang terlewat langsung muncul).
- Butuh internet di Mac dan HP (lewat server).

## Keamanan

- **HTTPS** wajib (Caddy / Let's Encrypt). Server sendiri hanya mendengarkan `127.0.0.1`.
- **Password + token per perangkat**: password hanya dipakai sekali saat login. Setiap perangkat mendapat token acak
  256-bit sendiri; server hanya menyimpan **hash**-nya. Perangkat yang hilang bisa **dicabut** dari
  Pengaturan di halaman PasteLAN (atau "Keluar" di perangkat itu).
  - Browser: token di cookie `HttpOnly` + `Secure` + `SameSite=Strict` (tidak bisa dibaca JavaScript).
  - Mac: token di **Keychain**.
- **Batas percobaan login**: 5× salah dari satu IP → IP itu dikunci 15 menit; 100× salah per jam dari semua IP →
  login baru ditutup 15 menit (perangkat yang sudah login tetap jalan).
- **Isi clipboard hanya di memori server**: maks 20 item / 150 MB, kedaluwarsa **24 jam**, hilang saat server
  restart. Tidak pernah ditulis ke disk atau log. Pemilik server (Anda) secara teknis bisa melihat isinya.
- **Halaman web ketat**: Content-Security-Policy tanpa script inline / CDN, `X-Frame-Options: DENY`, `nosniff`,
  HSTS. Isi clipboard selalu ditampilkan sebagai teks (bukan HTML). Gambar dicek dari isinya
  (PNG/JPEG/GIF/WebP/HEIC; SVG ditolak).
- Semua request API wajib header `X-PasteLAN` (perlindungan CSRF, selain cookie `SameSite=Strict`).
- Isi dari **password manager** (bertanda `org.nspasteboard.ConcealedType`) **tidak pernah** dikirim dari Mac.
- **Update otomatis** aplikasi Mac hanya dipasang kalau cocok dengan tanda tangan Ed25519 pemilik repo
  (lihat [Rilis](#rilis)).

## Server

Satu binary Go tanpa dependensi (halaman web ikut di dalamnya). Panduan lengkap: [`server/README.md`](server/README.md).

```bash
# di VPS (Linux): unduh pastelan-server-linux-amd64 (atau -arm64) dari Releases
sudo install -m 755 pastelan-server-linux-amd64 /usr/local/bin/pastelan-server
echo "PASTELAN_PASSWORD=$(openssl rand -base64 24)" | sudo tee /etc/pastelan.env && sudo chmod 600 /etc/pastelan.env
sudo cp server/deploy/pastelan.service /etc/systemd/system/ && sudo systemctl enable --now pastelan
# HTTPS: pasang Caddy, salin server/deploy/Caddyfile (ganti domain), lalu: sudo systemctl reload caddy
```

## Instal aplikasi Mac

Unduh dari [Releases](https://github.com/kikiraihan/mac-os-PasteLAN/releases/latest):

- **`PasteLAN.zip`**: ekstrak, pindahkan `PasteLAN.app` ke **Applications**, lalu buka.
  Kalau macOS menolak membuka (aplikasi belum dinotarisasi): klik kanan → **Open**, atau jalankan
  `xattr -cr /Applications/PasteLAN.app`.
- **`install-PasteLAN.zip`**: ekstrak, lalu jalankan `bash install-PasteLAN.command`
  (compile di Mac Anda, butuh Xcode Command Line Tools).

Butuh **macOS 13 (Ventura)** atau lebih baru. Pengguna versi lama (0.x, mode Wi-Fi lokal): setelah update,
PasteLAN meminta alamat server sekali.

## Build sendiri

```bash
xcode-select --install   # sekali saja
./scripts/build.sh       # hasil: build/PasteLAN.app
cp -R build/PasteLAN.app /Applications/ && open /Applications/PasteLAN.app

cd server && go test ./... && go build -o pastelan-server .   # server (Go 1.22+)
```

## Cara kerja (singkat)

| Bagian | Teknologi |
|---|---|
| Server | Go `net/http` (standard library saja), satu binary, halaman web di-`embed` |
| Real-time | Long-polling (`GET /api/items?wait=1`, ditahan maks 25 detik) |
| Login | Password → token per perangkat (hash SHA-256 di `devices.json`), cookie / Bearer |
| Halaman HP | HTML/CSS/JS biasa (tanpa framework / CDN) + service worker & manifest (PWA) |
| Aplikasi Mac | Swift + AppKit, `URLSession`, token di Keychain, `NSPasteboard.changeCount` tiap 0,8 detik |

Rencana pengembangan ada di [`_todo/`](_todo/), catatan keamanan & ide lanjutan di [`_techdebt/`](_techdebt/).

## Rilis

Versi diatur di `Resources/Info.plist` (lihat [AGENTS.md](AGENTS.md)). Merge ke `main` dengan versi yang belum
punya tag akan otomatis membuat tag `v<versi>` dan rilis lewat GitHub Actions (aplikasi Mac + binary server Linux).

### Tanda tangan rilis (auto-update)

Auto-update di aplikasi hanya memasang `PasteLAN.zip` yang punya `PasteLAN.zip.sig` valid untuk kunci publik di
`Updater.publicKey`. Yang ditandatangani: `"PasteLAN <tag>\n"` + isi zip (Ed25519, `scripts/sign-release.swift`).

1. Sekali saja, di Mac sendiri: `swift scripts/sign-release.swift keygen` → kunci privat di `~/.pastelan-signing-key`,
   kunci publik tercetak di terminal → tempel ke `Updater.publicKey` di `main.swift`.
2. Pilih cara menandatangani:
   - **Otomatis (CI)**: simpan isi `~/.pastelan-signing-key` sebagai GitHub Secret `PASTELAN_SIGNING_KEY`.
     Melindungi dari aset rilis yang diganti, tapi **tidak** dari akun GitHub yang dibobol (pembobol bisa memakai
     secret lewat workflow).
   - **Manual (lebih aman)**: jangan simpan secret. Setelah rilis jadi, di Mac sendiri:
     `swift scripts/sign-release.swift sign PasteLAN.zip v<versi> > PasteLAN.zip.sig`, lalu unggah `PasteLAN.zip.sig`
     ke halaman rilis. Kunci privat tidak pernah meninggalkan Mac Anda.
