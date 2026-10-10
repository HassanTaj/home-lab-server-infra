#!/usr/bin/env bash
# Synchronize one Immich external-library path into a real album.
# Run after clicking Scan for the external library. Dry-run is the default.
HOMELAB_LOG_TAG=immich-folder-album
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd curl jq
load_env immich-album-sync.env
IMMICH_URL=$(printenv IMMICH_URL 2>/dev/null || true)
[ -n "$IMMICH_URL" ] || IMMICH_URL=http://100.64.0.10:2283/api
IMMICH_API_KEY=$(printenv IMMICH_API_KEY 2>/dev/null || true)
IMMICH_LIBRARY_ID=$(printenv IMMICH_LIBRARY_ID 2>/dev/null || true)
[ -n "$IMMICH_API_KEY" ] || die "IMMICH_API_KEY is not set"
[ -n "$IMMICH_LIBRARY_ID" ] || die "IMMICH_LIBRARY_ID is not set (configure it after creating the external library)"
IMMICH_ALBUM_NAME=$(printenv IMMICH_ALBUM_NAME 2>/dev/null || true)
[ -n "$IMMICH_ALBUM_NAME" ] || IMMICH_ALBUM_NAME='Example Album'
APPLY=0
[ "$#" -eq 0 ] || [ "$1" = "--apply" ] || die "usage: $0 [--apply]"
[ "$#" -eq 1 ] && APPLY=1

api() {
  curl -fsS --retry 2 --connect-timeout 5 --max-time 60 \
    -H "x-api-key: $IMMICH_API_KEY" -H 'Content-Type: application/json' "$@"
}

page=1
assets='[]'
while :; do
  body=$(jq -n --arg id "$IMMICH_LIBRARY_ID" --argjson page "$page" \
    '{libraryId:$id,size:1000,page:$page,order:"asc"}')
  response=$(api -X POST "$IMMICH_URL/search/metadata" -d "$body")
  items=$(jq -c '.assets.items // []' <<<"$response")
  assets=$(jq -c --argjson more "$items" --argjson old "$assets" '$old + $more' <<<"null")
  next=$(jq -r '.assets.nextPage // empty' <<<"$response")
  [ -n "$next" ] || break
  page=$next
done
asset_ids=$(jq -c '[.[].id] | unique' <<<"$assets")
asset_count=$(jq 'length' <<<"$asset_ids")
[ "$asset_count" -gt 0 ] || die "no assets found for external library $IMMICH_LIBRARY_ID; scan the library first"

albums=$(api -G "$IMMICH_URL/albums" --data-urlencode "name=$IMMICH_ALBUM_NAME")
album_id=$(jq -r --arg n "$IMMICH_ALBUM_NAME" '.[] | select(.albumName == $n) | .id' <<<"$albums" | head -1)
if [ -z "$album_id" ]; then
  if [ "$APPLY" -eq 0 ]; then
    log "DRY-RUN create album: $IMMICH_ALBUM_NAME"
  else
    album_id=$(api -X POST "$IMMICH_URL/albums" \
      -d "$(jq -n --arg n "$IMMICH_ALBUM_NAME" '{albumName:$n}')" | jq -r '.id')
    [ -n "$album_id" ] && [ "$album_id" != "null" ] || die "Immich album creation returned no id"
    log "created album: $IMMICH_ALBUM_NAME ($album_id)"
  fi
fi

if [ -z "$album_id" ]; then
  log "DRY-RUN would add $asset_count external assets to $IMMICH_ALBUM_NAME"
  exit 0
fi

album=$(api "$IMMICH_URL/albums/$album_id")
current_ids=$(jq -c '[.assets[]?.id] | unique' <<<"$album")
add_ids=$(jq -c --argjson want "$asset_ids" --argjson have "$current_ids" '$want - $have' <<<"null")
remove_ids=$(jq -c --argjson want "$asset_ids" --argjson have "$current_ids" '$have - $want' <<<"null")
add_count=$(jq 'length' <<<"$add_ids")
remove_count=$(jq 'length' <<<"$remove_ids")
log "album $IMMICH_ALBUM_NAME: $asset_count desired, $add_count to add, $remove_count stale"

if [ "$APPLY" -eq 1 ]; then
  [ "$add_count" -eq 0 ] || api -X PUT "$IMMICH_URL/albums/$album_id/assets" \
    -d "$(jq -n --argjson ids "$add_ids" '{ids:$ids}')" >/dev/null
  [ "$remove_count" -eq 0 ] || api -X DELETE "$IMMICH_URL/albums/$album_id/assets" \
    -d "$(jq -n --argjson ids "$remove_ids" '{ids:$ids}')" >/dev/null
  log "album membership synchronized; source files were not modified"
else
  log "DRY-RUN no album membership changes made"
fi
