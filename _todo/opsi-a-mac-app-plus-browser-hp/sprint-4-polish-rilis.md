# Sprint 4 — Polish, keamanan & rilis `v0.1.0`

**Tujuan:** aplikasi siap dipakai sehari-hari dan dirilis otomatis lewat GitHub Actions.

## Lingkup

### Fitur pelengkap (sama seperti LiteScroller)

- **Buka saat login** (`SMAppService.mainApp`)
- **Cek pembaruan…**: cek GitHub Releases saat dibuka lalu sehari sekali; update dari menu (unduh zip, tukar .app, buka ulang)
- **Uninstall PasteLAN…**: hapus login item & pengaturan, pindahkan .app ke Tong Sampah
- **Cara pakai…** + muncul otomatis saat pertama kali dibuka

### Keamanan

- **Ganti token…**: buat token baru, semua HP yang terhubung langsung ditolak (harus scan QR baru)
- Batas koneksi/ukuran/timeout (lihat sprint 1)
- Riwayat tidak pernah ditulis ke disk
- Halaman tanpa resource eksternal + `Referrer-Policy: no-referrer` → token tidak bocor

### Dokumentasi

- README: fitur, cara pakai, izin firewall, catatan Wi-Fi publik (*client isolation*), privasi, build, instal

### Rilis

- Workflow `build.yml`: build universal, cek designated requirement, buat installer & zip, rilis otomatis kalau tag `v<versi>` belum ada
- Versi `0.1.0` (build `1`)

## Daftar uji manual (wajib di Mac + HP nyata)

| # | Langkah | Harapan |
|---|---|---|
| 1 | Jalankan PasteLAN pertama kali | Ikon ⇄ muncul, dialog "Cara pakai", (mungkin) dialog firewall → **Izinkan** |
| 2 | Klik ikon | QR code + `http://<ip>:8787` tampil |
| 3 | Scan QR dari iPhone (Safari) & Android (Chrome) | Halaman terbuka, status hijau "Terhubung ke <nama Mac>" |
| 4 | Ketik/tempel teks di HP → Kirim ke Mac → ⌘V di Mac | Teks sama persis, ikon menu bar ✓ sebentar |
| 5 | Kirim foto dari galeri iPhone & Android → ⌘V di Preview/Notes | Gambar tampil |
| 6 | ⌘C teks di Mac | Muncul di HP ≤ 2 dtk, tombol Salin berfungsi (tempel di aplikasi lain di HP) |
| 7 | ⌘⌃⇧4 (screenshot ke clipboard) | Gambar muncul di HP, tekan lama → simpan/salin berhasil |
| 8 | Copy file .jpg/.heic di Finder | Gambar muncul di HP |
| 9 | Copy password dari 1Password/Bitwarden/Keychain | **Tidak** muncul di HP |
| 10 | Kunci HP 1 menit, buka lagi, copy sesuatu di Mac | Item muncul (polling pulih) |
| 11 | Matikan "Berbagi aktif" | HP status merah; nyalakan lagi → pulih otomatis |
| 12 | Ganti token | HP menampilkan "link tidak berlaku"; scan QR baru → normal |
| 13 | Matikan "Kirim otomatis" → copy di Mac | Tidak terkirim; "Kirim clipboard sekarang" → terkirim |
| 14 | Riwayat → klik item dari HP | Masuk clipboard Mac lagi, tidak muncul duplikat di HP |
| 15 | Buka saat login, Cek pembaruan, Uninstall | Berfungsi seperti di LiteScroller |
| 16 | Activity Monitor saat diam | CPU ≈ 0%, memori kecil |

## Kriteria selesai

- [x] Semua fitur di atas ada di kode
- [x] `swiftc -parse` lolos
- [ ] CI macOS hijau
- [ ] Daftar uji manual lulus
- [ ] Merge ke `main` → tag & rilis `v0.1.0`
