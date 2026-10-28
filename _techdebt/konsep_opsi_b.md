# Konsep Opsi B — Mac app + aplikasi native di HP

> Status: **tech debt / ide masa depan**. Belum dikerjakan. Opsi A (Mac app + HP lewat browser)
> sudah dibuat di `_todo/opsi-a-mac-app-plus-browser-hp/`.

## Kenapa dipertimbangkan

Opsi A tidak perlu install apa pun di HP, tapi punya batasan bawaan browser:

| Batasan opsi A | Bisa diatasi di opsi B? |
|---|---|
| HP harus scan QR / membuka bookmark dulu | ✅ Penemuan otomatis via Bonjour (mDNS) |
| Halaman harus terbuka supaya menerima item dari Mac | ⚠️ Sebagian: Android bisa pakai foreground service; iOS tetap terbatas |
| Tombol "Salin" pakai fallback `execCommand` (HTTP lokal bukan secure context) | ✅ API clipboard native |
| Gambar tidak bisa disalin ke clipboard HP dengan satu tombol (harus tekan lama) | ✅ API clipboard native |
| Tidak terenkripsi (HTTP) | ✅ TLS dengan sertifikat yang di-pin saat pairing |
| Tidak ada notifikasi saat Mac mengirim sesuatu | ✅ Notifikasi lokal |

## Arsitektur

```
┌──────────────── Mac (PasteLAN.app) ────────────────┐         ┌────────── HP (PasteLAN mobile) ──────────┐
│ NSPasteboard watcher                               │         │ Share sheet / Quick Settings tile / widget│
│ NWListener (TLS) + Bonjour "_pastelan._tcp"        │◀──LAN──▶│ NWBrowser (iOS) / NsdManager (Android)    │
│ Pairing: QR berisi kunci publik + kode 6 digit     │         │ Clipboard API native + notifikasi lokal   │
└────────────────────────────────────────────────────┘         └───────────────────────────────────────────┘
```

- **Penemuan:** Mac mengiklankan `_pastelan._tcp` via Bonjour (`NWListener.service`). HP mencari layanan itu,
  jadi tidak perlu IP/QR lagi setelah pairing pertama. IP Mac berubah pun tidak masalah.
- **Pairing (sekali):** QR berisi fingerprint sertifikat + rahasia pairing. Setelah itu kedua sisi menyimpan kunci
  (Keychain / Android Keystore) dan koneksi berikutnya otomatis.
- **Transport:** TCP + TLS (sertifikat self-signed yang di-*pin*, jadi tanpa peringatan), pesan JSON berbingkai
  panjang (length-prefixed) atau WebSocket. Dua arah, persisten, ada heartbeat.
- **Protokol pesan:** `hello`, `clip{kind,mime,data}`, `ack`, `ping/pong`. Bisa dipakai ulang oleh opsi A
  (server Mac tetap melayani browser).

## Per platform

### Android (Kotlin)
- Menerima dari Mac: foreground service + notifikasi "Salin" (Android 10+ hanya membolehkan **menulis**
  clipboard dari background, jadi aman).
- Mengirim ke Mac: Android 10+ **melarang membaca** clipboard dari background → pakai:
  - tile Quick Settings "Kirim clipboard", atau
  - share sheet ("Bagikan → PasteLAN"), atau
  - tombol di notifikasi (membuka activity transparan sesaat untuk membaca clipboard).
- Distribusi: APK di GitHub Releases (sideload) atau Play Store.

### iOS (Swift/SwiftUI)
- Membaca clipboard memunculkan banner "PasteLAN pasted from …"; tidak bisa di background.
- Mengirim ke Mac: Share Extension, widget, atau Shortcut ("Kirim clipboard ke Mac").
- Menerima dari Mac: hanya saat aplikasi terbuka (tidak ada socket di background); alternatif notifikasi lokal
  tidak mungkin tanpa push server → **bertentangan dengan prinsip tanpa server**.
- Wajib `NSLocalNetworkUsageDescription` + `NSBonjourServices`.
- Distribusi: butuh Apple Developer Program ($99/tahun) untuk TestFlight/App Store, atau sideload 7 hari via Xcode.

## Perkiraan usaha

| Bagian | Perkiraan |
|---|---|
| Refactor server Mac: TLS + Bonjour + protokol pesan | 1 sprint |
| Aplikasi Android (service, tile, share, pairing) | 2 sprint |
| Aplikasi iOS (app, share extension, pairing) | 2 sprint |
| CI build & distribusi kedua aplikasi | 1 sprint |

## Prasyarat sebelum mulai

1. Opsi A sudah stabil dipakai sehari-hari (protokol & UX terbukti).
2. Putuskan platform prioritas (Android dulu lebih murah: tanpa biaya developer, background lebih longgar).
3. Putuskan apakah server Mac tetap melayani browser (disarankan: ya, sebagai fallback tanpa install).

## Alternatif yang sudah ada (pembanding)

- **LocalSend**: open source, semua platform, fokus kirim file
- **KDE Connect**: Android ↔ desktop, termasuk sinkron clipboard
- **Universal Clipboard** Apple: otomatis kalau HP-nya iPhone dengan Apple ID yang sama
