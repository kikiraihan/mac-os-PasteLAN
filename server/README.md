# PasteLAN server

Server kecil yang meneruskan isi clipboard antara Mac dan HP. Satu binary Go (standard library saja),
halaman web / PWA ikut di dalamnya. Butuh ±20–40 MB RAM.

## Konfigurasi (environment)

| Variabel | Wajib | Default | Keterangan |
|---|---|---|---|
| `PASTELAN_PASSWORD` | ✅ | – | Password login, **minimal 12 karakter**. Pakai yang acak: `openssl rand -base64 24` |
| `PASTELAN_ADDR` | | `127.0.0.1:8080` | Alamat dengar. Biarkan lokal; HTTPS lewat reverse proxy |
| `PASTELAN_DATA` | | `data` | Folder `devices.json` (daftar perangkat + **hash** token; bukan isi clipboard) |
| `PASTELAN_TLS_CERT` / `PASTELAN_TLS_KEY` | | – | Opsional: HTTPS langsung tanpa reverse proxy |

Ganti password = ubah `PASTELAN_PASSWORD` lalu restart. Perangkat yang sudah login tetap jalan (tokennya tidak
bergantung pada password); cabut lewat Pengaturan di halaman PasteLAN kalau perlu.

## Pasang di VPS (systemd + Caddy)

```bash
# 1. binary (dari Releases, atau build sendiri: cd server && CGO_ENABLED=0 go build -o pastelan-server .)
sudo install -m 755 pastelan-server-linux-amd64 /usr/local/bin/pastelan-server

# 2. password (hanya bisa dibaca root)
echo "PASTELAN_PASSWORD=$(openssl rand -base64 24)" | sudo tee /etc/pastelan.env
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

## API (ringkas)

Semua request `/api/` wajib header `X-PasteLAN: 1`. Login: cookie `pl_token` (browser) atau
`Authorization: Bearer <token>` (aplikasi Mac).

| Method & path | Keterangan |
|---|---|
| `POST /api/login` `{"password","name"}` | → `{"token","device"}` + cookie |
| `POST /api/logout` | Cabut token perangkat ini |
| `GET /api/items?after=&s=&wait=1` | Item baru (long-poll maks 25 detik) |
| `POST /api/text` | Body: teks UTF-8 (maks 2 MB) |
| `POST /api/image` | Body: file gambar (maks 30 MB; jenis dicek dari isi) |
| `GET /api/image/{id}` | Isi gambar |
| `DELETE /api/items` | Hapus riwayat (semua perangkat) |
| `GET /api/devices` · `DELETE /api/devices/{id}` | Daftar / cabut perangkat |

## Tes

```bash
go vet ./... && go test -race ./...
```
