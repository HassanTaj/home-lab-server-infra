#!/usr/bin/env bash
# Monthly restore drill: prove both repositories can actually give data back.
#
# 1. Restore a representative file from each repository into scratch space.
# 2. Restore the Nextcloud database dump into an isolated scratch database.
# 3. Report, then clean up its own scratch artefacts.
#
# A drill that cannot complete is a backup failure, not a drill failure.

HOMELAB_LOG_TAG=restore-drill
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd restic docker
load_env backup.env
load_env databases.env

with_storage_lock
verify_data_mounted

STAMP=$(date +%Y%m%dT%H%M%S)
WORK="${HOMELAB_ROOT}/backup-staging/drill-${STAMP}"
install -d -o root -g root -m 0700 "$WORK"
fail=0

drill_repo() {
  local name="$1" repo="$2" pass="$3"
  log "--- drill: ${name} ---"
  export RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass"

  if ! restic snapshots --latest 1 >/dev/null 2>&1; then
    warn "FAIL  ${name}: no snapshots available"; fail=1; return
  fi

  # How many REGULAR FILES does the snapshot hold? A legitimately empty dataset
  # must restore zero files and still pass — asserting "> 0" unconditionally
  # reports a backup failure for a directory that is simply empty, which is a
  # false alarm that trains you to ignore drill output.
  #
  # `restic stats` is the wrong source here: --mode restore-size counts directory
  # entries too, and --mode files-by-contents counts the shared empty-content
  # blob as 1. Both report a non-zero count for a snapshot containing no files.
  # Counting type=="file" entries is the only figure that matches what a restore
  # actually writes.
  local expected
  expected=$(restic ls --json latest 2>/dev/null \
    | grep -c '"type":"file"' || true)
  expected=${expected:-0}

  local out="${WORK}/${name}"
  install -d -m 0700 "$out"
  if ! restic restore latest --target "$out" >/dev/null 2>&1; then
    warn "FAIL  ${name}: restic restore failed"; fail=1; return
  fi

  local n bytes
  n=$(find "$out" -type f | wc -l)
  bytes=$(du -sb "$out" | cut -f1)

  if [ "$expected" -eq 0 ]; then
    log "OK    ${name}: snapshot is empty (0 files); restore correctly produced none"
    log "      NOTE: this repository holds no data yet, so it proves only that the"
    log "      repository is readable — not that real data can be recovered."
  elif [ "$n" -ge "$expected" ] && [ "$bytes" -gt 0 ]; then
    log "OK    ${name}: restored ${n}/${expected} files (${bytes} bytes)"
  else
    warn "FAIL  ${name}: restored ${n} files, snapshot claims ${expected}"; fail=1
  fi
}

drill_repo internal "$RESTIC_REPO_INTERNAL" "$RESTIC_PASSWORD_INTERNAL"

log "--- drill: database ---"
dump=$(find "${WORK}/internal" -name "${NEXTCLOUD_DB_NAME}.dump" -print -quit 2>/dev/null || true)
if [ -n "$dump" ]; then
  scratch="drill_${STAMP}"
  if "$(dirname "$0")/restore-database.sh" "$dump" "$scratch" >/dev/null 2>&1; then
    log "OK    database restored into ${scratch}"
    docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" homelab-postgres \
      psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE \"${scratch}\"" >/dev/null
    log "      scratch database dropped"
  else
    warn "FAIL  database restore failed"; fail=1
  fi
else
  warn "FAIL  no ${NEXTCLOUD_DB_NAME}.dump found in the internal snapshot"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  rm -rf "$WORK"
  log "restore drill PASSED - scratch cleaned up"
else
  warn "restore drill FAILED - evidence preserved at ${WORK}"
  exit 1
fi
