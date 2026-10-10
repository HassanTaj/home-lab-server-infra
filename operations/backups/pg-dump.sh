#!/usr/bin/env bash
# Produce compressed logical dumps of every application database plus globals
# into the staging directory.
#
# Dumps are written to a temporary name and renamed only on success, so a
# partial dump can never be mistaken for a complete one.

HOMELAB_LOG_TAG=pg-dump
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
load_env databases.env

CT=homelab-postgres
STAGING="${HOMELAB_ROOT}/backup-staging"
install -d -o root -g root -m 0700 "$STAGING"

docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true \
  || die "$CT is not running"

pg() { docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$CT" "$@"; }

# Clear only completed dumps from the previous run. Anything left behind by a
# FAILED run is preserved for inspection (*.partial is never deleted here).
find "$STAGING" -maxdepth 1 -name '*.sql.gz' -delete

log "dumping globals"
pg pg_dumpall -U "$POSTGRES_USER" --globals-only \
  | gzip -9 > "${STAGING}/globals.sql.gz.partial"
mv "${STAGING}/globals.sql.gz.partial" "${STAGING}/globals.sql.gz"

mapfile -t dbs < <(pg psql -tAX -U "$POSTGRES_USER" -d postgres \
  -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'")

[ "${#dbs[@]}" -gt 0 ] || warn "no application databases found"

for db in "${dbs[@]}"; do
  [ -n "$db" ] || continue
  log "dumping ${db}"
  pg pg_dump -U "$POSTGRES_USER" --format=custom --compress=9 "$db" \
    > "${STAGING}/${db}.dump.partial"
  mv "${STAGING}/${db}.dump.partial" "${STAGING}/${db}.dump"
done

# Record what a restore is allowed to expect.
{
  printf 'generated %s\n' "$(date -Is)"
  printf 'server %s\n' "$(pg psql -tAX -U "$POSTGRES_USER" -d postgres -c 'SHOW server_version')"
  printf 'databases %s\n' "${dbs[*]}"
} > "${STAGING}/MANIFEST"

log "dumps complete:"
ls -lh "$STAGING" | sed 's/^/    /'
