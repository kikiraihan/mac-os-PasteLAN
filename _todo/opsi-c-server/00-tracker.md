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
- [x] v1.2.0: "Tambah HP (scan QR)" ke server lama → pesan jelas "perbarui server" (bukan HTTP 405);
      `/api/` tak dikenal → 404 JSON; README server: bagian "Memperbarui server"
- [x] v1.2.0: halaman admin `/admin` (`PASTELAN_ADMIN_PASSWORD`): link setup (Mac tempel link, tanpa password),
      perangkat (cabut / cabut semua), password perangkat opsional (aktif / mati, hash PBKDF2), hapus otomatis &
      lama simpan, batas item / memori, masa berlaku link; `deploy/pastelan.env.example` + `server/AGENTS.md`
- [x] v1.2.0: web: hapus per item & "Hapus semua" (tersinkron ke semua perangkat lewat `ids` / `rev`)
- [x] v1.3.0: ganti password admin dari halaman admin (hash PBKDF2 di `settings.json`, menggantikan env, sesi lain
      keluar); halaman admin baru (pola Racik: sidebar / tab bar bawah di HP, tema terang-gelap, 4 bagian);
      menu Mac gaya Clipy (riwayat langsung di menu, ⌘0–⌘9, pengaturan di submenu)
- [x] v1.7.0: riwayat Mac tetap ada setelah restart (`HistoryStore`, seperti CopyClip), bisa dimatikan di
      Pengaturan → Umum; gambar sebagai file, id item server tidak disimpan
- [x] v1.8.0: "Sinkron" → **Autosync** (opsi "Kirim setiap copy otomatis" digabung); notifikasi PWA (Web Push,
      `server/push.go`) untuk kiriman manual ⇧ + klik dari Mac, potongan teks + tombol **Salin**; tombol Install PWA
- [x] v1.9.0: **Dengarkan kiriman dari server** (saat autosync mati, mode server): Mac tetap long-poll tanpa mengirim
      copy; kiriman HP / browser masuk riwayat (clipboard tidak ditimpa), titik di kanan atas ikon menu bar + titik
      biru di baris clip sampai menu ditutup. Pengaturan → Umum / menu, default nyala
- [x] v1.15.0: **aplikasi Android** (`android/`, Kotlin + Compose): notifikasi kiriman baru dengan tombol **Salin**
      (teks & gambar langsung ke clipboard tanpa membuka aplikasi), koneksi latar tanpa FCM, mode semua / hanya ⌃-klik,
      salin otomatis, riwayat (ketuk = salin, tekan lama = salin / bagikan / hapus), kirim teks & gambar, Bagikan →
      PasteLAN, masuk dengan scan QR / link setup / password, periksa pembaruan. Server: item punya `notify`.
      Tes: `ParseTest`, `UiTest` (Robolectric + screenshot), `scripts/test-android.sh`; CI job `android` di `build.yml`
- [x] v1.15.0: **unduh aplikasi Android dari web** (pola AI Todo): `GET /api/app/android` + `/unduh/PasteLAN.apk`
      (302 ke rilis GitHub, tanpa login, cache 15 menit, `PASTELAN_RELEASE_REPO`); PWA: spanduk di browser Android (bisa
      ditutup), Pengaturan → Aplikasi Android, ajakan di form masuk; admin: kartu Aplikasi Android (unduh + salin
      tautan); dialog Tambah HP di Mac menyebut aplikasi Android. CI job android pakai SDK bawaan runner. Tes: `release_test.go`
- [ ] Pemilik: buat kunci tanda tangan Android + secret `ANDROID_KEYSTORE_*` (`android/README.md`) supaya rilis berisi
      `PasteLAN.apk`
- [ ] Uji aplikasi Android di HP nyata: scan QR, notifikasi → Salin (teks & gambar), salin otomatis, aplikasi ditutup,
      HP restart, Bagikan → PasteLAN
- [ ] Uji "Dengarkan kiriman dari server" di Mac nyata (tampilan titik di menu bar terang / gelap)
- [ ] Uji notifikasi di HP nyata: Android (tombol Salin) & iPhone ter-install (ketuk → Salin)
- [ ] Uji di Mac & HP nyata: login, install PWA, kirim dua arah, cabut perangkat
- [ ] Uji metode Wi-Fi lokal di Mac nyata & ganti-ganti metode
- [x] CI/CD server (pola Racik): `server-ci.yml` + `deploy-server.yml` → SSH, `deploy/deploy.sh` (backup data,
      health check, rollback otomatis), `deploy/rollback.sh`, `deploy/deploy-remote.sh`; panduan `server/CICD.md`
- [ ] Pasang server di VPS pemilik + isi secret deploy (SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS)
