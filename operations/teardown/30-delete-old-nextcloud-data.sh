#!/usr/bin/env bash
# Delete ONLY the two approved legacy Nextcloud data paths.
#
#   /srv/legacy/nextcloud-data
#   /srv/docker/data/nextcloud
#
# IRREVERSIBLE. Preconditions, all enforced:
#   - the new stack is running,
#   - both Restic repositories hold a recent verified snapshot,
#   - a restore drill has passed,
#   - the operator supplies the confirmation phrase.
#
# Every other file under /srv/docker is preserved.
#
#   30-delete-old-nextcloud-data.sh --dry-run   (default)
#   30-delete-old-nextcloud-data.sh --confirm DELETE-OLD-NEXTCLOUD-DATA

HOMELAB_LOG_TAG=delete-old-nc
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker restic
. "$(dirname "$0")/legacy-objects.sh"
load_env backup.env

mode=dry
if [ "${1:-}" = "--confirm" ]; then
  [ "${2:-}" = "DELETE-OLD-NEXTCLOUD-DATA" ] || die "confirmation phrase mismatch"
  mode=live
fi
log "mode: ${mode}"

# --- precondition: new stack healthy ---------------------------------------
docker inspect -f '{{.State.Running}}' homelab-nextcloud 2>/dev/null | grep -q true \
  || die "homelab-nextcloud is not running"

# --- precondition: recent verified snapshots -------------------------------
verify_data_mounted
for pair in "internal:${RESTIC_REPO_INTERNAL}:${RESTIC_PASSWORD_INTERNAL}"; do
  name=${pair%%:*}; rest=${pair#*:}; repo=${rest%%:*}; pass=${rest#*:}
  latest=$(RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
    restic snapshots --latest 1 --json 2>/dev/null | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$latest" ] || die "${name} repository has no snapshots"
  age_days=$(( ( $(date +%s) - $(date -d "$latest" +%s) ) / 86400 ))
  [ "$age_days" -le 2 ] || die "${name} newest snapshot is ${age_days} days old (need <= 2)"
  log "OK    ${name} snapshot ${latest} (${age_days}d old)"
done

# --- precondition: restore drill passed ------------------------------------
drill_result=$(systemctl show -p Result --value homelab-restore-drill.service 2>/dev/null || echo unknown)
[ "$drill_result" = "success" ] \
  || die "homelab-restore-drill.service last result is '${drill_result}', expected 'success'"
log "OK    restore drill has passed"

# --- delete ----------------------------------------------------------------
for p in "${LEGACY_DELETE_PATHS[@]}"; do
  # Resolve immediately before deletion and re-check the literal path.
  real=$(readlink -f "$p" 2>/dev/null || true)
  if [ -z "$real" ] || [ ! -e "$real" ]; then
    log "${p} already absent"
    continue
  fi
  case "$real" in
    /srv/legacy/nextcloud-data|/srv/docker/data/nextcloud) ;;
    *) die "${p} resolves to unexpected path ${real} - refusing" ;;
  esac
  size=$(du -sh "$real" | cut -f1)
  log "deleting ${real} (${size})"
  if [ "$mode" = live ]; then rm -rf --one-file-system "$real"; else log "DRY-RUN: rm -rf ${real}"; fi
done

log "verifying /srv/docker survivors"
find /srv/docker -maxdepth 2 -mindepth 1 -printf '    %p\n' | sort
log "done (${mode})"
