# AGENTS.md

Panduan untuk agen AI (Claude, dll.) yang bekerja di repo ini.

## Versioning

Format versi: **`va.b.c`** (tanpa `v` di `Info.plist`, mis. `0.1.0`; tag rilis jadi `v0.1.0`).

| Bagian | Naik ketika | Contoh |
|---|---|---|
| **a** (major) | perubahan besar (sangat jarang) atau ada *breaking change* | `0.7.3` → `1.0.0` |
| **b** (minor) | ada fitur baru, atau perubahan style mayor | `0.7.3` → `0.8.0` |
| **c** (patch) | perbaikan bug, atau perubahan style minor | `0.7.3` → `0.7.4` |

Aturan:

- Saat `a` naik, `b` dan `c` di-reset ke 0. Saat `b` naik, `c` di-reset ke 0.
- **Setiap PR yang mengubah aplikasi wajib menaikkan versi** di `Resources/Info.plist`:
  - `CFBundleShortVersionString` → versi baru sesuai tabel di atas.
  - `CFBundleVersion` → naik 1 (nomor build, selalu bertambah).
- Kalau satu PR berisi beberapa jenis perubahan, ambil kenaikan yang **tertinggi**
  (mis. fitur baru + bug fix → naikkan `b`).
- PR yang hanya mengubah dokumentasi, README, CI, atau berkas agen (tanpa mengubah aplikasi)
  **tidak** menaikkan versi.
- Hitung versi baru dari versi di branch `main` terbaru, bukan dari branch lama.
- Versi lama dua bagian (mis. `0.6`) dianggap `0.6.0`.
- Sebutkan versi lama → baru di deskripsi PR (mis. `Versi: 0.6.0 → 0.7.0 (fitur baru)`).

Merge ke `main` dengan versi yang belum punya tag akan otomatis membuat tag `v<versi>` dan rilis
(lihat `.github/workflows/build.yml`).

## Struktur & catatan proyek

- Satu file sumber: `Sources/PasteLAN/main.swift` (Swift + AppKit + Network.framework, tanpa dependensi).
  Halaman web untuk HP ditanam di file yang sama (`enum Page`), tanpa resource eksternal / CDN.
- Rencana kerja ada di `_todo/` (satu folder per inisiatif: file sprint + `00-tracker.md`).
  Perbarui tracker setiap kali tugas selesai.
- Ide yang ditunda / utang teknis ada di `_techdebt/`.
- Keamanan: semua isi `/api/` dienkripsi ChaCha20-Poly1305 (Swift `CryptoKit` ⇄ JS `AEAD` di `enum Page`, format
  `nonce + ciphertext + tag`, AAD `PL1|req|…`, `PL1|body|…`, `PL1|resp|…`). Ubah format di kedua sisi sekaligus.
  Auto-update wajib tanda tangan Ed25519 (`scripts/sign-release.swift`). Jangan pernah meminta / menyimpan kunci privat.
  Sisa temuan audit di `_techdebt/keamanan.md`.
- Tidak ada Mac di lingkungan agen cloud: cek sintaks dengan `swiftc -parse Sources/PasteLAN/main.swift`
  (toolchain Swift Linux), build sebenarnya dicek oleh GitHub Actions (macOS).
