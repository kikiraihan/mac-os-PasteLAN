# Tracker — Opsi C: server sendiri + PWA (v1.0.0)

Menggantikan opsi A (server di Mac, HP lewat Wi-Fi lokal). Alasan: di lapangan HP sering tidak bisa menjangkau
Mac (data seluler, Wi-Fi kantor/kampus dengan *client isolation*), dan halaman HTTP lokal tidak bisa di-install
sebagai aplikasi. Opsi A tetap terdokumentasi di `../opsi-a-mac-app-plus-browser-hp/` (sejarah).

## Keputusan desain

| Topik | Keputusan | Alasan |
|---|---|---|
| Server | Go, standard library saja, satu binary, web di-`embed` | Ringan, mudah dipasang di VPS |
| HTTPS | Reverse proxy (Caddy, Let's Encrypt); server dengar `127.0.0.1` | PWA & clipboard API butuh HTTPS |
| Frontend | HTML/CSS/JS biasa, tanpa framework / CDN | Cukup untuk satu halaman; CSP ketat tanpa build |
| Login | Satu password → token per perangkat (hash di disk), bisa dicabut | Sederhana, perangkat hilang mudah diputus |
| Isi clipboard | Hanya di memori server: 20 item / 150 MB / 24 jam | Tidak ada isi yang tersimpan di disk |
| Enkripsi | HTTPS saja (tanpa E2E) | Dipilih pemilik: simpel; pemilik server dipercaya |
| Mode LAN | v1.0.0: dihapus. **v1.1.0: kembali sebagai metode opsional** (default server) | Permintaan pemilik: tetap bisa dipakai tanpa server |

## Tugas

- [x] Server Go: login + token per perangkat, batas percobaan login, long-poll, teks & gambar, header keamanan
- [x] PWA: login, kirim/terima, salin teks & gambar, pengaturan (cabut perangkat, hapus riwayat, keluar),
      manifest + service worker (API tidak pernah di-cache), ikon
- [x] Aplikasi Mac jadi klien server: token di Keychain, mode LAN & enkripsi JS dihapus
- [x] Tes: `go test -race`, E2E Chromium (server asli), klien Swift ⇄ server (Linux)
- [x] CI: tes Go + binary server Linux (amd64/arm64) ikut rilis; deploy systemd + Caddy
- [x] v1.1.0: metode Wi-Fi lokal opsional (menu → Metode), kode v0.3.0 dipulihkan sebagai `LANServer`
- [x] v1.1.0: "Tambah HP (scan QR)…" di Mac → HP masuk tanpa password (kode sekali pakai, 5 menit)
- [x] v1.1.1: "Tambah HP (scan QR)" ke server lama → pesan jelas "perbarui server" (bukan HTTP 405);
      `/api/` tak dikenal → 404 JSON; README server: bagian "Memperbarui server"
- [ ] Uji di Mac & HP nyata: login, install PWA, kirim dua arah, cabut perangkat
- [ ] Uji metode Wi-Fi lokal di Mac nyata & ganti-ganti metode
- [ ] Pasang server di VPS pemilik
