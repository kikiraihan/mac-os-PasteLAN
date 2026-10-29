# Keamanan — catatan

> Status: **tech debt**. Riwayat: audit v0.1.0 → perbaikan v0.1.1–v0.3.0 (mode Wi-Fi lokal: kunci di QR,
> enkripsi ChaCha20-Poly1305, pembatasan IP lokal). v1.0.0: metode server sendiri (lihat `_todo/opsi-c-server/`).
> v1.1.0: mode Wi-Fi lokal kembali sebagai metode **opsional** (default tidak aktif), kodenya sama dengan v0.3.0.
> v1.2.0: halaman admin (`/admin`), link setup dari admin, password perangkat opsional.

## Model ancaman — metode server (default)

- **Penyadap jaringan**: tertutup oleh HTTPS (+ HSTS).
- **Orang lain menebak password / kode QR**: batas percobaan per IP (/64 untuk IPv6) + batas global; password minimal
  12 karakter; kode QR 256-bit, sekali pakai, 5 menit, maks 10 aktif.
- **Foto layar QR "Tambah HP"**: siapa pun yang memotret QR itu dalam 5 menit bisa masuk (sekali). Diterima; QR hanya
  dibuat saat diminta, dan perangkat asing bisa dicabut dari Pengaturan.
- **Password admin bocor / ditebak**: admin bisa membuat link setup (= akses masuk) dan mengubah pengaturan, tapi
  tidak bisa membaca isi clipboard lewat halaman admin. Password admin hanya di environment server (min. 12 karakter,
  bukan template `pastelan.env.example`, beda dari password perangkat), salah password dihitung bersama batas login.
  Sesi admin: token acak di cookie `pl_admin` (`Path=/api/admin`, `HttpOnly`, `Secure`, `SameSite=Strict`), 12 jam,
  hanya di memori.
- **Agen AI menyalin password contoh**: server menolak berjalan dengan password template; `server/AGENTS.md`
  melarang memakai password yang pernah tertulis di repo / chat.
- **`settings.json` bocor**: hanya berisi pengaturan + hash PBKDF2-SHA256 (600.000 iterasi, salt acak) password
  perangkat. Hitungan PBKDF2 dibatasi 2 bersamaan supaya tebakan beruntun tidak menghabiskan CPU.
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
- Ganti password otomatis mencabut semua token (sekarang: cabut manual dari Pengaturan / "Cabut semua" di admin).
- QR code link setup di halaman admin (perlu pembuat QR JS sendiri, tanpa CDN).
- Batas percobaan login (5× / 15 menit) bisa diatur dari admin.
- Kunci auto-update di GitHub Secrets bisa dipakai pembobol akun GitHub; tanda tangan manual lebih aman (README → Rilis).
