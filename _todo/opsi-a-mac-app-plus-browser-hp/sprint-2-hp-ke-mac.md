# Sprint 2 — Halaman web & alur HP → Mac

**Tujuan:** dari HP, pengguna bisa mengirim teks dan gambar yang langsung masuk ke clipboard Mac.

## User story

- Sebagai pengguna HP, saya menempel teks di kotak, tekan **Kirim ke Mac**, lalu di Mac cukup ⌘V.
- Saya bisa memilih satu atau beberapa gambar dari galeri, lalu gambar itu siap ⌘V di Mac.
- Saya bisa menempel gambar langsung di kotak teks (kalau keyboard/browser mendukung).
- Saya tahu pengiriman berhasil (toast di HP, ikon ✓ sebentar di menu bar Mac).

## Halaman web

- HTML/CSS/JS **ditanam di binary** (string Swift), tanpa file eksternal, tanpa CDN (bisa jalan tanpa internet)
- Responsif, mode gelap otomatis (`prefers-color-scheme`), `safe-area-inset` untuk notch
- Elemen:
  - Header: titik status (hijau terhubung / merah terputus) + nama Mac
  - Kartu kirim: `textarea`, tombol **Kirim ke Mac**, tombol **Kirim gambar** (`<input type=file accept=image/* multiple>`)
  - ⌘/Ctrl + Enter = kirim
  - Daftar clipboard (sprint 3)
- Token dibaca dari `?t=` di URL (URL bisa di-bookmark / "Tambahkan ke Layar Utama")

## API

| Endpoint | Body | Hasil |
|---|---|---|
| `POST /api/text` | `text/plain; charset=utf-8` (maks 30 MB, kosong ditolak) | `{"ok":true,"id":N}` |
| `POST /api/image` | byte gambar mentah, `Content-Type: image/*` | `{"ok":true,"id":N}`; 415 kalau bukan gambar |

## Menulis ke clipboard Mac

- Teks: `clearContents()` + `setString(.string)`
- Gambar: `NSImage(data:)` (validasi) → `writeObjects([image])` (TIFF, dibaca semua aplikasi) + format asli (`public.png` / `public.jpeg`) supaya kualitas tidak turun
- Setelah menulis, `changeCount` dicatat supaya pemantau clipboard (sprint 3) tidak mengirimnya balik ke HP
- Opsi menu: **Simpan juga gambar dari HP ke folder Unduhan** (`PasteLAN-yyyyMMdd-HHmmss.ext`, default mati)

## Kriteria selesai

- [x] Teks dari HP bisa di-⌘V di Mac (termasuk emoji & teks multi-baris)
- [x] Foto iPhone (JPEG/HEIC) & screenshot Android (PNG) bisa di-⌘V di Mac (Preview, Notes, Slack, dll.)
- [x] File bukan gambar ditolak dengan pesan yang jelas
- [x] Token salah → halaman "link tidak berlaku, scan ulang QR"
