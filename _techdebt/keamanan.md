# Keamanan — catatan

> Status: **tech debt**. Riwayat: audit v0.1.0 → perbaikan v0.1.1–v0.3.0 (mode Wi-Fi lokal: kunci di QR,
> enkripsi ChaCha20-Poly1305, pembatasan IP lokal). v1.0.0: metode server sendiri (lihat `_todo/opsi-c-server/`).
> v1.1.0: mode Wi-Fi lokal kembali sebagai metode **opsional** (default tidak aktif), kodenya sama dengan v0.3.0.

## Model ancaman — metode server (default)

- **Penyadap jaringan**: tertutup oleh HTTPS (+ HSTS).
- **Orang lain menebak password**: batas percobaan per IP (/64 untuk IPv6) + batas global; password minimal 12 karakter.
- **Situs lain memanggil API (CSRF)**: header wajib `X-PasteLAN` + cookie `SameSite=Strict`, tanpa CORS.
- **XSS lewat isi clipboard**: isi selalu `textContent`; CSP tanpa `unsafe-inline`; gambar dicek dari isi (tanpa SVG).
- **Perangkat hilang**: cabut tokennya dari Pengaturan; token hanya tersimpan sebagai hash di server.
- **Server bocor (disk / backup)**: `devices.json` hanya berisi hash token; isi clipboard tidak pernah di disk.
- **Pemilik / pembobol server yang sedang berjalan**: bisa membaca isi clipboard di memori. Diterima (dipilih
  pemilik: tanpa E2E supaya tetap simpel).

## Model ancaman — metode Wi-Fi lokal (opsional)

- **Penyadap pasif di Wi-Fi yang sama**: tidak bisa membaca / memalsukan / mengulang (ChaCha20-Poly1305, kunci di
  `#k=`, `X-Auth` sekali pakai).
- **Perangkat lain tanpa kunci**: ditolak sebelum body dibaca; hanya IP lokal; batas koneksi per perangkat.
- **Penyerang aktif di Wi-Fi yang sama** (ARP spoofing / Wi-Fi palsu): bisa mengganti JS halaman HTTP dan mencuri
  kunci. Diterima untuk mode opsional ini; README menyarankan metode server / hotspot sendiri di Wi-Fi tak dipercaya.
- Kunci ada di fragment URL → tidak dikirim ke jaringan, tapi tersimpan di riwayat / bookmark browser HP.
- Port lokal hanya terbuka saat metode Wi-Fi lokal dipilih dan "Berbagi aktif".

## Ide lanjutan (belum perlu)

- Enkripsi ujung-ke-ujung (kunci dari password, WebCrypto ⇄ CryptoKit) kalau server dipakai bersama / tidak dipercaya.
- Ganti password otomatis mencabut semua token (sekarang: cabut manual dari Pengaturan).
- Kunci auto-update di GitHub Secrets bisa dipakai pembobol akun GitHub; tanda tangan manual lebih aman (README → Rilis).
