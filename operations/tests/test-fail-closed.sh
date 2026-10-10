#!/usr/bin/env bash
# Prove the storage safety interlocks actually fail closed.
#
# Verifies, without unplugging anything, that:
#   1. verify-disk.sh refuses when the mountpoint is not a mountpoint,
#   2. verify-disk.sh refuses when the marker file is absent,
#   3. the Compose launcher will not start without a verified data mount,
#   4. a backup script refuses when the UUID does not match.
#
# Uses a private mount namespace so the live system is never disturbed.

HOMELAB_LOG_TAG=fail-closed
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

require_root
require_cmd unshare mountpoint

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERIFY="${REPO_ROOT}/operations/storage/verify-disk.sh"
POOL_VERIFY="${REPO_ROOT}/operations/storage/verify-pool.sh"
fail=0

expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL  %s (command unexpectedly SUCCEEDED)\n' "$desc"; fail=1
  else
    printf '  OK    %s (refused as designed)\n' "$desc"
  fi
}

echo "=== 1. unmounted data disk ==="
# A private namespace with the mount detached; the live mount is unaffected.
expect_fail "verify-disk.sh with /mnt/data unmounted" \
  unshare --mount --propagation private -- \
    sh -c "umount -l ${DATA_MOUNT} 2>/dev/null; ${VERIFY}"

echo
echo "=== 2. mounted but marker missing ==="
echo
echo "=== 1a. unmounted mergerfs pool ==="
expect_fail "verify-pool.sh with /mnt/storage unmounted" \
  unshare --mount --propagation private -- \
    sh -c "umount -l /mnt/storage 2>/dev/null; ${POOL_VERIFY}"

expect_fail "verify-disk.sh with an empty tmpfs standing in for the disk" \
  unshare --mount --propagation private -- \
    sh -c "mount -t tmpfs none ${DATA_MOUNT} && ${VERIFY}"

echo
echo "=== 3. Compose launcher gates ==="
# Nextcloud is the only project that binds a path inside the data disk, so it is
# the only unit that may carry the data-disk dependency. The other two MUST NOT, or a
# USB re-enumeration takes the whole stack down again (incident YYYY-MM-DD).
NC_UNIT=/etc/systemd/system/homelab-nextcloud.service
if grep -q 'ExecStartPre=.*verify-disk.sh' "$NC_UNIT" 2>/dev/null; then
  printf '  OK    homelab-nextcloud.service gates on verify-disk.sh\n'
else
  printf '  FAIL  homelab-nextcloud.service has no verify-disk.sh ExecStartPre\n'; fail=1
fi
if grep -q 'RequiresMountsFor=/mnt/data /mnt/storage' "$NC_UNIT" 2>/dev/null; then
  printf '  OK    homelab-nextcloud.service requires data and pool mounts\n'
else
  printf '  FAIL  homelab-nextcloud.service lacks both storage RequiresMountsFor paths\n'; fail=1
fi
if grep -q 'ExecStartPre=.*verify-pool.sh' "$NC_UNIT" 2>/dev/null; then
  printf '  OK    homelab-nextcloud.service gates on verify-pool.sh\n'
else
  printf '  FAIL  homelab-nextcloud.service has no verify-pool.sh ExecStartPre\n'; fail=1
fi
for u in homelab-databases homelab-management homelab-landing homelab-networking; do
  if grep -qE 'RequiresMountsFor|verify-disk' "/etc/systemd/system/${u}.service" 2>/dev/null; then
    printf '  FAIL  %s.service is coupled to the data disk\n' "$u"; fail=1
  else
    printf '  OK    %s.service is independent of the data disk\n' "$u"
  fi
done
# Jellyfin's whole library is on the data disk, so it MUST be gated. Without the
# gate an absent disk means an empty bind, and its library scan would strip
# 43,481 items out of its own database.
MEDIA_UNIT=/etc/systemd/system/homelab-media.service
for chk in 'RequiresMountsFor=/mnt/data' 'ExecStartPre=.*verify-disk'; do
  if grep -qE "$chk" "$MEDIA_UNIT" 2>/dev/null; then
    printf '  OK    homelab-media.service has %s\n' "${chk%%=*}"
  else
    printf '  FAIL  homelab-media.service is missing %s\n' "${chk%%=*}"; fail=1
  fi
done
# The public landing page must not be able to rewrite what it serves.
if grep -qE './site:/usr/share/nginx/html:ro' "${REPO_ROOT}/runtime/compose/landing/docker-compose.yml" 2>/dev/null; then
  printf '  OK    landing page serves its files read-only\n'
else
  printf '  FAIL  landing page site directory is writable by the web server\n'; fail=1
fi

# Media must never be writable: the data disk has no backup.
if grep -qE '/mnt/data:/media:ro' "${REPO_ROOT}/runtime/compose/media/docker-compose.yml" 2>/dev/null; then
  printf '  OK    Jellyfin mounts the media library read-only\n'
else
  printf '  FAIL  Jellyfin media mount is not read-only - 507GB of unbacked-up video is writable\n'; fail=1
fi
# `down` in an ExecStop turns a cascade stop into container destruction.
for u in homelab-databases homelab-nextcloud homelab-nextcloud-degraded homelab-management homelab-media homelab-landing homelab-networking; do
  if grep -qE '^ExecStop=.*compose .*down' "/etc/systemd/system/${u}.service" 2>/dev/null; then
    printf '  FAIL  %s.service ExecStop uses `down` - a cascade would destroy containers\n' "$u"; fail=1
  else
    printf '  OK    %s.service ExecStop does not destroy containers\n' "$u"
  fi
done
if [ -e /etc/systemd/system/homelab-compose.service ]; then
  printf '  FAIL  retired homelab-compose.service is still installed\n'; fail=1
else
  printf '  OK    retired homelab-compose.service is absent\n'
fi

echo
echo "=== 3a. degraded mode (run without the data disk) ==="
DEG_UNIT=/etc/systemd/system/homelab-nextcloud-degraded.service
if [ -e "$DEG_UNIT" ]; then
  printf '  OK    homelab-nextcloud-degraded.service is installed\n'
  # The whole point of the unit: no data disk coupling. A drop-in cannot achieve this
  # because RequiresMountsFor=/Requires= are additive-only in systemd, so if this
  # ever regresses to a drop-in the unit stops surviving a disk loss.
  if grep -qE '^(RequiresMountsFor=.*/mnt/data|ExecStartPre=.*verify-disk)' "$DEG_UNIT"; then
    printf '  FAIL  degraded unit is coupled to the data disk - it cannot survive a removal\n'; fail=1
  else
    printf '  OK    degraded unit has no data-disk dependency\n'
  fi
  if grep -q '^Conflicts=homelab-nextcloud.service' "$DEG_UNIT"; then
    printf '  OK    degraded unit conflicts with the normal unit\n'
  else
    printf '  FAIL  degraded unit lacks Conflicts= - both could hold the same containers\n'; fail=1
  fi
else
  printf '  FAIL  homelab-nextcloud-degraded.service is not installed\n'; fail=1
fi

# Exactly one mode may be enabled, or a reboot is a coin flip.
n_enabled=0
for u in homelab-nextcloud homelab-nextcloud-degraded; do
  [ "$(systemctl is-enabled "${u}.service" 2>/dev/null || true)" = enabled ] && n_enabled=$((n_enabled + 1))
done
if [ "$n_enabled" -eq 1 ]; then
  printf '  OK    exactly one Nextcloud mode is enabled\n'
else
  printf '  FAIL  %s Nextcloud units enabled, expected exactly 1\n' "$n_enabled"; fail=1
fi

# The override must bind a FILE over /mnt/data. An empty directory there
# makes the scanner purge every data-disk entry from oc_filecache and propagate the
# deletions to sync clients.
DEG_YML=${REPO_ROOT}/runtime/compose/nextcloud/docker-compose.degraded.yml
if grep -q 'data-offline.marker:/mnt/data' "$DEG_YML" 2>/dev/null; then
  printf '  OK    degraded override binds a file over /mnt/data\n'
else
  printf '  FAIL  degraded override does not bind a file over /mnt/data\n'; fail=1
fi

echo
echo "=== 3b. self-heal ==="
if [ "$(systemctl is-enabled homelab-stack-watchdog.timer 2>/dev/null)" = enabled ]; then
  printf '  OK    homelab-stack-watchdog.timer is enabled\n'
else
  printf '  FAIL  homelab-stack-watchdog.timer is not enabled - a disk blip would not self-heal\n'; fail=1
fi
if grep -q 'homelab-networking.service' "${REPO_ROOT}/operations/bootstrap/stack-watchdog.sh"; then
  printf '  OK    watchdog manages homelab-networking.service\n'
else
  printf '  FAIL  watchdog does not manage homelab-networking.service\n'; fail=1
fi

echo
echo "=== 3c. Pi-hole exposure ==="
PIHOLE_YML=${REPO_ROOT}/runtime/compose/networking/docker-compose.yml
for binding in \
  '192.0.2.10:53:53/tcp' \
  '192.0.2.10:53:53/udp' \
  '100.64.0.10:8053:80/tcp'; do
  if grep -q "$binding" "$PIHOLE_YML"; then
    printf '  OK    Pi-hole binding %s\n' "$binding"
  else
    printf '  FAIL  Pi-hole binding missing: %s\n' "$binding"; fail=1
  fi
done
if grep -qE '(^|[" ])0\.0\.0\.0:' "$PIHOLE_YML"; then
  printf '  FAIL  Pi-hole has a wildcard port binding\n'; fail=1
else
  printf '  OK    Pi-hole has no wildcard port binding\n'
fi

echo
echo "=== 4. UUID mismatch ==="
expect_fail "backup refuses a wrong DATA_UUID" \
  env DATA_UUID=00000000DEADBEEF sh -c "
    . ${REPO_ROOT}/operations/lib/common.sh
    verify_data_mounted"

echo
if [ "$fail" -ne 0 ]; then log "fail-closed tests FAILED"; exit 1; fi
log "fail-closed tests passed"
