#!/bin/bash
# Build PasteLAN.app dari Sources/PasteLAN/main.swift
# Syarat: Xcode Command Line Tools  →  xcode-select --install
# Opsi:   ARCH=universal ./scripts/build.sh   (arm64 + x86_64, dipakai di GitHub Actions)
set -e
cd "$(dirname "$0")/.."

APP="build/PasteLAN.app"
SRC="Sources/PasteLAN/main.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compile..."
if [ "${ARCH:-}" = "universal" ]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos13.0  "$SRC" -o build/PasteLAN-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$SRC" -o build/PasteLAN-x86_64
  lipo -create build/PasteLAN-arm64 build/PasteLAN-x86_64 -output "$APP/Contents/MacOS/PasteLAN"
  rm -f build/PasteLAN-arm64 build/PasteLAN-x86_64
else
  swiftc -O -swift-version 5 "$SRC" -o "$APP/Contents/MacOS/PasteLAN"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ Codesign (ad-hoc)..."
# designated requirement cukup identifier (bukan cdhash) → izin firewall ("terima koneksi masuk")
# tetap berlaku setelah update / build ulang, tidak perlu dihapus lalu ditambah lagi
codesign --force --sign - --identifier id.local.pastelan \
  --requirements '=designated => identifier "id.local.pastelan"' "$APP"

echo "✅ Selesai: $APP"
echo "   Pasang:  cp -R $APP /Applications/ && open /Applications/PasteLAN.app"
