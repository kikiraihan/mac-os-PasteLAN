#!/usr/bin/env bash
#
# Rollback manual ke binary sebelum deploy terakhir. Dijalankan DI VPS:
#   sudo bash /usr/local/lib/pastelan/rollback.sh
#
# Binary lama disimpan deploy.sh sebagai /usr/local/bin/pastelan-server.prev. Rollback menukar keduanya,
# jadi menjalankan rollback dua kali = kembali ke versi baru. Data (devices.json / settings.json) tidak diubah;
# backup pre-deploy ada di /var/backups/pastelan/ kalau perlu dipulihkan manual.
#
set -euo pipefail

SERVICE="${SERVICE:-pastelan}"
BIN="${BIN:-/usr/local/bin/pastelan-server}"
PREV_BIN="$BIN.prev"

[ "$(id -u)" = 0 ] || { echo "Jalankan sebagai root (sudo)." >&2; exit 1; }
[ -f "$PREV_BIN" ] || { echo "Tidak ada binary lama ($PREV_BIN)." >&2; exit 1; }

cp -p "$BIN" "$BIN.rollback-tmp"
install -m 755 "$PREV_BIN" "$BIN.new"
mv -f "$BIN.new" "$BIN"
mv -f "$BIN.rollback-tmp" "$PREV_BIN"
systemctl restart "$SERVICE"
sleep 2
systemctl --no-pager status "$SERVICE" | head -5
journalctl -u "$SERVICE" --no-pager -o cat -n 5 | grep -F 'PasteLAN server' | tail -1 || true
echo "Rollback selesai (binary yang tadi terpasang sekarang di $PREV_BIN)."
