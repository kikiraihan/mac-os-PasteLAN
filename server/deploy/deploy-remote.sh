#!/usr/bin/env bash
#
# Deploy dari laptop tanpa GitHub Actions: build binary Linux di sini, kirim ke VPS, jalankan deploy.sh di sana.
#
#   server/deploy/deploy-remote.sh root@43.128.81.214          # atau alias dari ~/.ssh/config
#   SSH_PORT=2222 server/deploy/deploy-remote.sh user@host      # user bukan root → butuh sudo tanpa password
#
# Butuh Go di laptop (build silang ke Linux); VPS tidak butuh Go / git.
#
set -euo pipefail

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Pakai: $0 user@host" >&2; exit 1; }
SSH_PORT="${SSH_PORT:-22}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
ssh_=(ssh -p "$SSH_PORT" -o ConnectTimeout=15)
scp_=(scp -q -P "$SSH_PORT")

case "$("${ssh_[@]}" "$TARGET" uname -m)" in
	x86_64|amd64) arch=amd64 ;;
	aarch64|arm64) arch=arm64 ;;
	*) echo "Arsitektur VPS tidak didukung." >&2; exit 1 ;;
esac

v="$(tr -d '\n' < "$root/Resources/Info.plist" | sed -nE 's/.*<key>CFBundleShortVersionString<\/key>[[:space:]]*<string>([^<]+)<\/string>.*/\1/p')"
version="v$v+$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo lokal)"
[ -z "$(git -C "$root" status --porcelain -- server 2>/dev/null)" ] || version="$version-dirty"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Build $version (linux/$arch) ..."
(cd "$root/server" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath \
	-ldflags="-s -w -X main.version=$version" -o "$tmp/pastelan-server" .)

dir="$("${ssh_[@]}" "$TARGET" 'mktemp -d /tmp/pastelan-deploy.XXXXXX')"
"${scp_[@]}" "$tmp/pastelan-server" "$here/deploy.sh" "$here/rollback.sh" "$TARGET:$dir/"
"${ssh_[@]}" "$TARGET" "sudo_=; [ \"\$(id -u)\" = 0 ] || sudo_='sudo -n'; \
	\$sudo_ env SKIP_BACKUP='${SKIP_BACKUP:-0}' EXPECT_VERSION='$version' bash '$dir/deploy.sh' '$dir/pastelan-server'; \
	rc=\$?; rm -rf '$dir'; exit \$rc"
