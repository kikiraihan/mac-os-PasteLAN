#!/bin/bash
# Membuat dist/install-PasteLAN.command: installer satu file
# (source Swift + Info.plist ditanam di dalamnya, compile di Mac pengguna)
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
OUT="dist/install-PasteLAN.command"

{
cat <<'HEAD'
#!/bin/bash
# ============================================================
#  Installer PasteLAN
#  Jalankan:  bash install-PasteLAN.command
#  (compile + pasang ke /Applications + jalankan otomatis)
# ============================================================
set -e
clear
echo "=========================================="
echo "   Installer PasteLAN"
echo "=========================================="

# 1. Cek versi macOS (butuh 13 Ventura ke atas)
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
  echo "❌ Butuh macOS 13 (Ventura) atau lebih baru. Versi Anda: $(sw_vers -productVersion)"
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 1
fi

# 2. Cek compiler Swift (Xcode Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools belum terpasang."
  echo "   Jendela instalasi Apple akan muncul — klik 'Install' dan tunggu sampai selesai."
  echo "   Setelah itu, jalankan installer ini lagi."
  xcode-select --install 2>/dev/null || true
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 0
fi

# 3. Siapkan folder kerja sementara
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
APP="PasteLAN.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 4. Source code aplikasi
cat > main.swift <<'SWIFT_EOF'
HEAD
cat Sources/PasteLAN/main.swift
echo "SWIFT_EOF"
echo ""
echo "cat > \"\$APP/Contents/Info.plist\" <<'PLIST'"
cat Resources/Info.plist
echo "PLIST"
cat <<'TAIL'

echo "▶ Compile (± 30 detik)..."
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/PasteLAN"

echo "▶ Codesign (ad-hoc)..."
# designated requirement cukup identifier → izin tetap berlaku setelah update / install ulang
codesign --force --sign - --identifier id.local.pastelan \
  --requirements '=designated => identifier "id.local.pastelan"' "$APP"

# 5. Tutup versi lama (kalau ada), lalu pasang
pkill -x PasteLAN 2>/dev/null || true
DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -cr "$DEST/$APP" 2>/dev/null || true

echo "▶ Menjalankan PasteLAN..."
open "$DEST/$APP"

echo ""
echo "✅ Selesai! PasteLAN terpasang di: $DEST/$APP"
echo "   • Di menu bar muncul ikon ⇄ (kanan atas). Klik untuk melihat QR code."
echo "   • Scan QR code dengan kamera HP (Wi-Fi yang sama) → halaman PasteLAN terbuka."
echo "   • Kalau macOS bertanya soal koneksi masuk, pilih Izinkan."
echo ""
read -n 1 -s -r -p "Tekan tombol apa saja untuk menutup jendela ini..."
TAIL
} > "$OUT"

chmod +x "$OUT"
echo "✅ $OUT"
