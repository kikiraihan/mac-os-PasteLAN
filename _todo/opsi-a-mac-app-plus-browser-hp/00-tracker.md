# Tracker — Opsi A: Mac app + HP lewat browser

PRD PasteLAN versi pertama. Detail tiap sprint ada di file `sprint-*.md` di folder ini.
File ini menjadi satu-satunya tempat status: centang `[x]` begitu tugas selesai.

## Ringkasan produk

**Masalah:** memindahkan teks/gambar dari laptop ke HP (dan sebaliknya) masih lewat chat ke diri sendiri,
email, atau cloud. Lambat, dan data lewat server pihak ketiga.

**Solusi:** aplikasi menu bar macOS yang menjalankan server HTTP kecil **di jaringan lokal**.
HP scan QR code dari menu bar, lalu terbuka halaman web di browser. **Tidak perlu install apa pun di HP**,
tanpa cloud, dan tanpa akun.

| Arah | Cara kerja |
|---|---|
| HP → Mac | Tempel teks / pilih gambar di halaman, tekan **Kirim ke Mac** → langsung masuk clipboard Mac |
| Mac → HP | Setiap copy di Mac otomatis muncul di halaman HP (real-time), tinggal tekan **Salin** / tekan lama gambar |

**Target pengguna:** pemilik Mac + HP (Android **dan** iPhone) di Wi-Fi yang sama (rumah, hotspot HP).

### Keputusan desain (default yang dipilih)

| Topik | Keputusan | Alasan |
|---|---|---|
| Platform HP | Android & iPhone lewat browser | Satu kode, tanpa App Store / Play Store |
| Mac → HP | Otomatis (bisa dimatikan di menu → mode manual "Kirim clipboard sekarang") | Paling praktis; tetap ada kontrol |
| Riwayat | 20 item terakhir, **hanya di memori** (hilang saat aplikasi ditutup) | Privasi: clipboard tidak pernah ditulis ke disk |
| Keamanan | Token acak 128-bit di QR code, wajib di setiap request | Orang lain di Wi-Fi yang sama tidak bisa mengintip |
| Isi rahasia | Clipboard bertanda `org.nspasteboard.ConcealedType` (password manager) **tidak** dikirim | Password tidak bocor ke HP |
| Real-time | Long-polling HTTP (bukan WebSocket) | Sederhana, tanpa dependensi, tahan HP tidur / sinyal putus |
| Teknologi | Swift + AppKit + Network.framework, **satu file sumber, tanpa dependensi** | Konsisten dengan LiteScroller & LiteMonitor |
| Versi awal | `0.1.0` (build `1`) | Rilis pertama |

### Di luar cakupan (lihat `_techdebt/konsep_opsi_b.md`)

- Aplikasi native di HP, penemuan otomatis via Bonjour
- Sinkron otomatis HP → Mac tanpa aksi pengguna (dibatasi OS)
- Kirim file selain gambar
- Enkripsi HTTPS (sertifikat self-signed memicu peringatan browser)

## Status sprint

| Sprint | Fokus | Status |
|---|---|---|
| [Sprint 1](sprint-1-fondasi.md) | Fondasi: struktur repo, build/CI, menu bar, server HTTP, token, QR | ✅ Selesai |
| [Sprint 2](sprint-2-hp-ke-mac.md) | Halaman web + alur HP → Mac (teks & gambar) | ✅ Selesai |
| [Sprint 3](sprint-3-mac-ke-hp.md) | Pantau clipboard Mac + alur Mac → HP real-time + riwayat | ✅ Selesai |
| [Sprint 4](sprint-4-polish-rilis.md) | Polish, keamanan, update/uninstall, README, rilis `v0.1.0` | ✅ Selesai (kode) — ⏳ uji di Mac nyata |

## Checklist tugas

### Sprint 1 — Fondasi
- [x] Struktur repo mengikuti LiteScroller (`Sources/`, `Resources/`, `scripts/`, `.github/workflows/`)
- [x] `AGENTS.md` + `CLAUDE.md` (aturan versioning `a.b.c`)
- [x] `Resources/Info.plist` (`id.local.pastelan`, `0.1.0`, build `1`, `LSUIElement`, `NSLocalNetworkUsageDescription`)
- [x] `scripts/build.sh` (+ universal), `scripts/make-installer.sh`
- [x] Workflow build + rilis otomatis
- [x] Ikon menu bar + menu yang dibangun ulang setiap dibuka
- [x] Server HTTP mini di atas `NWListener` (parse request, `Content-Length`, batas ukuran, timeout)
- [x] Port default `8787`, otomatis coba port berikutnya kalau sibuk
- [x] Token acak tersimpan di `UserDefaults`, perbandingan constant-time
- [x] Deteksi IP lokal (utamakan `en*`, abaikan VPN/loopback/link-local)
- [x] QR code (CoreImage) langsung di dalam menu + "Salin link"
- [x] Toggle "Berbagi aktif"

### Sprint 2 — HP → Mac
- [x] Halaman web tertanam (HTML/CSS/JS dalam binary), mode gelap otomatis, ramah notch/safe-area
- [x] `POST /api/text` → clipboard Mac
- [x] `POST /api/image` (PNG/JPEG/HEIC/GIF/WebP) → clipboard Mac (TIFF + format asli)
- [x] Tempel gambar langsung di kotak teks (event `paste`)
- [x] Kirim beberapa gambar sekaligus
- [x] Umpan balik: toast di HP, ikon menu bar berubah ✓ sebentar
- [x] Opsi "Simpan juga gambar dari HP ke folder Unduhan"
- [x] Halaman "link tidak berlaku" kalau token salah

### Sprint 3 — Mac → HP
- [x] Pantau `NSPasteboard.changeCount` (timer 0,8 dtk + toleransi, hanya saat berbagi aktif & mode otomatis)
- [x] Baca teks, gambar (PNG/TIFF), dan file gambar yang di-copy dari Finder
- [x] Lewati isi rahasia/sementara (konvensi nspasteboard.org)
- [x] Tidak memantul: isi yang ditulis PasteLAN sendiri tidak dikirim balik
- [x] Riwayat 20 item di memori (batas total gambar 150 MB), duplikat berturut-turut diabaikan
- [x] `GET /api/items` long-poll (25 dtk) + `session` supaya HP reset saat Mac restart / riwayat dihapus
- [x] `GET /api/image/<id>` untuk pratinjau & simpan
- [x] Tombol **Salin** (fallback `execCommand` karena HTTP lokal bukan secure context)
- [x] Submenu Riwayat di Mac (klik = salin ulang) + "Hapus riwayat"
- [x] Mode manual: "Kirim clipboard Mac sekarang" (v1.8.0: digabung ke **Autosync**; saat mati kirim satu clip lewat ⇧ + klik)
- [x] Jumlah perangkat terhubung di menu

### Sprint 4 — Polish & rilis
- [x] Buka saat login (`SMAppService`)
- [x] Cek pembaruan dari GitHub Releases + update dari menu
- [x] Uninstall dari menu
- [x] "Cara pakai…" + onboarding saat pertama dibuka
- [x] "Ganti token" (putuskan semua HP)
- [x] Batas koneksi (64), timeout request (60 dtk), header maks 32 KB, body maks 30 MB
- [x] README lengkap
- [x] Cek sintaks Swift (`swiftc -parse`) di Linux
- [ ] **Build di macOS** (otomatis di GitHub Actions saat PR / push)
- [ ] **Uji manual di Mac + HP nyata** (lihat daftar uji di `sprint-4-polish-rilis.md`)
- [ ] Merge ke `main` → rilis otomatis `v0.1.0`

## Risiko & catatan

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Wi-Fi kantor/kampus/publik memakai *client isolation* | HP tidak bisa membuka halaman | Dijelaskan di README & "Cara pakai"; pakai hotspot HP |
| Firewall macOS menanyakan izin koneksi masuk | Server tidak terjangkau sampai diizinkan | Codesign dengan designated requirement berbasis identifier → izin bertahan antar-update |
| *Local Network privacy* macOS 15+ | Mungkin muncul dialog izin | `NSLocalNetworkUsageDescription` sudah diisi |
| HTTP lokal tidak terenkripsi | Bisa disadap di Wi-Fi yang sama | Token mencegah akses, bukan penyadapan → dicatat; HTTPS ada di tech debt |
| iOS Safari menangguhkan halaman di background | Item baru muncul telat | Polling langsung diulang saat halaman tampil lagi (`visibilitychange`) |
| Belum ada Mac untuk uji langsung di sesi pengembangan | Bug runtime bisa lolos | Cek sintaks di Linux + build CI di macOS + daftar uji manual |
