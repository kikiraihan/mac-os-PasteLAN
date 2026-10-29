# PasteLAN

Berbagi **copy-paste teks & gambar** antara Mac dan HP lewat **server PasteLAN milik Anda sendiri**.
Ringan dan sederhana: aplikasi menu bar macOS (Swift, satu file) + server kecil (Go, satu binary, tanpa dependensi)
+ halaman web yang bisa di-**install sebagai aplikasi (PWA)** di HP. Mac dan HP **tidak perlu di Wi-Fi yang sama**.

Tidak punya server? Pilih metode **Wi-Fi lokal** di menu: Mac menjalankan server kecil sendiri, HP di jaringan yang
sama cukup scan QR code (lihat [Dua metode](#dua-metode)).

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
- **Clipboard manager di Mac** (gaya Clipy): riwayat langsung di menu (default 15 clip, diatur di **Pengaturan… → Umum**),
  klik item atau tekan **⌘0–⌘9** saat menu terbuka untuk menyalinnya lagi, plus kotak **Cari clip…**;
  **tahan ⌥ lalu klik** (atau ⌥⌘0–⌥⌘9) untuk menghapus satu clip, bisa diurungkan dari menu; **tahan ⇧ lalu klik** untuk
  mengirim satu clip saja ke server / HP (berguna saat kirim otomatis / sinkron mati)
- **Sinkron bisa dimatikan** dari menu: PasteLAN jadi clipboard manager saja. Saat dinyalakan lagi hanya copy baru
  yang dikirim; clip lama bisa dicentang lalu dikirim dari **Clipboard manager…** (tab Clipboard di Pengaturan)
- **Pencarian clip** juga di halaman web (browser / HP)
- **Hapus per item** atau **hapus semua** dari halaman web (ikut hilang di semua perangkat)
- **Halaman admin** (`https://server/admin`, bisa dibuka nyaman di HP): link setup untuk perangkat baru, kelola
  perangkat, password perangkat, **ganti password admin**, hapus otomatis & lama penyimpanan, batas jumlah item / memori
- Mode **otomatis** atau **manual** ("Kirim clipboard Mac sekarang") di Mac
- Opsi menyimpan gambar dari HP ke folder **Unduhan**
- Buka saat login, update dari menu (bertanda tangan), uninstall dari menu

## Cara pakai

1. **Pasang server** di VPS Anda (sekali saja), lihat [Server](#server).
2. **Mac**: buka `https://server-anda/admin` (password admin) → **Buat link setup**. Klik ikon **📎** (penjepit kertas) di
   menu bar → **Atur server & login…** → tempel link itu (tanpa password). Bisa juga alamat server + password perangkat
   kalau login dengan password diaktifkan di admin.
3. **HP**: menu Mac → **Tambah HP (scan QR)…**, scan dengan kamera HP → HP langsung masuk **tanpa mengetik
   password**. Lalu **Install** / **Tambahkan ke Layar Utama**. (Atau buka link setup dari admin di HP.)
4. **HP → Mac**: tempel teks / pilih gambar, tekan **Kirim**, lalu ⌘V di Mac.
   **Mac → HP**: copy apa saja di Mac, isinya muncul di HP.

## Dua metode

Pilih di menu **📎 → Pengaturan… → Koneksi → Metode**. Hanya satu yang aktif; metode yang tidak dipakai dimatikan penuh.

| | **Server PasteLAN** (default) | **Wi-Fi lokal** (tanpa server) |
|---|---|---|
| Butuh | Server sendiri (VPS + domain) | Mac & HP di Wi-Fi yang sama (atau Mac memakai hotspot HP) |
| Jarak | Di mana saja (internet) | Satu jaringan |
| HP | PWA, bisa di-install; **Salin gambar** | Halaman web dari Mac (HTTP lokal); salin gambar dengan tekan lama |
| Masuk | Link setup dari admin / scan QR dari Mac (opsional: password) → token per perangkat | Scan QR (kunci 256-bit di link) |
| Keamanan | HTTPS | Isi dienkripsi ChaCha20-Poly1305 dengan kunci di QR |

Mode Wi-Fi lokal:
- Kalau macOS bertanya **"Izinkan PasteLAN menerima koneksi masuk?"**, pilih **Izinkan**.
- Wi-Fi **kantor / kampus / publik** sering memblokir antar-perangkat, dan HP yang memakai data seluler tidak bisa
  menjangkau Mac. Lihat baris **"Koneksi masuk terakhir"** di menu: kalau tidak muncul IP HP, permintaannya tidak
  sampai ke Mac. Pakai Wi-Fi rumah / hotspot HP, atau metode server.
- **Reset link (putuskan semua HP)…** mengganti kunci dan memulai ulang server lokal. Port **8787**
  (otomatis pindah ke 8788, … kalau dipakai aplikasi lain).

### Keterbatasan

- Arah HP → Mac selalu butuh satu ketukan (**Kirim**): Android dan iOS tidak mengizinkan web/aplikasi
  membaca clipboard HP secara otomatis.
- Halaman HP harus terbuka supaya menerima item baru dari Mac (setelah dibuka lagi, item yang terlewat langsung muncul).
- Metode server butuh internet di Mac dan HP.

## Keamanan

- **HTTPS** wajib (Caddy / Let's Encrypt). Server sendiri hanya mendengarkan `127.0.0.1`.
- **QR sekali pakai**: "Tambah HP (scan QR)…" di Mac membuat kode acak 256-bit yang berlaku **5 menit** dan hanya
  untuk **satu** perangkat (server hanya menyimpan hash-nya; kode ada di `#pair=` sehingga tidak masuk log / Referer,
  dan langsung dihapus dari alamat setelah dipakai). Kode hanya dibuat saat diminta, bukan setiap menu dibuka.
- **Admin**: halaman `/admin` dengan password sendiri (`PASTELAN_ADMIN_PASSWORD`, hanya di server; bisa diganti dari
  halaman admin dengan mengetik password lama → disimpan sebagai hash PBKDF2, sesi admin lain dikeluarkan). Sesi admin di
  cookie terpisah (`HttpOnly` + `Secure` + `SameSite=Strict`, 12 jam, hanya di memori). **Link setup** dari admin
  sama seperti QR: kode acak 256-bit, sekali pakai, berlaku 10 menit (bisa diatur 1–60).
- **Password perangkat (opsional) + token per perangkat**: login dengan password bisa dimatikan di admin. Password
  yang dibuat dari admin disimpan sebagai hash PBKDF2-SHA256 (`settings.json`). Setiap perangkat mendapat token acak
  256-bit sendiri; server hanya menyimpan **hash**-nya. Perangkat yang hilang bisa **dicabut** dari
  Pengaturan di halaman PasteLAN (atau "Keluar" di perangkat itu).
  - Browser: token di cookie `HttpOnly` + `Secure` + `SameSite=Strict` (tidak bisa dibaca JavaScript).
  - Mac: token di **Keychain**.
- **Batas percobaan login** (password perangkat, password admin, atau kode QR / link setup): 5× salah dari satu IP → IP itu dikunci 15 menit; 100× salah per jam dari semua IP →
  login baru ditutup 15 menit (perangkat yang sudah login tetap jalan).
- **Isi clipboard hanya di memori server**: default maks 20 item / 150 MB, kedaluwarsa **24 jam** (diatur di admin;
  hapus otomatis bisa dimatikan), selalu hilang saat server restart. Tidak pernah ditulis ke disk atau log. Pemilik
  server (Anda) secara teknis bisa melihat isinya.
- **Halaman web ketat**: Content-Security-Policy tanpa script inline / CDN, `X-Frame-Options: DENY`, `nosniff`,
  HSTS. Isi clipboard selalu ditampilkan sebagai teks (bukan HTML). Gambar dicek dari isinya
  (PNG/JPEG/GIF/WebP/HEIC; SVG ditolak).
- Semua request API wajib header `X-PasteLAN` (perlindungan CSRF, selain cookie `SameSite=Strict`).
- Isi dari **password manager** (bertanda `org.nspasteboard.ConcealedType`) **tidak pernah** dikirim dari Mac.
- **Update otomatis** aplikasi Mac hanya dipasang kalau cocok dengan tanda tangan Ed25519 pemilik repo
  (lihat [Rilis](#rilis)).
- **Metode Wi-Fi lokal**: hanya perangkat di jaringan lokal yang dilayani; kunci dicek sebelum isi request dibaca;
  header `X-Auth` sekali pakai (anti replay); batas koneksi per perangkat. Batasan: halamannya dimuat lewat HTTP,
  jadi penyerang **aktif** di Wi-Fi yang sama (mis. ARP spoofing) secara teori bisa mencuri kunci. Di Wi-Fi yang
  tidak dipercaya, pakai metode server atau hotspot HP sendiri.

## Server

Satu binary Go tanpa dependensi (halaman web ikut di dalamnya). Panduan lengkap: [`server/README.md`](server/README.md).

```bash
# di VPS (Linux): unduh pastelan-server-linux-amd64 (atau -arm64) dari Releases
sudo install -m 755 pastelan-server-linux-amd64 /usr/local/bin/pastelan-server
echo "PASTELAN_ADMIN_PASSWORD=$(openssl rand -base64 24)" | sudo tee /etc/pastelan.env && sudo chmod 600 /etc/pastelan.env
sudo cat /etc/pastelan.env   # catat password admin ini (contoh lengkap: server/deploy/pastelan.env.example)
sudo cp server/deploy/pastelan.service /etc/systemd/system/ && sudo systemctl enable --now pastelan
# HTTPS: pasang Caddy, salin server/deploy/Caddyfile (ganti domain), lalu: sudo systemctl reload caddy
```

Lalu buka `https://domain-anda/admin` → **Buat link setup** → tempel di Mac. Server **tidak** ikut update otomatis
aplikasi Mac: pasang **CI/CD** sekali ([`server/CICD.md`](server/CICD.md)) supaya setiap perubahan `server/` di
`main` langsung di-deploy ke VPS (backup, health check, rollback otomatis), atau perbarui manual
(`server/README.md` → *Memperbarui server*).

## Instal aplikasi Mac

Unduh dari [Releases](https://github.com/kikiraihan/mac-os-PasteLAN/releases/latest):

- **`PasteLAN.zip`**: ekstrak, pindahkan `PasteLAN.app` ke **Applications**, lalu buka.
  Kalau macOS menolak membuka (aplikasi belum dinotarisasi): klik kanan → **Open**, atau jalankan
  `xattr -cr /Applications/PasteLAN.app`.
- **`install-PasteLAN.zip`**: ekstrak, lalu jalankan `bash install-PasteLAN.command`
  (compile di Mac Anda, butuh Xcode Command Line Tools).

Butuh **macOS 13 (Ventura)** atau lebih baru. Pengguna versi lama (0.x): setelah update, PasteLAN meminta alamat
server sekali; pilih **Pakai Wi-Fi lokal saja** untuk tetap tanpa server.

## Build sendiri

```bash
xcode-select --install   # sekali saja
./scripts/build.sh       # hasil: build/PasteLAN.app
cp -R build/PasteLAN.app /Applications/ && open /Applications/PasteLAN.app

cd server && go test ./... && go build -o pastelan-server .   # server (Go 1.24+)
```

## Cara kerja (singkat)

| Bagian | Teknologi |
|---|---|
| Server | Go `net/http` (standard library saja), satu binary, halaman web di-`embed` |
| Real-time | Long-polling (`GET /api/items?wait=1`, ditahan maks 25 detik) |
| Login | Link setup / QR sekali pakai atau password → token per perangkat (hash SHA-256 di `devices.json`), cookie / Bearer |
| Admin | `/admin`, password dari environment; pengaturan di `settings.json` (0600) |
| Halaman HP | HTML/CSS/JS biasa (tanpa framework / CDN) + service worker & manifest (PWA) |
| Aplikasi Mac | Swift + AppKit, `URLSession`, token di Keychain, `NSPasteboard.changeCount` tiap 0,8 detik |
| Wi-Fi lokal | Server HTTP di Mac (`NWListener`), halaman HP ditanam di aplikasi, ChaCha20-Poly1305 (CryptoKit ⇄ JS) |

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
