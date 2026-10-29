# AGENTS.md — server PasteLAN

Panduan untuk agen AI (Claude, dll.) yang **memasang / memperbarui server PasteLAN di VPS** atau mengubah kode di
folder `server/`. Aturan umum repo ada di [`../AGENTS.md`](../AGENTS.md).

## Password: jangan salin contoh apa adanya

`deploy/pastelan.env.example` berisi **password contoh (template)** `GANTI-dengan-password-acak`. File itu ada di repo
publik, jadi siapa pun tahu nilainya.

- **Jangan pernah** menyalin `pastelan.env.example` ke `/etc/pastelan.env` tanpa mengganti passwordnya, dan jangan
  memakai password lain yang pernah tertulis di repo, issue, PR, chat, atau log (termasuk contoh dari pemilik).
- Buat password **acak baru** langsung di server, mis.:
  ```bash
  echo "PASTELAN_ADMIN_PASSWORD=$(openssl rand -base64 24)" | sudo tee /etc/pastelan.env
  sudo chmod 600 /etc/pastelan.env
  ```
  Server menolak berjalan kalau password masih template, kurang dari 12 karakter, atau password admin sama dengan
  `PASTELAN_PASSWORD`.
- Kalau pemilik memberi password sendiri, pakai itu hanya di `/etc/pastelan.env` di server. Jangan menulisnya ke
  repo, commit, file lain, atau log, dan jangan menampilkannya lagi selain sekali ke pemilik bila diminta.
- Beri tahu pemilik **di mana** password admin tersimpan (`sudo grep ADMIN /etc/pastelan.env`) supaya ia bisa
  mencatatnya / menggantinya. Jangan meminta / menyimpan kunci privat apa pun.
- `/etc/pastelan.env` harus `chmod 600` milik root. `PASTELAN_PASSWORD` (password perangkat) opsional; lebih baik
  dibuat dari halaman admin.

## Langkah pasang / perbarui

Ikuti `README.md` (bagian *Pasang di VPS* dan *Memperbarui server*). Setelah selesai:

1. `systemctl status pastelan` aktif, log berisi `PasteLAN server <versi> di 127.0.0.1:8080`.
2. `https://domain/admin` bisa dibuka (HTTPS lewat Caddy).
3. Minta pemilik masuk ke admin → **Buat link setup** → tempel di Mac. Agen tidak perlu (dan sebaiknya tidak)
   membuat link setup sendiri, karena link itu sama dengan akses masuk.

## Mengubah kode server

- Go standard library saja; halaman web di `web/` tanpa framework / CDN, tanpa script / style inline (CSP).
- Cek sebelum commit: `gofmt -l . && go vet ./... && go test -race ./...`.
- Kalau `templatePassword` di `settings.go` diubah, ubah juga `deploy/pastelan.env.example` (ada tes yang mencocokkan).
