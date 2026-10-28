# Keamanan — sisa temuan audit

> Status: **tech debt**. Hasil audit keamanan (v0.1.0).
>
> - **v0.1.1**: kunci dicek sebelum body dibaca, batas body per endpoint, hanya IP lokal, batas koneksi per
>   perangkat, batas waktu header 10 detik, whitelist MIME gambar, batas 100 megapiksel, "Salin link" tidak ikut
>   Universal Clipboard, pilihan kirim otomatis saat pertama kali dibuka.
> - **v0.2.0**: enkripsi ujung-ke-ujung ChaCha20-Poly1305 (kunci di `#k=`, header `X-Auth` sekali pakai, anti
>   replay, toleransi jam ±5 menit lewat 409), dan auto-update wajib tanda tangan Ed25519.

## 1. ~~Kunci publik update belum diisi~~ (selesai di v0.2.1)

`Updater.publicKey` sudah diisi. Pengguna v0.2.0 (kunci masih kosong) diarahkan ke halaman rilis sekali untuk
update manual ke v0.2.1; setelah itu update otomatis berjalan dengan verifikasi tanda tangan.
Rilis tanpa `PasteLAN.zip.sig` yang valid tetap hanya membuka halaman rilis.

## 2. Penyerang aktif di Wi-Fi yang sama (prioritas rendah–sedang)

Halaman HP tetap dimuat lewat HTTP. Penyerang **aktif** (ARP spoofing / Wi-Fi palsu) bisa mengganti JS halaman
dan membaca kunci dari `#k=`. Penyadap pasif sudah tidak bisa apa-apa.

Pilihan perbaikan:

- TLS dengan sertifikat yang di-pin saat pairing → butuh aplikasi native di HP (lihat `konsep_opsi_b.md`).
- Mitigasi kecil: daftar IP perangkat yang terhubung di menu + notifikasi saat clipboard Mac ditulis dari HP,
  supaya perangkat asing cepat ketahuan.

## 3. Lain-lain (prioritas rendah)

- Kunci ada di fragment URL → tidak dikirim ke jaringan, tapi tetap tersimpan di riwayat / bookmark browser HP
  (bisa tersinkron ke iCloud / Chrome Sync) dan di `localStorage` halaman.
- Kunci tidak kedaluwarsa otomatis. Opsi "Ganti link tiap N hari / tiap aplikasi dibuka" bisa ditambahkan.
- Enkripsi gambar besar di HP memakai JS murni (±0,7 detik per 10 MB di desktop, beberapa detik di HP untuk 30 MB)
  dan berjalan di thread utama. Bisa dipindah ke Web Worker kalau terasa macet.
