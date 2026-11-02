# Menu tetap terbuka saat hapus (⌥) / kirim (⌃)

> Status: **ditunda**. Sejak v1.10.0 menu ditutup lalu langsung dibuka lagi (`reopenMenu()` di `main.swift`), jadi
> banyak clip bisa dihapus / dikirim berturut-turut, tapi terlihat kedip (menu keluar lalu muncul lagi).

NSMenu selalu menutup setelah item biasa diklik; tidak ada API untuk mencegahnya. Opsi kalau ingin tanpa kedip:

1. **Baris clip sebagai custom view** (`NSMenuItem.view`): klik pada view tidak menutup menu.
   - Gambar sendiri teks, ikon, sorotan (`enclosingMenuItem.isHighlighted`), titik "baru".
   - `isAlternate` tidak berlaku untuk item ber-view → cek `NSEvent.modifierFlags` berkala (timer di mode
     `.eventTracking`) lalu ganti tampilan "Hapus" / "Kirim".
   - Klik biasa (salin) tetap menutup menu (`menu.cancelTracking()`); ⌥⌘0–9 / ⌃⌘0–9 tetap menutup menu.
   - ±150–200 baris, perlu diuji di Mac.
2. **Ganti menu dengan jendela / panel sendiri**: paling leluasa, tapi hampir menulis ulang menu & tidak terasa
   seperti menu macOS asli.
