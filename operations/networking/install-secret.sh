#!/usr/bin/env bash
# Create Pi-hole's dashboard password without printing it or storing it in Git.

HOMELAB_LOG_TAG=pihole-secret
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd install mktemp openssl stat

readonly TARGET=${HOMELAB_SECRETS_DIR}/pihole-web-password

if [ -e "$TARGET" ]; then
  [ -f "$TARGET" ] || die "$TARGET exists but is not a regular file"
  [ "$(stat -c '%U:%G' "$TARGET")" = root:root ] \
    || die "$TARGET must be owned by root:root"
  [ "$(stat -c '%a' "$TARGET")" = 600 ] \
    || die "$TARGET must have mode 600"
  [ -s "$TARGET" ] || die "$TARGET is empty"
  [ "$(wc -l < "$TARGET")" -eq 1 ] || die "$TARGET must contain exactly one line"
  log "keeping existing ${TARGET}"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
openssl rand -hex 32 > "$tmp"
install -o root -g root -m 0600 "$tmp" "$TARGET"
log "generated ${TARGET} (password not printed)"
