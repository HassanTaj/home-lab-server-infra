#!/usr/bin/env bash
# Remove the exact legacy Docker containers, volumes, networks and images.
#
# IRREVERSIBLE for the named volumes. Run only after the new stack has passed
# the acceptance suite AND a successful restore drill.
#
# Never uses docker system prune. Only the names in legacy-objects.sh are
# touched. Requires an explicit confirmation phrase.
#
#   20-remove-legacy-objects.sh --dry-run     (default)
#   20-remove-legacy-objects.sh --confirm REMOVE-LEGACY

HOMELAB_LOG_TAG=remove-legacy
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
. "$(dirname "$0")/legacy-objects.sh"

mode=dry
if [ "${1:-}" = "--confirm" ]; then
  [ "${2:-}" = "REMOVE-LEGACY" ] || die "confirmation phrase mismatch"
  mode=live
fi
log "mode: ${mode}"

run() {
  if [ "$mode" = live ]; then "$@"; else log "DRY-RUN: $*"; fi
}

# --- guard: the new stack must be healthy before the old one is destroyed ----
for c in homelab-postgres homelab-nextcloud homelab-portainer; do
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true \
    || die "new stack container ${c} is not running - refusing to remove legacy objects"
done
log "new stack verified running"

# --- containers -------------------------------------------------------------
for c in "${LEGACY_CONTAINERS[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    if docker inspect -f '{{.State.Running}}' "$c" | grep -q true; then
      die "${c} is still running - run 10-stop-legacy.sh first"
    fi
    log "removing container ${c}"
    run docker rm "$c"
  fi
done

# --- volumes ----------------------------------------------------------------
for v in "${LEGACY_VOLUMES[@]}"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    log "removing volume ${v}"
    run docker volume rm "$v"
  fi
done

# --- networks ---------------------------------------------------------------
for n in "${LEGACY_NETWORKS[@]}"; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    attached=$(docker network inspect -f '{{len .Containers}}' "$n")
    if [ "$attached" != "0" ]; then
      warn "network ${n} still has ${attached} attached container(s) - skipping"
      continue
    fi
    log "removing network ${n}"
    run docker network rm "$n"
  fi
done

# --- images -----------------------------------------------------------------
# Removed by exact reference. Images still referenced by a surviving container
# are skipped by the daemon rather than forced.
for i in "${LEGACY_IMAGES[@]}"; do
  if docker image inspect "$i" >/dev/null 2>&1; then
    log "removing image ${i}"
    run docker image rm "$i" || warn "image ${i} still in use - left in place"
  fi
done

log "done (${mode}). /srv/docker files are untouched by this script."
