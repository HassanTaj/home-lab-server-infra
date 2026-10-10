#!/usr/bin/env bash
# Create the deterministic host directory layout. Idempotent.

HOMELAB_LOG_TAG=directories
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root

install -d -o root -g root -m 0700 "$HOMELAB_SECRETS_DIR"

install -d -o root -g root -m 0755 "$HOMELAB_ROOT"
install -d -o root -g root -m 0755 "${HOMELAB_ROOT}/appdata"

# Each bind mount must be owned by the UID its container actually runs as.
# These are the in-image accounts, verified against the pinned digests:
#   postgres 999:999   pgadmin 5050:0 (root group)   nextcloud www-data 33:33
# Portainer runs as root and needs no adjustment.
#
# chown rather than `install -o`: these UIDs exist inside the images, not
# necessarily on the host, and `install` rejects an unknown owner.
own_dir() {  # own_dir <path> <uid> <gid> <mode>
  mkdir -p "$1"
  chown "$2:$3" "$1"
  chmod "$4" "$1"
}

own_dir "${HOMELAB_ROOT}/appdata/postgres"  999  999 0750
own_dir "${HOMELAB_ROOT}/appdata/pgadmin"   5050 0   0750
own_dir "${HOMELAB_ROOT}/appdata/nextcloud" 33   33  0750
own_dir "${HOMELAB_ROOT}/appdata/portainer" 0    0   0750
own_dir "${HOMELAB_ROOT}/appdata/pihole"    1000 1000 0750

# Nextcloud primary storage stays on the internal ext4 partition.
own_dir "${HOMELAB_ROOT}/nextcloud-data"    33   33  0750
# Immich managed originals are kept on the visible native SSD path. The old
# appdata/immich/library tree is retained separately during the rollback window.
own_dir "${HOMELAB_ROOT}/immich-data" 0 0 0755
for d in upload library; do
  own_dir "${HOMELAB_ROOT}/immich-data/$d" 0 0 0755
done
for d in thumbs encoded-video profile backups; do
  own_dir "${HOMELAB_ROOT}/appdata/immich/generated/$d" 0 0 0755
done
# Dedicated SSD mergerfs branch. Never point mergerfs at /home itself.
own_dir "${HOMELAB_ROOT}/storage-branches" 0 0 0755
own_dir "${HOMELAB_ROOT}/storage-branches/ssd" 33 33 0770
if [ ! -f "${HOMELAB_ROOT}/storage-branches/ssd/.homelab-storage-branch-marker" ]; then
  printf 'homelab-storage-branch ssd\n' > "${HOMELAB_ROOT}/storage-branches/ssd/.homelab-storage-branch-marker"
fi
chown root:root "${HOMELAB_ROOT}/storage-branches/ssd/.homelab-storage-branch-marker"
chmod 0644 "${HOMELAB_ROOT}/storage-branches/ssd/.homelab-storage-branch-marker"

# Group-restricted share on the INTERNAL disk, attached to Nextcloud as external
# storage alongside the data disk so the two can be assigned to different people.
own_dir "${HOMELAB_ROOT}/shared-internal"   33   33  0770

# Database dumps land here before Restic ingests them.
install -d -o root -g root -m 0700 "${HOMELAB_ROOT}/backup-staging"

# Reserved for future Restic repositories on the internal SSD. The data disk is
# deliberately NOT backed up (deployment configuration), so nothing lives here
# yet.
install -d -o root -g root -m 0700 "${HOMELAB_ROOT}/backups"

# The data mountpoint must exist and stay empty while the disk is absent.
install -d -o root -g root -m 0755 "$DATA_MOUNT"
verify_data_mountpoint_clean

log "directory layout ready"
find "$HOMELAB_ROOT" -maxdepth 2 -type d -printf '    %M %u:%g %p\n' | sort -k4
