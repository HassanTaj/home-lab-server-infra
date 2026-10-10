#!/usr/bin/env bash
# Run Nextcloud WITHOUT the data disk, or return it to normal.
#
# For when the disk is dead, lost, or deliberately retired. Nextcloud normally
# refuses to start without it -- deliberately, see operations/storage/verify-disk.sh
# -- but almost all of its data lives on the internal SSD:
#
#     /srv/homelab/nextcloud-data          user files
#     /srv/homelab/appdata/nextcloud/html  the installation
#     /srv/homelab/shared-internal         the internal share
#
# Only the two data-disk external storages need the disk. Without this script the only
# way to serve the SSD data with a dead disk is hand-editing Compose at 3am.
#
#   nextcloud-degraded.sh --status   (default)
#   nextcloud-degraded.sh --on
#   nextcloud-degraded.sh --off      (requires the real disk to be back)
#
# THE IMPORTANT PART: it is not enough to stop binding the disk. If Nextcloud can
# still see /mnt/data as an empty directory, its scanner treats every file
# under the data-disk external storages as deleted, purges them from oc_filecache
# (many rows as of YYYY-MM-DD, 99.97% of the whole table) and sync clients
# then delete the users' local copies. Two independent guards prevent it:
#
#   1. The Compose override binds a regular FILE over /mnt/data, so the Local
#      backend's is_dir() check fails and the storage is reported unavailable
#      rather than empty. Unavailable storages are never scanned.
#   2. The data-disk external storages are repointed at a path that does not exist,
#      so they report unavailable even if guard 1 were ever removed.
#
# Mode is switched by swapping which of two units is enabled, NOT by a drop-in.
# A drop-in cannot work: RequiresMountsFor= and the Requires= it generates are
# additive only in systemd, so blanking them has no effect and the disk loss
# would still cascade-stop the unit meant to survive it. See the header of
# operations/bootstrap/homelab-nextcloud-degraded.service.in.

HOMELAB_LOG_TAG=nc-degraded
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker systemctl

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
readonly NC_COMPOSE="${REPO_ROOT}/runtime/compose/nextcloud/docker-compose.yml"
readonly NC_DEGRADED="${REPO_ROOT}/runtime/compose/nextcloud/docker-compose.degraded.yml"
readonly UNIT_NORMAL=homelab-nextcloud.service
readonly UNIT_DEGRADED=homelab-nextcloud-degraded.service
readonly MARKER=/srv/homelab/data-offline.marker
readonly OFFLINE_DATADIR=/mnt/data-OFFLINE
readonly LIVE_DATADIR=/mnt/data
readonly CT=homelab-nextcloud

occ() { docker exec -u www-data "$CT" php occ "$@"; }

# Mount ids of the admin external storages that point at the data-disk path.
# Discovered rather than hardcoded: ids change if a mount is recreated.
data_mount_ids() {
  local want="$1"
  occ files_external:list --output=json 2>/dev/null | python3 -c "
import json,sys
try: mounts = json.load(sys.stdin)
except Exception: sys.exit(0)
for m in mounts:
    if m.get('configuration',{}).get('datadir') == '$want':
        print(m['mount_id'])
"
}

wait_healthy() {
  local i
  for i in $(seq 1 60); do
    case "$(docker inspect -f '{{.State.Health.Status}}' "$CT" 2>/dev/null || true)" in
      healthy) log "${CT} is healthy"; return 0 ;;
    esac
    sleep 3
  done
  die "${CT} did not become healthy in 180s - see: docker logs ${CT}"
}

degraded_active() {
  [ "$(systemctl is-enabled "$UNIT_DEGRADED" 2>/dev/null || true)" = enabled ]
}

status() {
  if degraded_active; then
    log "MODE: DEGRADED (running without the data disk)"
  else
    log "MODE: normal (data disk required)"
  fi
  printf '  %-30s %s\n' "$UNIT_NORMAL"   "$(systemctl is-active "$UNIT_NORMAL"   2>/dev/null || true)"
  printf '  %-30s %s\n' "$UNIT_DEGRADED" "$(systemctl is-active "$UNIT_DEGRADED" 2>/dev/null || true)"
  printf '  data mounted    %s\n' "$(mountpoint -q "$DATA_MOUNT" && echo yes || echo no)"
  if docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true; then
    printf '  data storages   live=%s offline=%s\n' \
      "$(data_mount_ids "$LIVE_DATADIR" | tr '\n' ' ')" \
      "$(data_mount_ids "$OFFLINE_DATADIR" | tr '\n' ' ')"
  else
    printf '  data storages   (container not running)\n'
  fi
}

turn_on() {
  degraded_active && { log "already in degraded mode"; status; return 0; }
  systemctl cat "$UNIT_DEGRADED" >/dev/null 2>&1 \
    || die "${UNIT_DEGRADED} is not installed - run operations/bootstrap/50-systemd.sh"

  # Guard 1: the file that gets bound over /mnt/data. Read-only for everyone
  # so nothing can ever treat it as a writable location.
  printf '%s\n' \
    'Nextcloud is running in degraded mode: the data disk is not attached.' \
    'This FILE is bound over /mnt/data so the data-disk external storages report' \
    '"Storage not available" instead of appearing empty. An empty directory here' \
    'would make the scanner purge oc_filecache and propagate deletions to sync' \
    'clients. Managed by operations/storage/nextcloud-degraded.sh - do not edit.' \
    > "$MARKER"
  chown root:root "$MARKER"; chmod 0444 "$MARKER"
  log "wrote guard file ${MARKER}"

  # Swap which unit is enabled, so a reboot and the watchdog both agree on the
  # mode. Conflicts= is symmetric, so starting the degraded unit stops the normal
  # one; disabling the normal unit first keeps the watchdog from racing it back.
  systemctl disable --now "$UNIT_NORMAL" 2>&1 | sed 's/^/  /' || true

  # The old containers still hold a bind to the (possibly absent) disk, so they
  # must be replaced rather than restarted.
  docker compose -f "$NC_COMPOSE" stop >/dev/null 2>&1 || true

  systemctl reset-failed "$UNIT_DEGRADED" 2>/dev/null || true
  systemctl enable --now "$UNIT_DEGRADED" 2>&1 | sed 's/^/  /'
  wait_healthy

  # Guard 2: repoint the data-disk storages so they report unavailable, not empty.
  local ids id n=0
  ids=$(data_mount_ids "$LIVE_DATADIR")
  for id in $ids; do
    occ files_external:config "$id" datadir "$OFFLINE_DATADIR" >/dev/null
    log "external storage ${id}: datadir -> ${OFFLINE_DATADIR}"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || warn "no external storage pointed at ${LIVE_DATADIR} (already repointed?)"

  log "DEGRADED MODE ACTIVE. SSD data is served; data-disk shares report unavailable."
  status
}

turn_off() {
  degraded_active || { log "not in degraded mode"; status; return 0; }

  # Fail closed: never leave degraded mode unless the real disk is genuinely
  # back. Returning storages to /mnt/data while it is an empty directory is
  # the exact scenario the whole design exists to prevent.
  load_env backup.env
  mountpoint -q "$DATA_MOUNT" || die "${DATA_MOUNT} is not mounted - attach the disk and start mnt-data.mount first"
  verify_data_mounted

  # Repoint the storages back BEFORE the container is swapped, while the
  # marker-file guard is still in place.
  local ids id
  ids=$(data_mount_ids "$OFFLINE_DATADIR")
  for id in $ids; do
    occ files_external:config "$id" datadir "$LIVE_DATADIR" >/dev/null
    log "external storage ${id}: datadir -> ${LIVE_DATADIR}"
  done

  systemctl disable --now "$UNIT_DEGRADED" 2>&1 | sed 's/^/  /' || true
  docker compose -f "$NC_COMPOSE" -f "$NC_DEGRADED" stop >/dev/null 2>&1 || true

  systemctl reset-failed "$UNIT_NORMAL" 2>/dev/null || true
  systemctl enable --now "$UNIT_NORMAL" 2>&1 | sed 's/^/  /'
  wait_healthy
  rm -f "$MARKER"

  log "NORMAL MODE RESTORED."
  status
}

case "${1:---status}" in
  --status) status ;;
  --on)     turn_on ;;
  --off)    turn_off ;;
  *) die "usage: $0 [--status|--on|--off]" ;;
esac
