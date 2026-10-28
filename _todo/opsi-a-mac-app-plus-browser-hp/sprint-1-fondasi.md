# Sprint 1 — Fondasi

**Tujuan:** aplikasi menu bar berjalan, server HTTP lokal hidup, HP bisa membuka alamatnya lewat QR code.

## User story

- Sebagai pengguna, saya menjalankan PasteLAN dan melihat ikon ⇄ di menu bar.
- Saat saya klik ikon, saya melihat **QR code** dan alamat `http://<ip-mac>:8787`.
- Saya bisa mematikan/menyalakan berbagi kapan saja.

## Lingkup

### Struktur repo (sama dengan LiteScroller / LiteMonitor)

```
Sources/PasteLAN/main.swift      # satu file sumber
Resources/Info.plist             # versi & identitas aplikasi
scripts/build.sh                 # build .app (ARCH=universal untuk CI)
scripts/make-installer.sh        # installer satu file .command
.github/workflows/build.yml      # build + rilis otomatis
AGENTS.md, CLAUDE.md             # aturan versioning
```

### Info.plist

- `CFBundleIdentifier` = `id.local.pastelan`
- `CFBundleShortVersionString` = `0.1.0`, `CFBundleVersion` = `1`
- `LSUIElement` = true (tanpa ikon Dock), `LSMinimumSystemVersion` = 13.0
- `NSLocalNetworkUsageDescription`: alasan butuh jaringan lokal

### Server HTTP (Network.framework)

- `NWListener` TCP, semua antarmuka, port `8787`; kalau gagal → coba `8788`, `8789`, … (maks 12 kali)
- Parser HTTP/1.1 minimal: request line, header (huruf kecil), `Content-Length`, query string
- Setiap respons `Connection: close` (sederhana, tanpa keep-alive)
- Batas: header 32 KB, body 30 MB, 64 koneksi aktif, request harus lengkap dalam 60 detik
- Header keamanan: `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`

### Token

- 16 byte acak (hex 32 karakter), dibuat sekali lalu disimpan di `UserDefaults`
- Halaman: `/?t=<token>`; API: header `X-Token` (atau `?t=` untuk `<img>`)
- Dibandingkan secara constant-time

### IP lokal

- `getifaddrs` → IPv4, `IFF_UP`, bukan loopback, bukan `169.254.x.x`
- Prioritas: `en*` dengan IP privat → `bridge*` (Internet Sharing) → lainnya; `utun`/`ipsec`/`awdl`/`llw` diabaikan
- Dihitung ulang setiap menu dibuka (IP bisa berubah)

### Menu bar

- Ikon SF Symbol `arrow.left.arrow.right.circle` (template, ikut tema), redup saat berbagi mati
- Menu dibangun ulang di `menuNeedsUpdate` → IP, QR, riwayat selalu terbaru
- QR code (CoreImage `CIQRCodeGenerator`) ditampilkan langsung di menu + alamat di bawahnya
- "Salin link" → URL lengkap dengan token ke clipboard Mac

## Kriteria selesai

- [x] `./scripts/build.sh` menghasilkan `build/PasteLAN.app` (dicek di CI macOS)
- [x] Membuka `http://<ip>:8787/?t=<token>` dari HP menampilkan halaman
- [x] Tanpa token / token salah → 403
- [x] Mematikan "Berbagi aktif" → port ditutup, semua koneksi diputus
