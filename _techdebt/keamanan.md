# Keamanan — catatan

> Status: **tech debt**. Riwayat: audit v0.1.0 → perbaikan v0.1.1–v0.3.0 (mode Wi-Fi lokal: kunci di QR,
> enkripsi ChaCha20-Poly1305, pembatasan IP lokal). Sejak **v1.0.0** mode Wi-Fi lokal diganti server sendiri
> (lihat `_todo/opsi-c-server/`), jadi temuan khusus mode lokal (penyerang aktif di Wi-Fi yang sama, kunci di
> fragment URL, enkripsi JS) tidak berlaku lagi.

## Model ancaman v1.0.0

- **Penyadap jaringan**: tertutup oleh HTTPS (+ HSTS).
- **Orang lain menebak password**: batas percobaan per IP (/64 untuk IPv6) + batas global; password minimal 12 karakter.
- **Situs lain memanggil API (CSRF)**: header wajib `X-PasteLAN` + cookie `SameSite=Strict`, tanpa CORS.
- **XSS lewat isi clipboard**: isi selalu `textContent`; CSP tanpa `unsafe-inline`; gambar dicek dari isi (tanpa SVG).
- **Perangkat hilang**: cabut tokennya dari Pengaturan; token hanya tersimpan sebagai hash di server.
- **Server bocor (disk / backup)**: `devices.json` hanya berisi hash token; isi clipboard tidak pernah di disk.
- **Pemilik / pembobol server yang sedang berjalan**: bisa membaca isi clipboard di memori. Diterima (dipilih
  pemilik: tanpa E2E supaya tetap simpel).

## Ide lanjutan (belum perlu)

- Enkripsi ujung-ke-ujung (kunci dari password, WebCrypto ⇄ CryptoKit) kalau server dipakai bersama / tidak dipercaya.
- Ganti password otomatis mencabut semua token (sekarang: cabut manual dari Pengaturan).
- Kunci auto-update di GitHub Secrets bisa dipakai pembobol akun GitHub; tanda tangan manual lebih aman (README → Rilis).
