# PasteLAN server

Server kecil yang meneruskan isi clipboard antara Mac dan HP. Satu binary Go (standard library saja),
halaman web / PWA ikut di dalamnya. Butuh ±20–40 MB RAM.

## Konfigurasi (environment)

| Variabel | Wajib | Default | Keterangan |
|---|---|---|---|
| `PASTELAN_ADMIN_PASSWORD` | ✅¹ | – | Password halaman admin (`/admin`), **minimal 12 karakter**, acak: `openssl rand -base64 24`. Kosong → admin nonaktif |
| `PASTELAN_PASSWORD` | ✅¹ | – | Opsional: password bersama untuk login perangkat (min. 12, beda dari password admin). Bisa juga dibuat / dimatikan di admin |
| `PASTELAN_ADDR` | | `127.0.0.1:8080` | Alamat dengar. Biarkan lokal; HTTPS lewat reverse proxy |
| `PASTELAN_DATA` | | `data` | Folder `devices.json` (daftar perangkat + **hash** token) dan `settings.json` (pengaturan admin); bukan isi clipboard |
| `PASTELAN_TLS_CERT` / `PASTELAN_TLS_KEY` | | – | Opsional: HTTPS langsung tanpa reverse proxy |

¹ Minimal salah satu wajib diisi; disarankan `PASTELAN_ADMIN_PASSWORD`. Contoh lengkap:
[`deploy/pastelan.env.example`](deploy/pastelan.env.example). Password contoh di file itu **ditolak** server, jadi
harus diganti (lihat juga [`AGENTS.md`](AGENTS.md) untuk agen AI yang memasang server).

Ganti password admin = ubah `PASTELAN_ADMIN_PASSWORD` lalu restart. Password perangkat diganti dari halaman admin
(yang dari admin menang atas `PASTELAN_PASSWORD`). Perangkat yang sudah login tetap jalan (tokennya tidak bergantung
pada password); cabut lewat halaman admin / Pengaturan kalau perlu.

## Halaman admin

Buka `https://domain-anda/admin`, masuk dengan `PASTELAN_ADMIN_PASSWORD`:

- **Buat link setup**: link sekali pakai (`https://domain/#pair=…`, default 10 menit) untuk perangkat baru. Mac: menu
  PasteLAN → *Atur server & login…* → tempel link. HP: buka link di browser.
- **Riwayat clipboard**: hapus otomatis (ya / tidak) dan lama penyimpanan, jumlah item maksimal, total memori
  maksimal, masa berlaku link setup, hapus semua riwayat.
- **Login dengan password**: aktif / mati, buat / ganti password perangkat (disimpan sebagai hash PBKDF2).
- **Perangkat**: daftar, cabut satu, cabut semua.

## Pasang di VPS (systemd + Caddy)

```bash
# 1. binary (dari Releases, atau build sendiri: cd server && CGO_ENABLED=0 go build -o pastelan-server .)
sudo install -m 755 pastelan-server-linux-amd64 /usr/local/bin/pastelan-server

# 2. password admin acak (hanya bisa dibaca root); contoh lengkap: deploy/pastelan.env.example
echo "PASTELAN_ADMIN_PASSWORD=$(openssl rand -base64 24)" | sudo tee /etc/pastelan.env
sudo chmod 600 /etc/pastelan.env

# 3. service (user sementara tanpa hak, hanya boleh menulis /var/lib/pastelan)
sudo cp deploy/pastelan.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pastelan

# 4. HTTPS otomatis: pasang Caddy (https://caddyserver.com/docs/install), lalu
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile   # ganti pastelan.example.com dengan domain Anda
sudo systemctl reload caddy
```

DNS domain/subdomain harus mengarah ke VPS, dan port 80 + 443 terbuka (untuk Let's Encrypt).
Memakai Nginx? Teruskan ke `127.0.0.1:8080` dengan `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`,
`proxy_set_header X-Forwarded-Proto $scheme;`, `client_max_body_size 32m;` dan `proxy_read_timeout 60s;`.

## Memperbarui server

**Otomatis (disarankan)**: CI/CD men-deploy server setiap ada perubahan `server/` di `main` (backup data, health
check, rollback otomatis). Setup sekali: [CICD.md](CICD.md). Dari laptop: `deploy/deploy-remote.sh root@IP-VPS`.

**Manual**: binary server **tidak** ikut auto-update aplikasi Mac. Setelah rilis baru, perbarui juga di VPS (fitur
baru seperti "Tambah HP (scan QR)" butuh server versi yang sama; server lama menjawab 405 / 404):

```bash
# unduh pastelan-server-linux-amd64 (atau -arm64) dari Releases versi terbaru, lalu
sudo install -m 755 pastelan-server-linux-amd64 /usr/local/bin/pastelan-server
sudo systemctl restart pastelan
```

Perangkat yang sudah login tetap login (token disimpan di `/var/lib/pastelan`); riwayat clipboard (hanya di memori)
hilang saat restart.

**Dari versi ≤ 1.1.x ke 1.2.0 (migrasi admin)**: tambahkan password admin sekali, lalu restart. `PASTELAN_PASSWORD`
lama tetap berlaku sebagai password perangkat (bisa dimatikan / diganti dari admin).

```bash
echo "PASTELAN_ADMIN_PASSWORD=$(openssl rand -base64 24)" | sudo tee -a /etc/pastelan.env
sudo systemctl restart pastelan && sudo grep ADMIN /etc/pastelan.env   # catat password admin ini
```

## API (ringkas)

Semua request `/api/` wajib header `X-PasteLAN: 1`. Login: cookie `pl_token` (browser) atau
`Authorization: Bearer <token>` (aplikasi Mac).

| Method & path | Keterangan |
|---|---|
| `POST /api/login` `{"password","name"}` | → `{"token","device"}` + cookie |
| `POST /api/logout` | Cabut token perangkat ini |
| `GET /api/config` | `{"passwordLogin"}`: apakah login dengan password tersedia |
| `POST /api/pair` | (sudah login) → `{"code","expires"}`: kode QR sekali pakai, 5 menit |
| `POST /api/pair/claim` `{"code","name"}` | Tukar kode QR / link setup → `{"token","device"}` + cookie (seperti login) |
| `GET /api/items?after=&s=&r=&wait=1` | Item baru (long-poll maks 25 detik) + `ids` (item yang masih ada), `rev`, `max` |
| `POST /api/text` | Body: teks UTF-8 (maks 2 MB) |
| `POST /api/image` | Body: file gambar (maks 30 MB; jenis dicek dari isi) |
| `GET /api/image/{id}` | Isi gambar |
| `DELETE /api/items` | Hapus riwayat (semua perangkat) |
| `DELETE /api/items/{id}` | Hapus satu item (semua perangkat) |
| `GET /api/devices` · `DELETE /api/devices/{id}` | Daftar / cabut perangkat |
| `POST /api/admin/login` `{"password"}` · `POST /api/admin/logout` | Sesi admin (cookie `pl_admin`) |
| `GET /api/admin/status` · `PUT /api/admin/settings` | Pengaturan, perangkat, pemakaian memori |
| `POST /api/admin/password` · `POST /api/admin/setup-link` | Password perangkat · link setup sekali pakai |
| `DELETE /api/admin/devices[/{id}]` · `DELETE /api/admin/items` | Cabut perangkat / semua · hapus riwayat |

## Tes

```bash
go vet ./... && go test -race ./...
```
