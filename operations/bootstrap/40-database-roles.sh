#!/usr/bin/env bash
# Create the least-privilege Nextcloud role and database inside the shared
# PostgreSQL instance. Idempotent.
#
# Future applications get their own role and database here rather than reusing
# the Nextcloud credentials.

HOMELAB_LOG_TAG=db-roles
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
load_env databases.env

CT=homelab-postgres
docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true \
  || die "$CT is not running; start the databases project first"

psql_admin() {
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$CT" \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres "$@"
}

if psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='${NEXTCLOUD_DB_USER}'" | grep -q 1; then
  log "role ${NEXTCLOUD_DB_USER} exists; updating password"
  psql_admin -c "ALTER ROLE \"${NEXTCLOUD_DB_USER}\" WITH LOGIN PASSWORD '${NEXTCLOUD_DB_PASSWORD}'"
else
  psql_admin -c "CREATE ROLE \"${NEXTCLOUD_DB_USER}\" WITH LOGIN PASSWORD '${NEXTCLOUD_DB_PASSWORD}'"
  log "created role ${NEXTCLOUD_DB_USER}"
fi

if psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='${NEXTCLOUD_DB_NAME}'" | grep -q 1; then
  log "database ${NEXTCLOUD_DB_NAME} exists"
else
  psql_admin -c "CREATE DATABASE \"${NEXTCLOUD_DB_NAME}\" OWNER \"${NEXTCLOUD_DB_USER}\" ENCODING 'UTF8'"
  log "created database ${NEXTCLOUD_DB_NAME}"
fi

# Deny the rest of the cluster to this role.
psql_admin -c "REVOKE ALL ON DATABASE \"${NEXTCLOUD_DB_NAME}\" FROM PUBLIC"
psql_admin -c "GRANT ALL ON DATABASE \"${NEXTCLOUD_DB_NAME}\" TO \"${NEXTCLOUD_DB_USER}\""

log "database roles ready"
