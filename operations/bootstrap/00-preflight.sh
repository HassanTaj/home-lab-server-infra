#!/usr/bin/env bash
# Read-only preflight. Verifies the host matches the assumptions in
# guides/setup.mdx before any bootstrap step mutates anything.
#
# Changes nothing. Safe to run at any time.

HOMELAB_LOG_TAG=preflight
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker findmnt blkid ip ss restic mergerfs flock mountpoint

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    log "OK    $1"
  else
    warn "FAIL  $1"
    fail=1
  fi
}

log "--- host ---"
check "docker engine responds"            'docker info'
check "docker compose v2 available"       'docker compose version'
check "NetBird interface wt0 exists"      'ip link show wt0'
check "NetBird address 100.64.0.10 up"  'ip -4 addr show wt0 | grep -q 100.64.0.10'
check "data disk UUID present"           'blkid -U DEMO_DATA_DISK_UUID'

log "--- secrets ---"
for f in databases.env pgadmin.env nextcloud.env redis.env backup.env; do
  if [ -f "${HOMELAB_SECRETS_DIR}/${f}" ]; then
    mode=$(stat -c '%a' "${HOMELAB_SECRETS_DIR}/${f}")
    if [ "$mode" = "600" ]; then log "OK    ${f} (0600)"; else warn "FAIL  ${f} has mode ${mode}"; fail=1; fi
    if grep -q 'CHANGE_ME' "${HOMELAB_SECRETS_DIR}/${f}"; then
      warn "FAIL  ${f} still contains CHANGE_ME placeholders"; fail=1
    fi
  else
    warn "FAIL  ${HOMELAB_SECRETS_DIR}/${f} missing"; fail=1
  fi
done

log "--- port availability on the NetBird address ---"
for port in 8080 9000 5050 9090 8090; do
  if ss -tlnH "sport = :${port}" | grep -q '100.64.0.10'; then
    warn "FAIL  100.64.0.10:${port} already in use"; fail=1
  else
    log "OK    100.64.0.10:${port} free"
  fi
done

log "--- capacity ---"
require_free_gib /home 50 || fail=1

if [ "$fail" -ne 0 ]; then
  die "preflight failed - resolve the FAIL lines above before continuing"
fi
log "preflight passed"
