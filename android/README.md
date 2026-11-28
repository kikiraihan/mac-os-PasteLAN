# Aplikasi Android PasteLAN

Kode: folder ini — Kotlin + Jetpack Compose (Material 3, warna sama dengan PWA, mode gelap), minSdk 26 (Android 8),
satu APK untuk server PasteLAN mana pun. Hanya untuk **metode server** (bukan Wi-Fi lokal).

## Fitur

- **Notifikasi kiriman baru dengan tombol Salin** — teks / gambar dari Mac, browser, atau HP lain langsung masuk
  clipboard HP **tanpa membuka aplikasi** (ini yang tidak bisa dilakukan PWA di Android). Ketuk notifikasi = buka
  aplikasi + salin. Isi tidak tampil di layar kunci.
- Pilih yang diberi tahu (Pengaturan → Notifikasi): **semua kiriman dari perangkat lain** (termasuk autosync Mac,
  bawaan) atau **hanya kiriman dengan notifikasi** (⌃ + klik clip di menu Mac).
- **Salin otomatis** (opsional): kiriman baru langsung masuk clipboard HP.
- Riwayat server (terbaru di atas): ketuk = salin, tekan lama = Salin / Bagikan / Hapus.
- Kirim teks (tombol **Tempel** mengambil clipboard HP; gambar di clipboard langsung terkirim) atau pilih gambar.
- **Bagikan → PasteLAN** dari aplikasi lain (teks & gambar), dan **"Kirim ke PasteLAN"** di menu pilihan teks.
- Masuk tanpa password: **Scan QR dari Mac** (menu → Tambah HP (scan QR)…) atau tempel **link setup** dari halaman
  admin (link di clipboard langsung terisi). Password perangkat tetap bisa dipakai bila diaktifkan admin.
- Token perangkat disimpan terenkripsi (Android Keystore), data aplikasi tidak ikut backup.
- **Periksa pembaruan** (Pengaturan → Tentang): membandingkan versi dengan rilis GitHub, tombol Unduh membuka
  `PasteLAN.apk` di browser; Android memastikan tanda tangannya sama dengan versi terpasang.

## Unduh

- Dari server sendiri: `https://server-anda/unduh/PasteLAN.apk` (tanpa login, dialihkan ke rilis GitHub terbaru).
  Ditawarkan di halaman web PasteLAN (spanduk di browser Android + Pengaturan → Aplikasi Android + form masuk),
  halaman admin (Ringkasan → **Aplikasi Android**, ada tombol Salin tautan), dan dialog **Tambah HP (scan QR)…** di Mac.
- Atau langsung dari [Releases](https://github.com/kikiraihan/mac-os-PasteLAN/releases/latest).

## Cara kerja notifikasi

Tanpa Google / FCM: layanan latar depan memegang **long-poll** `GET /api/items?wait=1` ke server (sama dengan
aplikasi Mac & PWA). Android mewajibkan notifikasi tetap **"Menunggu kiriman"** (kanal *Koneksi latar*, prioritas
minimum — bisa disembunyikan di Pengaturan Android → Notifikasi PasteLAN). Isi clipboard hanya lewat server sendiri.

- Izinkan **"berjalan tanpa pembatasan baterai"** (tombol di Pengaturan aplikasi) — tanpa ini sebagian HP
  (Xiaomi, Samsung, Oppo, …) memutus koneksi latar sehingga notifikasi telat.
- Bisa dimatikan: Pengaturan → **Terima saat aplikasi ditutup** (notifikasi hanya saat aplikasi dibuka).
- Item yang ditandai server `notify: true` = dikirim dengan `?notify=1` (⌃ + klik di Mac / tombol di HP lain).
- Gambar diunduh ke folder cache aplikasi untuk pratinjau & salin, dan dihapus begitu hilang dari riwayat server
  atau saat keluar.

## Kunci tanda tangan rilis (pemilik, sekali)

APK rilis harus selalu ditandatangani kunci yang sama, kalau tidak Android menolak pembaruan.

```bash
keytool -genkeypair -v -keystore pastelan.jks -alias pastelan -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 pastelan.jks > pastelan.jks.b64
```

GitHub → repo → Settings → Secrets and variables → Actions:
`ANDROID_KEYSTORE_B64` (isi `pastelan.jks.b64`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`pastelan`),
`ANDROID_KEY_PASSWORD`. Simpan `pastelan.jks` + password di tempat aman (hilang = pengguna harus pasang ulang).
Jangan pernah commit keystore / password (`*.jks` sudah di `.gitignore`).

Tanpa secret ini workflow tetap menguji & membangun, tapi rilis tidak berisi `PasteLAN.apk` (hanya artefak
`PasteLAN-debug.apk` di halaman run Actions, bisa dipasang untuk mencoba).

## Build & tes lokal

```bash
cd android
echo "sdk.dir=$ANDROID_HOME" > local.properties     # sekali
./gradlew testDebugUnitTest assembleDebug            # APK: app/build/outputs/apk/debug/app-debug.apk
cd .. && ./scripts/test-android.sh                   # klien Android ⇄ server Go asli
```

`UiTest` (Robolectric) menyimpan screenshot tiap layar di `app/build/screenshots/`. Build debug memakai package
`id.local.pastelan.debug` (bisa terpasang berdampingan dengan versi rilis). Versi = `Resources/Info.plist`
(`CFBundleShortVersionString` → versionName, `CFBundleVersion` → versionCode), sama dengan aplikasi Mac & server.
Server lokal: `http://10.0.2.2:8080` (emulator) / `127.0.0.1` diizinkan tanpa HTTPS; selain itu wajib HTTPS.
