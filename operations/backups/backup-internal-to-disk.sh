#!/usr/bin/env bash
# Internal application state, config, Nextcloud data and database dumps
#   -> encrypted Restic repository on the data disk.
#
# Fails closed if the data disk is absent or is not the expected filesystem.

HOMELAB_LOG_TAG=backup-internal
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd restic docker findmnt blkid
load_env backup.env

with_storage_lock
verify_data_mounted
require_free_gib "$DATA_MOUNT" 20

export RESTIC_REPOSITORY="$RESTIC_REPO_INTERNAL"
export RESTIC_PASSWORD="$RESTIC_PASSWORD_INTERNAL"

if ! restic cat config >/dev/null 2>&1; then
  log "initialising repository $RESTIC_REPOSITORY"
  restic init
fi

# Fresh logical dumps first; a data backup without a matching dump is not useful.
"$(dirname "$0")/pg-dump.sh"

EXCLUDES=(
  # Never back a repository up into itself.
  --exclude "$RESTIC_REPO_INTERNAL"
  # Regenerable Nextcloud state.
  --exclude "${HOMELAB_ROOT}/nextcloud-data/appdata_*/preview"
  --exclude "${HOMELAB_ROOT}/appdata/nextcloud/html/data/*/cache"
  --exclude "${HOMELAB_ROOT}/nextcloud-data/*/cache"
  --exclude "${HOMELAB_ROOT}/nextcloud-data/*/uploads"
  --exclude "${HOMELAB_ROOT}/appdata/pgadmin/sessions"
  # Live cluster files: the logical dumps are the supported restore path.
  --exclude "${HOMELAB_ROOT}/appdata/postgres"
  # Pool bulk data is replaceable and remains outside the internal backup set.
  --exclude "${HOMELAB_ROOT}/storage-branches"
  # Residue from a previously failed dump.
  --exclude "*.partial"
  --exclude-caches
)

# legacy-archive holds tarballs of retired trees that exist nowhere else --
  # /srv/docker was archived there on an earlier deployment before deletion. It contains
  # private keys (the old self-signed Nextcloud cert, Portainer's TLS key), so it
  # is 0600 root-owned and must never be committed to Git. Restic encrypts it at
  # rest, which is why it lives here rather than in the repo.
  log "backing up internal data to $RESTIC_REPOSITORY"
restic backup \
  --tag internal \
  --host homelab \
  "${EXCLUDES[@]}" \
  "${HOMELAB_ROOT}/appdata" \
  "${HOMELAB_ROOT}/immich-data" \
  "${HOMELAB_ROOT}/shared-internal" \
  "${HOMELAB_ROOT}/nextcloud-data" \
  "${HOMELAB_ROOT}/backup-staging" \
    "${HOMELAB_ROOT}/legacy-archive"

log "verifying newest snapshot"
restic check --read-data-subset=2% \
  || die "verification failed - NOT pruning, repository left intact for inspection"

log "applying retention ${RETENTION_DAILY}d/${RETENTION_WEEKLY}w/${RETENTION_MONTHLY}m"
restic forget \
  --tag internal \
  --keep-daily "$RETENTION_DAILY" \
  --keep-weekly "$RETENTION_WEEKLY" \
  --keep-monthly "$RETENTION_MONTHLY" \
  --prune

restic snapshots --tag internal --latest 3
log "internal backup complete"
