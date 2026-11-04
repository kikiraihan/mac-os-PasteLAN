# Video teaser

`pastelan-teaser.mp4` — teaser 29 detik, 1920×1080, 30 fps, tanpa suara.

| Detik | Adegan |
|---|---|
| 0–3,5 | Ikon + "PasteLAN — Copy di Mac. Paste di HP. Dan sebaliknya." |
| 3,5–10,5 | Mac → HP: teks diseleksi, ⌘C, muncul di HP, Salin |
| 10,5–17,5 | HP → Mac: tempel di HP, Kirim, masuk ke riwayat menu Mac, ⌘V |
| 17,5–21,5 | PWA di HP terang & gelap (screenshot `hp-light.png`, `hp-dark.png`) |
| 21,5–25,5 | Fitur: server sendiri, Wi-Fi lokal, clipboard manager, notifikasi, hanya di RAM, update bertanda tangan |
| 25,5–29 | Penutup |

## Render ulang

Sumber animasi ada di `src/teaser.html` (memakai screenshot dari `docs/screenshots/`). Buka langsung
di browser untuk pratinjau. Untuk membuat MP4 (butuh Node + Playwright/Chromium + ffmpeg):

```bash
node video/src/render.js
```
