#!/usr/bin/env bash
# Start any Homelab stack unit that is enabled but not running.
#
# Why this exists: on YYYY-MM-DD 05:34 the USB disk re-enumerated for two
# seconds (usb 1-2: USB disconnect ... new high-speed USB device one second
# later). The mount unit died, systemd cascade-stopped the whole stack through
# RequiresMountsFor, and nothing ever brought it back -- the units are
# Type=oneshot with no Restart=, and the automount only mounts on access. A
# two-second hardware glitch became a service outage.
#
# This closes that gap. It is intentionally conservative:
#   - it only ever calls `systemctl start`, never stop, restart or down,
#   - it skips units that are not enabled, so disabling a unit is respected,
#   - it will not spin on Nextcloud while the data disk is physically absent,
#   - touch /etc/homelab/stack-hold to suspend it entirely for maintenance.

HOMELAB_LOG_TAG=stack-watchdog
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd systemctl

# Single-instance. The port-publish repair below runs `docker compose config` per
# unit and can recreate containers, so a slow run -- a large image pull saturating
# the daemon, for example -- must not be overlapped by the next timer firing.
# Observed YYYY-MM-DD: four runs stacked while an Immich pull was in flight.
exec 9>/run/homelab-stack-watchdog.lock
flock -n 9 || { echo "another stack-watchdog run holds the lock; exiting" >&2; exit 0; }

readonly HOLD=/etc/homelab/stack-hold
if [ -e "$HOLD" ]; then
  log "hold file ${HOLD} present - taking no action"
  exit 0
fi

# DATA_UUID. Needed to tell "disk unplugged" apart from "start genuinely failed".
load_env backup.env

# Both Nextcloud units are listed. Exactly one is ever enabled -- normal or
# degraded -- and the "not enabled, leave it alone" rule below means the watchdog
# automatically manages whichever mode the host is in, with no extra state.
UNITS=(
  homelab-databases.service
  homelab-nextcloud.service
  homelab-nextcloud-degraded.service
  homelab-management.service
  homelab-media.service
  homelab-landing.service
  homelab-immich.service
  homelab-yui.service
  homelab-networking.service
)

started=0
for u in "${UNITS[@]}"; do
  # A unit the operator disabled is left alone.
  if [ "$(systemctl is-enabled "$u" 2>/dev/null || true)" != enabled ]; then
    continue
  fi

  state=$(systemctl is-active "$u" 2>/dev/null || true)
  case "$state" in
    active)     continue ;;
    activating) log "${u} is already starting"; continue ;;
  esac

  # Nextcloud is fail-closed on the data disk. Retrying a start that cannot
  # possibly succeed would fill the journal and mask the real cause, so wait
  # for the block device to reappear instead.
  #
  # Applies to the disk-gated units only. homelab-nextcloud-degraded.service is
  # built to run without the disk, so it is never skipped for a missing one.
  case "$u" in homelab-nextcloud.service|homelab-media.service) disk_gated=yes ;; *) disk_gated=no ;; esac
  if [ "$disk_gated" = yes ] \
     && [ ! -e "/dev/disk/by-uuid/${DATA_UUID}" ]; then
    log "${u} down, but data disk ${DATA_UUID} is not attached - waiting for the disk"
    log "  (to run without the disk: operations/storage/nextcloud-degraded.sh --on)"
    continue
  fi

  # A previous failed start latches the unit into `failed`; clear it so this
  # attempt is allowed to run.
  [ "$state" = failed ] && systemctl reset-failed "$u" 2>/dev/null || true

  log "${u} is ${state:-inactive} - starting"
  if systemctl start "$u"; then
    log "${u} started"
    started=$((started + 1))
  else
    warn "${u} failed to start - see: journalctl -u ${u} -n 50"
  fi
done

# --- repair missing port publishes -------------------------------------------
#
# A container can be running and "healthy" while publishing nothing. Docker
# auto-restarts containers at daemon start, and if it does so before NetBird has
# created wt0 it cannot bind 100.64.0.10, so it silently drops the publish.
# Observed YYYY-MM-DD: nginx healthy, nothing listening on 8081, public 502.
#
# `systemctl restart` does NOT fix it. ExecStop is `compose stop`, so a restart
# reuses the existing container with its broken config. Only a recreate repairs it.
#
# The expected ports are read straight out of the compose YAML, deliberately NOT
# via `docker compose config`: that talks to the daemon and took over 100 seconds
# while an image pull was saturating it, which is longer than the timer interval.
# Reading the file is instant and works even when the daemon is busy.
repaired=0
for u in "${UNITS[@]}"; do
  [ "$(systemctl is-active "$u" 2>/dev/null || true)" = active ] || continue
  cf=$(systemctl show "$u" -p ExecStart --value | grep -oE '/[^ ]*docker-compose[^ ]*\.yml' | head -1)
  [ -n "$cf" ] && [ -f "$cf" ] || continue

  missing=$(python3 - "$cf" <<'PYEOF'
import sys, re
# Match the published side of "host_ip:published:target" in a ports: list.
pat = re.compile(r'^\s*-\s*["\']?(\d+\.\d+\.\d+\.\d+):(\d+):\d+')
for line in open(sys.argv[1], errors='replace'):
    m = pat.match(line)
    if m:
        print(m.group(1), m.group(2))
PYEOF
)
  gone=""
  while read -r addr port; do
    [ -n "$port" ] || continue
    ss -ltn 2>/dev/null | grep -q "${addr}:${port} " || gone="${gone} ${addr}:${port}"
  done <<< "$missing"

  if [ -n "$gone" ]; then
    warn "${u} is active but nothing is listening on:${gone} - recreating"
    if docker compose -f "$cf" up -d --force-recreate --wait >/dev/null 2>&1; then
      log "${u} recreated, publishes restored"; repaired=$((repaired + 1))
    else
      warn "${u} recreate failed - see: docker compose -f ${cf} up -d"
    fi
  fi
done

[ "$started" -eq 0 ] && [ "$repaired" -eq 0 ] && log "nothing to do" \
  || log "started ${started} unit(s), repaired ${repaired}"
