#!/usr/bin/env bash
# Create one Jellyfin music-video library per immediate Tutorials directory.
# Dry-run is the default; --apply is required for API changes.
HOMELAB_LOG_TAG=jellyfin-tutorial-libraries
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd curl jq find stat
JELLYFIN_URL=$(printenv JELLYFIN_URL 2>/dev/null || true)
[ -n "$JELLYFIN_URL" ] || JELLYFIN_URL=http://100.64.0.10:8096
API_KEY_FILE=$(printenv JELLYFIN_API_KEY_FILE 2>/dev/null || true)
[ -n "$API_KEY_FILE" ] || API_KEY_FILE=/etc/homelab/jellyfin-api-key
TUTORIALS_HOST=$(printenv TUTORIALS_HOST 2>/dev/null || true)
[ -n "$TUTORIALS_HOST" ] || TUTORIALS_HOST=/mnt/data/Tutorials
TUTORIALS_CONTAINER=$(printenv TUTORIALS_CONTAINER 2>/dev/null || true)
[ -n "$TUTORIALS_CONTAINER" ] || TUTORIALS_CONTAINER=/media/Tutorials
APPLY=0
[ "$#" -eq 0 ] || [ "$1" = "--apply" ] || die "usage: $0 [--apply]"
[ "$#" -eq 1 ] && APPLY=1
[ -r "$API_KEY_FILE" ] || die "missing Jellyfin API key file: $API_KEY_FILE"
mode=$(stat -c '%a' "$API_KEY_FILE"); owner=$(stat -c '%U:%G' "$API_KEY_FILE")
[ "$mode" = "600" ] || die "$API_KEY_FILE has mode $mode, expected 600"
[ "$owner" = "root:root" ] || die "$API_KEY_FILE is owned by $owner, expected root:root"
[ -d "$TUTORIALS_HOST" ] || die "Tutorials path missing: $TUTORIALS_HOST"
api_key=$(<"$API_KEY_FILE")
[ -n "$api_key" ] || die "Jellyfin API key file is empty"

api() {
  curl -fsS --retry 2 --connect-timeout 5 --max-time 30 \
    -H "X-Emby-Token: $api_key" "$@"
}
subjects=$(find "$TUTORIALS_HOST" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V)
existing=$(api "$JELLYFIN_URL/Library/VirtualFolders")
subject_count=$(printf '%s\n' "$subjects" | sed '/^$/d' | wc -l)
[ "$subject_count" -gt 0 ] || die "no tutorial subject directories under $TUTORIALS_HOST"
log "found $subject_count tutorial subject directories (root ZIP files ignored)"

created=0
while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  path="$TUTORIALS_CONTAINER/$subject"
  matches=$(jq -r --arg n "$subject" '.[] | select(.Name == $n) | .Locations[]?' <<<"$existing")
  if [ -n "$matches" ]; then
    printf '%s\n' "$matches" | grep -Fxq "$path" \
      || die "existing Jellyfin library '$subject' has wrong path (expected $path)"
    log "OK existing: $subject -> $path"
    continue
  fi
  if [ "$APPLY" -eq 0 ]; then
    log "DRY-RUN create: $subject -> $path (musicvideos)"
    continue
  fi
  curl -fsS --retry 2 --connect-timeout 5 --max-time 30 -X POST \
    -H "X-Emby-Token: $api_key" \
    --get "$JELLYFIN_URL/Library/VirtualFolders" \
    --data-urlencode "name=$subject" \
    --data-urlencode "collectionType=musicvideos" \
    --data-urlencode "paths=$path" \
    --data-urlencode "refreshLibrary=false" >/dev/null
  created=$((created + 1))
  log "created: $subject -> $path"
done <<< "$subjects"

if [ "$APPLY" -eq 1 ] && [ "$created" -gt 0 ]; then
  api -X POST "$JELLYFIN_URL/Library/Refresh" >/dev/null
  log "requested one global Jellyfin library refresh"
fi
log "tutorial library sync complete (created $created)"
