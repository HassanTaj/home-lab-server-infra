#!/usr/bin/env bash
# Restore a PostgreSQL dump into an ISOLATED scratch database.
#
#   restore-database.sh <dump-file> [scratch-db-name]
#
# The scratch database is created fresh and dropped only by the operator. The
# live database is never touched, so this is safe to run against production.

HOMELAB_LOG_TAG=restore-db
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
load_env databases.env

dump="${1:-}"
scratch="${2:-restore_scratch_$(date +%Y%m%d%H%M%S)}"
[ -n "$dump" ] && [ -f "$dump" ] || die "usage: $0 <dump-file> [scratch-db-name]"

case "$scratch" in
  "$NEXTCLOUD_DB_NAME"|postgres|template0|template1)
    die "refusing to restore over live database '$scratch'" ;;
esac

CT=homelab-postgres
docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true \
  || die "$CT is not running"

pg() { docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$CT" "$@"; }

log "creating scratch database ${scratch}"
pg psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -c "CREATE DATABASE \"${scratch}\" ENCODING 'UTF8'"

log "restoring ${dump} into ${scratch}"
pg pg_restore -U "$POSTGRES_USER" -d "$scratch" --no-owner --no-privileges < "$dump"

log "verifying restored content"
pg psql -tAX -U "$POSTGRES_USER" -d "$scratch" -c \
  "SELECT count(*) || ' tables in public schema' FROM information_schema.tables WHERE table_schema='public'"
pg psql -tAX -U "$POSTGRES_USER" -d "$scratch" -c \
  "SELECT pg_size_pretty(pg_database_size('${scratch}')) || ' restored size'"

log "scratch database ${scratch} is ready for inspection"
log "drop it when finished:  docker exec -i ${CT} psql -U ${POSTGRES_USER} -d postgres -c 'DROP DATABASE \"${scratch}\"'"
