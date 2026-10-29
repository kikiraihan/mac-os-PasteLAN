# CI/CD server — auto deploy ke VPS

Polanya sama dengan Racik (`kikiraihan/Racik`, `CICD.md`): push ke `main` → CI → SSH ke VPS → deploy dengan
health check & rollback otomatis. Bedanya, PasteLAN server hanya **satu binary Go + systemd**: binary dibuild di
GitHub Actions lalu dikirim ke VPS, jadi VPS **tidak butuh git, Go, maupun Docker**.

```
Anda: git push origin main   (atau merge PR yang mengubah server/)
        │
        ▼
GitHub Actions — Server CI (server-ci.yml)
        │  gofmt, go vet, go test -race, cek script deploy, build binary linux amd64 + arm64
        │  (kalau semuanya hijau)
        ▼
GitHub Actions — Deploy server ke VPS (deploy-server.yml)
        │  SSH ke VPS → cek arsitektur (uname -m) → kirim binary + deploy.sh ke /tmp → jalankan
        ▼
deploy.sh di VPS (sebagai root / sudo)
        ├─ tolak deploy kalau /etc/pastelan.env belum ada / masih password contoh
        ├─ tolak binary yang bukan ELF / beda arsitektur
        ├─ backup data → /var/backups/pastelan/predeploy-<waktu>.tar.gz (devices.json + settings.json)
        ├─ binary lama → /usr/local/bin/pastelan-server.prev, binary baru dipasang (atomik)
        ├─ systemctl restart pastelan
        ├─ health check: GET / = 200 dan GET /api/items (tanpa token) = 401
        └─ kalau gagal → ROLLBACK otomatis ke binary lama (+ 80 baris log di output Actions)
```

- Pull request hanya menjalankan CI (tanpa deploy). Kalau CI merah, deploy **tidak** jalan, VPS tidak tersentuh.
- Deploy hanya jalan kalau ada perubahan di `server/` (atau workflow-nya). Perubahan aplikasi Mac saja tidak
  me-restart server.
- Selama secret belum diisi, deploy **dilewati** dengan peringatan (bukan merah). Run workflow manual tetap gagal
  supaya ketahuan.
- Rilis GitHub (binary di Releases) tetap dibuat `build.yml` seperti biasa; deploy ini terpisah.

Prasyarat: server sudah dipasang sekali secara manual mengikuti [README.md](README.md) → *Pasang di VPS*
(binary di `/usr/local/bin/pastelan-server`, `/etc/pastelan.env` berisi password **acak**, service `pastelan`
aktif, HTTPS lewat Caddy / nginx). Untuk agen AI yang memasang server, baca juga [AGENTS.md](AGENTS.md).

> **Satu VM dengan Racik / our-life-planner?** Bisa. PasteLAN tidak memakai Docker; ia hanya mendengarkan
> `127.0.0.1:8080` (ganti `PASTELAN_ADDR` di unit kalau port itu dipakai app lain). Kalau nginx host sudah
> memegang port 80/443, **jangan** pasang Caddy; pakai blok nginx di bagian
> [nginx](#kalau-vps-sudah-memakai-nginx) di bawah. Deploy-nya tidak saling mengganggu: tidak ada build di VPS,
> restart hanya beberapa detik.

---

## Bagian A — Setup di sisi VPS

### A1. SSH key untuk GitHub Actions

Buat key baru khusus repo ini. **Di laptop Anda**:

```bash
ssh-keygen -t ed25519 -C "github-actions-pastelan" -f ~/.ssh/pastelan_deploy -N ""
ssh-copy-id -i ~/.ssh/pastelan_deploy.pub -p 22 root@IP-VPS
ssh -i ~/.ssh/pastelan_deploy root@IP-VPS "echo koneksi-ok"
```

> Boleh memakai ulang key Racik (`~/.ssh/racik_deploy`) kalau VM & user-nya sama. Key terpisah lebih rapi: bisa
> dicabut per repo tanpa mematikan deploy repo lain.

### A2. User SSH bisa menjalankan deploy sebagai root

Deploy mengganti binary di `/usr/local/bin` dan me-restart systemd, jadi butuh root.

- `SSH_USER=root` → tidak perlu apa-apa.
- User biasa → izinkan `sudo` tanpa password **hanya** untuk perintah deploy. Paling sederhana:
  ```bash
  echo 'deploy ALL=(root) NOPASSWD: /usr/bin/env' | sudo tee /etc/sudoers.d/pastelan-deploy
  sudo chmod 440 /etc/sudoers.d/pastelan-deploy && sudo visudo -c
  ```
  (ganti `deploy` dengan nama user; deploy dijalankan sebagai `sudo -n env … bash /tmp/pastelan-deploy.*/deploy.sh`.
  Catatan: aturan ini praktis setara akses root untuk user itu, jadi jaga kunci SSH-nya.)

### A3. Pastikan server sudah terpasang & sehat

```bash
systemctl status pastelan --no-pager        # active (running)
sudo grep -c PASSWORD /etc/pastelan.env      # ≥ 1, dan BUKAN password contoh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/   # 200
command -v curl file                         # curl wajib; file opsional (cek arsitektur)
```

### A4. Coba deploy manual dulu (dari laptop)

```bash
server/deploy/deploy-remote.sh root@IP-VPS
```

Butuh Go di laptop (build silang ke Linux). Yang seharusnya terlihat: `Backup data` → `Binary baru terpasang` →
`Health check OK` → `Log start: … PasteLAN server v1.x.y+abc1234 …` → `Deploy selesai.`

### A5. Ambil host key VPS

**Di laptop**:

```bash
ssh-keyscan -p 22 -H IP-VPS
```

Salin seluruh output-nya untuk secret `SSH_KNOWN_HOSTS` (sama dengan Racik kalau VM-nya sama).

---

## Bagian B — Setup di sisi GitHub

### B1. Tambahkan Secrets

**github.com/kikiraihan/mac-os-PasteLAN → Settings → Secrets and variables → Actions → New repository secret**

| Nama secret | Isi | Wajib? |
|---|---|---|
| `SSH_HOST` | IP VPS | ✅ |
| `SSH_USER` | user SSH di VPS, mis. `root` | ✅ |
| `SSH_PRIVATE_KEY` | **seluruh isi** `~/.ssh/pastelan_deploy` termasuk baris `-----BEGIN…`/`-----END…` | ✅ |
| `SSH_KNOWN_HOSTS` | output `ssh-keyscan` dari langkah A5 | Sangat disarankan |
| `SSH_PORT` | port SSH kalau bukan 22 | Opsional |

Secret GitHub berlaku per repo: yang sudah diisi di Racik tidak terbaca dari repo ini, jadi isi ulang di sini.
Salin private key ke clipboard (macOS): `pbcopy < ~/.ssh/pastelan_deploy`.

**Password PasteLAN tidak pernah masuk ke GitHub.** Password admin / perangkat hanya ada di `/etc/pastelan.env`
di VPS; workflow tidak membaca maupun mengirimnya.

### B2. Merge ke main

Workflow ada di `.github/workflows/server-ci.yml` dan `.github/workflows/deploy-server.yml`. Begitu masuk ke
`main`, push berikutnya yang mengubah `server/` otomatis deploy.

### B3. Lihat hasilnya

Tab **Actions** → **Deploy server ke VPS**: job `ci` jalan duluan, lalu `SSH deploy`. Log dari server tampil di
step "Jalankan deploy di VPS"; ringkasan versi & commit ada di halaman run.

---

## Pemakaian sehari-hari

| Tujuan | Perintah |
|---|---|
| Deploy otomatis | merge / push ke `main` yang mengubah `server/` (±2 menit) |
| Re-deploy tanpa commit baru | Actions → **Deploy server ke VPS** → **Run workflow** (bisa centang "Lewati backup") |
| Deploy dari laptop tanpa GitHub | `server/deploy/deploy-remote.sh root@IP-VPS` |
| Deploy binary dari Releases (di VPS) | `sudo bash deploy.sh ./pastelan-server-linux-amd64` (deploy.sh dari repo) |
| Rollback ke binary sebelumnya | `sudo bash /usr/local/lib/pastelan/rollback.sh` (di VPS; dua kali = kembali lagi) |
| Versi yang jalan | `journalctl -u pastelan -o cat \| grep 'PasteLAN server' \| tail -1`, atau halaman `/admin` |
| Status / log | `systemctl status pastelan` · `journalctl -u pastelan -f` |
| Cek CI di lokal sebelum push | `cd server && gofmt -l . && go vet ./... && go test -race ./...` |

Setelah rollback, `main` di GitHub masih berisi kode bermasalah: perbaiki atau `git revert`, supaya deploy
berikutnya tidak mengembalikan bug yang sama.

---

## Yang perlu diperhatikan

**Restart mengosongkan riwayat clipboard.** Isi clipboard hanya di memori server (sengaja, demi keamanan), jadi
setiap deploy menghapus riwayat. Token perangkat & pengaturan admin tetap (di `/var/lib/pastelan`); Mac & HP
tersambung lagi otomatis dalam beberapa detik.

**Data tidak ikut mundur saat rollback.** Rollback hanya menukar binary. Kalau versi baru sempat mengubah
`settings.json` / `devices.json` dengan format yang tidak dikenal versi lama, pulihkan backup pre-deploy:

```bash
ls -1t /var/backups/pastelan/predeploy-*.tar.gz | head -3
sudo systemctl stop pastelan
sudo tar xzf /var/backups/pastelan/predeploy-<waktu>.tar.gz -C "$(readlink -f /var/lib/pastelan)"
sudo systemctl start pastelan
```

Karena itu, perubahan format file data sebaiknya **additive** (field baru opsional) supaya versi lama tetap jalan.

**Unit systemd tidak ikut diperbarui.** Deploy hanya mengganti binary. Kalau `deploy/pastelan.service` berubah,
salin manual: `sudo cp server/deploy/pastelan.service /etc/systemd/system/ && sudo systemctl daemon-reload &&
sudo systemctl restart pastelan`.

**Env baru.** Kalau versi baru butuh variabel baru di `/etc/pastelan.env` (mis. `PASTELAN_ADMIN_PASSWORD` sejak
1.2.0), tambahkan dulu di VPS sebelum merge. Kalau lupa, server menolak start → health check gagal → rollback
otomatis, dan pesan errornya tampil di log Actions.

---

## Kalau VPS sudah memakai nginx

Misalnya satu VM dengan Racik (nginx host + Cloudflare). Jangan pasang Caddy (bentrok di port 80/443). Contoh
`/etc/nginx/sites-available/pastelan` (sertifikat dari Cloudflare Origin / certbot, sesuaikan dengan setup Racik):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name pastelan.domain-anda.com;
    # ssl_certificate / ssl_certificate_key: sama seperti situs lain di VM ini

    client_max_body_size 32m;          # gambar maks 30 MB
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;        # long-poll ditahan 25 detik
        proxy_buffering off;
    }
}
```

`sudo ln -s /etc/nginx/sites-available/pastelan /etc/nginx/sites-enabled/ && sudo nginx -t && sudo systemctl reload nginx`.
Di belakang Cloudflare, pakai mode SSL **Full (strict)** supaya koneksi Cloudflare → VPS tetap HTTPS.

---

## Troubleshooting

**`Permission denied (publickey)` di step SSH**: `SSH_PRIVATE_KEY` terpotong (harus lengkap dengan baris
BEGIN/END), atau public key belum ada di `~/.ssh/authorized_keys` milik `SSH_USER`.

**`Host key verification failed`**: `SSH_KNOWN_HOSTS` tidak cocok (VPS ganti IP / reinstall). Ulangi
`ssh-keyscan` dan perbarui secret.

**`sudo: a password is required`**: `SSH_USER` bukan root dan belum diizinkan sudo tanpa password (A2).

**`Service 'pastelan' belum terpasang`**: pasang server pertama kali secara manual (README → Pasang di VPS).

**`/etc/pastelan.env masih memakai password contoh`**: ganti password di `/etc/pastelan.env` dengan
`openssl rand -base64 24`, lalu jalankan ulang deploy.

**`Arsitektur binary tidak cocok`**: jarang terjadi (workflow memilih amd64/arm64 dari `uname -m`); pastikan VPS
x86_64 atau aarch64.

**`Health check GAGAL` lalu rollback**: log server dicetak di output Actions. Penyebab umum: variabel env baru
belum ditambahkan, port `PASTELAN_ADDR` dipakai app lain, atau password tidak memenuhi aturan (min. 12 karakter,
bukan contoh, admin ≠ perangkat). Kalau server mendengarkan alamat lain, set `HEALTH_URL`
(mis. `HEALTH_URL=http://127.0.0.1:9090`) saat menjalankan `deploy.sh` manual.

**`curl tidak terpasang`**: `sudo apt install -y curl`.
