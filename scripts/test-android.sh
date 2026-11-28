#!/bin/bash
# Uji klien Android (android/app/.../Api.kt) terhadap server Go asli.
# Butuh Go, JDK 17+, dan Android SDK (android/local.properties: sdk.dir=… atau ANDROID_HOME).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

(cd server && go build -o "$WORK/pastelan-server" .)
PASS="password-tes-android-$RANDOM-$RANDOM"
PASTELAN_ADDR=127.0.0.1:8097 PASTELAN_DATA="$WORK/data" PASTELAN_PASSWORD="$PASS" \
  "$WORK/pastelan-server" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS -H 'X-PasteLAN: 1' http://127.0.0.1:8097/api/config >/dev/null 2>&1 && break; sleep 0.2; done

cd android
PASTELAN_URL=http://127.0.0.1:8097 PASTELAN_PASS="$PASS" \
  ./gradlew --no-daemon -q testDebugUnitTest --tests '*ServerIntegrationTest*' --rerun
echo "Tes klien Android ⇄ server: LULUS"
