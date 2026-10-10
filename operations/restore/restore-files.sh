#!/usr/bin/env bash
# Restore files from the Restic repository into an isolated scratch directory.
#
#   restore-files.sh internal [<snapshot>] [<path-to-restore>]
#
# NEVER restores in place. Output always lands under a fresh directory in
# /srv/homelab/backup-staging/restore-<repo>-<timestamp>, so a restore can
# never overwrite live data by accident.

HOMELAB_LOG_TAG=restore-files
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd restic
load_env backup.env

which="${1:-}"
snapshot="${2:-latest}"
subpath="${3:-}"

case "$which" in
  internal) repo="$RESTIC_REPO_INTERNAL"; pass="$RESTIC_PASSWORD_INTERNAL" ;;
  *) die "usage: $0 internal [snapshot] [path]" ;;
esac

verify_data_mounted

target="${HOMELAB_ROOT}/backup-staging/restore-${which}-$(date +%Y%m%dT%H%M%S)"
install -d -o root -g root -m 0700 "$target"

export RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass"

args=(restore "$snapshot" --target "$target")
[ -n "$subpath" ] && args+=(--include "$subpath")

log "restoring ${which} snapshot ${snapshot} -> ${target}"
restic "${args[@]}"

log "restored content:"
find "$target" -maxdepth 4 -printf '    %y %10s %p\n' | head -50
log "restore directory: ${target}"
log "Review it, then delete it manually. Nothing live was touched."
