# Keamanan — sisa temuan audit

> Status: **tech debt**. Hasil audit keamanan (v0.1.0). Yang mudah sudah diperbaiki di v0.1.1:
> token dicek sebelum body dibaca, batas body per endpoint, hanya IP lokal, batas koneksi per perangkat,
> batas waktu header 10 detik, whitelist MIME gambar, batas 100 megapiksel, "Salin link" tidak ikut
> Universal Clipboard, dan pilihan kirim otomatis saat pertama kali dibuka.

## 1. Update tanpa verifikasi tanda tangan (prioritas tinggi)

Updater mengunduh `PasteLAN.zip` dari GitHub Release lalu langsung memasangnya. Satu-satunya jaminan adalah
HTTPS + akun GitHub. Kalau akun / repo dibobol (atau PR berbahaya ter-merge ke `main`, yang otomatis dirilis),
semua pengguna yang menekan "Update sekarang" menjalankan kode penyerang.

Rencana (fitur → naik minor):

1. `scripts/sign-release.swift` (CryptoKit, tanpa dependensi):
   - `keygen` → dijalankan **sekali oleh pemilik repo di Mac sendiri**; private key ke GitHub Secret
     `PASTELAN_SIGNING_KEY`, public key ditanam di `Updater`.
   - `sign <file>` → cetak tanda tangan Ed25519 (base64).
2. CI (hanya di step rilis): tanda tangani `dist/PasteLAN.zip` → `dist/PasteLAN.zip.sig`, unggah ke rilis.
3. `Updater.install`: unduh `.sig`, verifikasi `Curve25519.Signing.PublicKey.isValidSignature` **sebelum** `ditto`;
   setelah ekstrak cek `bundleIdentifier == "id.local.pastelan"`. Gagal → buka halaman rilis saja.
4. Opsional: tanda tangani `versi + sha256(zip)` supaya rilis lama yang sah tidak bisa disodorkan (downgrade).

## 2. HTTP tanpa enkripsi (prioritas sedang, paling besar pekerjaannya)

Siapa pun yang bisa menyadap Wi-Fi yang sama melihat isi clipboard dan token. Dengan token itu ia bisa membaca
semua copy berikutnya dan menulis ke clipboard Mac sampai link diganti.

Rencana (fitur → naik minor):

- QR berisi kunci di fragment: `http://ip:port/#k=<256-bit>` (fragment tidak pernah dikirim lewat jaringan).
- Semua isi API dienkripsi ChaCha20-Poly1305: Mac pakai `CryptoKit.ChaChaPoly`, HP pakai implementasi JS murni
  yang ditanam di `Page` (WebCrypto tidak tersedia di HTTP karena bukan secure context).
- Autentikasi = bisa mendekripsi; tambahkan timestamp / counter di plaintext untuk mencegah replay.
- Batasan: hanya melindungi dari penyadapan **pasif**. Penyerang aktif (ARP spoofing) masih bisa menyuntik JS saat
  halaman pertama dimuat. Perlindungan penuh butuh TLS ber-pin → lihat `konsep_opsi_b.md`.

Mitigasi kecil yang bisa dikerjakan lebih dulu:

- Token kedaluwarsa otomatis (opsi "Ganti link tiap N hari / tiap aplikasi dibuka").
- Daftar IP perangkat yang terhubung di menu + notifikasi saat clipboard Mac ditulis dari HP.

## 3. Lain-lain (prioritas rendah)

- Token ada di query string (`?t=`) → tersimpan di riwayat browser HP (bisa tersinkron ke iCloud / Chrome Sync).
  Gambar bisa diambil lewat `fetch` + header `X-Token` lalu ditampilkan sebagai `blob:` URL.
