#!/usr/bin/env bash
# Pull the seven homelab certificates from edge VPS over the existing NetBird SSH
# path and atomically refresh the local Traefik certificate files.

HOMELAB_LOG_TAG=local-edge-certsync
. "$(cd "$(dirname "$0")/../lib" && pwd)/common.sh"

require_root
require_cmd ssh tar openssl cmp install mktemp sha256sum awk

readonly CERT_ROOT=/srv/homelab/appdata/local-edge/certs
readonly REMOTE_EXPORT=/srv/edge-vps-demo/operations/traefik/export-homelab-certs.py
readonly CERT_MINIMUM_SECONDS=604800  # seven days; fail closed before expiry
readonly DOMAINS=(
  home.example.com
  assistant.home.example.com
  next.home.example.com
  images.home.example.com
  media.home.example.com
  pihole.home.example.com
  portainer.home.example.com
)

work=$(mktemp -d /run/homelab-certsync.XXXXXX)
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

install -d -o root -g root -m 0755 "$CERT_ROOT"

log "pulling selected certificates from edge VPS"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes edge-vps \
  "python3 ${REMOTE_EXPORT}" \
  | tar --extract --gzip --file=- --directory="$work" \
        --no-same-owner --no-same-permissions

for domain in "${DOMAINS[@]}"; do
  cert="$work/$domain/fullchain.pem"
  key="$work/$domain/privkey.pem"
  [ -f "$cert" ] && [ ! -L "$cert" ] || die "missing or unsafe certificate for $domain"
  [ -f "$key" ] && [ ! -L "$key" ] || die "missing or unsafe private key for $domain"

  openssl x509 -in "$cert" -noout >/dev/null \
    || die "certificate for $domain is not parseable"
  openssl x509 -in "$cert" -noout -checkend "$CERT_MINIMUM_SECONDS" >/dev/null \
    || die "certificate for $domain expires in less than seven days"
  openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null \
    || die "certificate for $domain does not cover its hostname"

  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -pubout \
    | openssl pkey -pubin -outform DER \
    | sha256sum | awk '{print $1}')
  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] \
    || die "certificate/private-key mismatch for $domain"
done

for domain in "${DOMAINS[@]}"; do
  target_dir="$CERT_ROOT/$domain"
  install -d -o root -g root -m 0755 "$target_dir"
  for name in fullchain.pem privkey.pem; do
    mode=0644
    [ "$name" = privkey.pem ] && mode=0600
    source="$work/$domain/$name"
    target="$target_dir/$name"
    if [ -f "$target" ] && cmp -s "$source" "$target"; then
      log "$domain/$name unchanged"
      continue
    fi
    staged="$target.tmp.$$"
    install -o root -g root -m "$mode" "$source" "$staged"
    mv -f -- "$staged" "$target"
    log "$domain/$name updated"
  done
done

marker="$CERT_ROOT/.ready"
staged_marker="$marker.tmp.$$"
printf '%s\n' "$(date -Is)" > "$staged_marker"
install -o root -g root -m 0644 "$staged_marker" "$marker"
rm -f -- "$staged_marker"
sync
log "certificate set is ready for local Traefik"
