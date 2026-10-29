#!/usr/bin/env bash
#
# Deploy binary server PasteLAN yang dijalankan DI VPS (sebagai root / lewat sudo), oleh GitHub Actions
# (deploy-server.yml), deploy-remote.sh dari laptop, atau manual:
#
#   sudo bash deploy.sh /path/ke/pastelan-server-linux-amd64
#
# Alurnya:
#   1. cek prasyarat: systemd unit pastelan terpasang, /etc/pastelan.env ada & bukan password contoh, binary valid
#   2. backup data (devices.json + settings.json) → /var/backups/pastelan/predeploy-<waktu>.tar.gz
#   3. simpan binary lama sebagai pastelan-server.prev, pasang binary baru (atomik)
#   4. systemctl restart pastelan
#   5. health check: GET / = 200 dan GET /api/items (tanpa token) = 401
#   6. kalau gagal → rollback otomatis ke binary lama + log 80 baris terakhir
#
# Isi clipboard hanya di memori server, jadi restart selalu mengosongkan riwayat (token perangkat tetap).
#
# Variabel yang bisa dioverride lewat environment:
#   SERVICE         (default: pastelan)
#   BIN             (default: /usr/local/bin/pastelan-server)
#   ENV_FILE        (default: /etc/pastelan.env)
#   HEALTH_URL      (default: dari PASTELAN_ADDR di unit / ENV_FILE, mis. http://127.0.0.1:8080)
#   HEALTH_RETRIES  (default: 20)   percobaan health check
#   HEALTH_DELAY    (default: 1)    jeda detik antar percobaan
#   SKIP_BACKUP     (default: 0)    set 1 untuk lewati backup data
#   NO_ROLLBACK     (default: 0)    set 1 untuk biarkan versi gagal tetap jalan
#   KEEP_BACKUPS    (default: 10)   jumlah backup pre-deploy yang disimpan
#   EXPECT_VERSION  (opsional)      versi yang harus muncul di log start (hanya peringatan kalau tidak cocok)
#
set -euo pipefail

NEW_BIN="${1:-}"
SERVICE="${SERVICE:-pastelan}"
BIN="${BIN:-/usr/local/bin/pastelan-server}"
PREV_BIN="$BIN.prev"
ENV_FILE="${ENV_FILE:-/etc/pastelan.env}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"
HEALTH_DELAY="${HEALTH_DELAY:-1}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"
NO_ROLLBACK="${NO_ROLLBACK:-0}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pastelan}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/pastelan}"
TEMPLATE_PASSWORD="GANTI-dengan-password-acak" # sama dengan templatePassword di server/settings.go

log()  { printf '\033[36m[deploy %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[deploy %s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[31m[deploy %s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- 1. Prasyarat --------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "Jalankan sebagai root (sudo bash $0 ...)."
[ -n "$NEW_BIN" ] && [ -f "$NEW_BIN" ] || die "Binary baru tidak ditemukan: '${NEW_BIN}'. Pakai: deploy.sh <binary>"
command -v systemctl >/dev/null || die "systemd tidak tersedia di server."
command -v curl >/dev/null || die "curl tidak terpasang di server (apt install curl)."
systemctl cat "$SERVICE" >/dev/null 2>&1 \
	|| die "Service '$SERVICE' belum terpasang. Pasang server pertama kali dulu (server/README.md → Pasang di VPS)."
[ -f "$ENV_FILE" ] || die "$ENV_FILE belum ada. Buat dulu (lihat server/deploy/pastelan.env.example), password acak."
if grep -qE "^[[:space:]]*(export[[:space:]]+)?PASTELAN_[A-Z_]*PASSWORD[[:space:]]*=[[:space:]]*[\"']?$TEMPLATE_PASSWORD" "$ENV_FILE"; then
	die "$ENV_FILE masih memakai password contoh '$TEMPLATE_PASSWORD'. Ganti dengan: openssl rand -base64 24"
fi
# aturan password sama dengan config.check di server/main.go: yang diisi minimal 12 karakter dan berbeda satu sama lain.
# Dicek SEBELUM binary diganti & restart: kalau tidak, server (versi baru maupun lama) langsung berhenti saat start
# dan situs jadi 502 di belakang reverse proxy.
env_value() { # nilai terakhir NAME=... di ENV_FILE, tanpa 'export' dan tanda kutip pembungkus
	grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "$ENV_FILE" | tail -1 \
		| sed -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\1/; s/^'(.*)'\$/\1/" || true
}
admin_pw="$(env_value PASTELAN_ADMIN_PASSWORD)"
device_pw="$(env_value PASTELAN_PASSWORD)"
for name in PASTELAN_ADMIN_PASSWORD PASTELAN_PASSWORD; do
	[ "$name" = PASTELAN_ADMIN_PASSWORD ] && v="$admin_pw" || v="$device_pw"
	if [ -n "$v" ] && [ "$(printf '%s' "$v" | LC_ALL=C.UTF-8 wc -m)" -lt 12 ]; then
		die "$name di $ENV_FILE kurang dari 12 karakter (server akan menolak start). Ganti dengan: openssl rand -base64 24"
	fi
done
if [ -n "$admin_pw" ] && [ "$admin_pw" = "$device_pw" ]; then
	die "PASTELAN_ADMIN_PASSWORD dan PASTELAN_PASSWORD di $ENV_FILE harus berbeda."
fi
unset admin_pw device_pw v
[ "$(head -c 4 "$NEW_BIN" | od -An -c | tr -d ' ')" = '177ELF' ] || die "$NEW_BIN bukan binary Linux (ELF)."
case "$(uname -m)" in
	x86_64)  want='x86-64' ;;
	aarch64) want='aarch64' ;;
	*)       want='' ;;
esac
if [ -n "$want" ] && command -v file >/dev/null && ! file -b "$NEW_BIN" | grep -q "$want"; then
	die "Arsitektur binary tidak cocok dengan server ($(uname -m)): $(file -b "$NEW_BIN")"
fi

# alamat health check: PASTELAN_ADDR dari unit systemd, lalu dari ENV_FILE, default 127.0.0.1:8080
addr_from() { tr ' ' '\n' | grep -E '^"?PASTELAN_ADDR=' | tail -1 | sed -E 's/^"?PASTELAN_ADDR=//; s/"$//' | tr -d "'\""; }
if [ -z "${HEALTH_URL:-}" ]; then
	addr="$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null | addr_from || true)"
	[ -n "$addr" ] || addr="$(grep -E '^[[:space:]]*PASTELAN_ADDR=' "$ENV_FILE" | addr_from || true)"
	addr="${addr:-127.0.0.1:8080}"
	case "$addr" in :*) addr="127.0.0.1$addr" ;; 0.0.0.0:*) addr="127.0.0.1:${addr##*:}" ;; esac
	scheme=http
	grep -qE '^[[:space:]]*PASTELAN_TLS_CERT=.+' "$ENV_FILE" && scheme=https
	HEALTH_URL="$scheme://$addr"
fi

# --- 2. Backup data ------------------------------------------------------------
# devices.json (hash token perangkat) & settings.json (pengaturan admin). Isi clipboard tidak pernah di disk.
if [ "$SKIP_BACKUP" != "1" ]; then
	data_dir="$(readlink -f /var/lib/pastelan 2>/dev/null || true)"
	if [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
		mkdir -p "$BACKUP_DIR"
		chmod 700 "$BACKUP_DIR"
		file="$BACKUP_DIR/predeploy-$(date +%Y%m%d-%H%M%S).tar.gz"
		if (umask 077 && tar czf "$file" -C "$data_dir" .); then
			log "Backup data -> $file"
			ls -1t "$BACKUP_DIR"/predeploy-*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
		else
			rm -f "$file"
			warn "Backup data gagal. Lanjut deploy."
		fi
	else
		warn "Folder data /var/lib/pastelan tidak ditemukan, backup dilewati."
	fi
else
	log "Lewati backup data."
fi

# --- 3. Pasang binary baru -----------------------------------------------------
new_sum="$(sha256sum "$NEW_BIN" | cut -d' ' -f1)"
if [ -f "$BIN" ] && [ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$new_sum" ]; then
	log "Binary sama dengan yang terpasang ($(echo "$new_sum" | cut -c1-12)). Tetap restart untuk memastikan."
	had_prev=0
elif [ -f "$BIN" ]; then
	cp -p "$BIN" "$PREV_BIN"
	had_prev=1
	log "Binary lama disimpan -> $PREV_BIN"
else
	had_prev=0
fi
install -m 755 "$NEW_BIN" "$BIN.new"
mv -f "$BIN.new" "$BIN"
log "Binary baru terpasang ($(echo "$new_sum" | cut -c1-12))${EXPECT_VERSION:+, versi $EXPECT_VERSION}"

# rollback.sh ikut dipasang supaya bisa dipakai manual: sudo bash /usr/local/lib/pastelan/rollback.sh
here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/rollback.sh" ]; then
	mkdir -p "$LIB_DIR"
	install -m 755 "$here/rollback.sh" "$LIB_DIR/rollback.sh"
fi

# --- 4 & 5. Restart & health check --------------------------------------------
health_check() {
	local i root api
	for i in $(seq 1 "$HEALTH_RETRIES"); do
		root="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL/" || true)"
		api="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 -H 'X-PasteLAN: 1' "$HEALTH_URL/api/items" || true)"
		if [ "$root" = 200 ] && [ "$api" = 401 ]; then
			log "Health check OK ($HEALTH_URL) setelah ${i}x percobaan."
			return 0
		fi
		sleep "$HEALTH_DELAY"
	done
	warn "Health check terakhir: GET / = $root (harus 200), GET /api/items = $api (harus 401)."
	return 1
}

restart() {
	started="$(date +%s)"
	log "systemctl restart $SERVICE ..."
	# setelah beberapa kali gagal start systemd menolak start baru ("Start request repeated too quickly") → reset dulu
	systemctl reset-failed "$SERVICE" 2>/dev/null || true
	systemctl restart "$SERVICE"
}

restart || true
if ! health_check; then
	warn "Versi baru tidak sehat."
	systemctl --no-pager status "$SERVICE" || true
	journalctl -u "$SERVICE" --no-pager -n 80 --since "@$started" || true
	[ "$NO_ROLLBACK" = "1" ] && die "Health check gagal (rollback dimatikan)."
	[ "$had_prev" = "1" ] || die "Health check gagal dan tidak ada binary lama untuk rollback. Cek manual di server!"
	log "Rollback ke binary lama ..."
	install -m 755 "$PREV_BIN" "$BIN.new"
	mv -f "$BIN.new" "$BIN"
	restart || true
	health_check && die "Versi baru tidak sehat; sudah rollback dan versi lama jalan normal lagi."
	journalctl -u "$SERVICE" --no-pager -n 30 --since "@$started" || true
	die "Versi baru tidak sehat DAN rollback juga tidak sehat. Perlu cek manual di server!"
fi

# --- 6. Info versi -------------------------------------------------------------
line="$(journalctl -u "$SERVICE" --no-pager -o cat --since "@$started" 2>/dev/null | grep -F 'PasteLAN server' | tail -1 || true)"
[ -n "$line" ] && log "Log start: $line"
if [ -n "${EXPECT_VERSION:-}" ] && [ -n "$line" ] && ! printf '%s' "$line" | grep -qF "$EXPECT_VERSION"; then
	warn "Versi di log tidak sama dengan yang diharapkan ($EXPECT_VERSION)."
fi
log "Deploy selesai."
