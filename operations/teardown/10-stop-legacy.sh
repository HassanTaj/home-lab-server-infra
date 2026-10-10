#!/usr/bin/env bash
# Stop the legacy containers WITHOUT removing anything.
#
# Reversible: every container, volume, network, image and bind path survives.
# This is the step that frees ports 80/443/53 and RAM for the new stack while
# keeping a one-command rollback available.
#
#   rollback:  operations/teardown/10-stop-legacy.sh --start

HOMELAB_LOG_TAG=stop-legacy
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
. "$(dirname "$0")/legacy-objects.sh"

action="${1:---stop}"

case "$action" in
  --stop)
    for c in "${LEGACY_CONTAINERS[@]}"; do
      if docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
        log "stopping ${c}"
        docker stop -t 30 "$c" >/dev/null
      else
        log "${c} already stopped or absent"
      fi
    done
    log "legacy containers stopped. Nothing was removed."
    ;;
  --start)
    for c in "${LEGACY_CONTAINERS[@]}"; do
      # mssql has been intentionally down for months; do not resurrect it.
      [ "$c" = "mssql" ] && continue
      if docker inspect "$c" >/dev/null 2>&1; then
        log "starting ${c}"
        docker start "$c" >/dev/null || warn "could not start ${c}"
      fi
    done
    log "legacy containers restarted"
    ;;
  *)
    die "usage: $0 [--stop|--start]" ;;
esac

docker ps -a --format '  {{.Names}}\t{{.Status}}'
