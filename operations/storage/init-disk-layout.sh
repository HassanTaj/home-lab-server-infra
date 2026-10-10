#!/usr/bin/env bash
# Create the Homelab directories on the data disk and drop the marker file.
#
# PRESERVES ALL EXISTING EXISTING CONTENT. This script only ever creates new paths
# under /mnt/data/.homelab. It never formats, repartitions, or deletes.
#
# Run once, after the mount unit is active.

HOMELAB_LOG_TAG=init-disk-layout
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd findmnt blkid mountpoint
load_env backup.env

mountpoint -q "$DATA_MOUNT" || die "$DATA_MOUNT is not mounted"

# UUID must match before we write anything at all.
# Discard the autofs row the .automount unit stacks under the real mount.
src=$(findmnt -nr -o SOURCE,FSTYPE --target "$DATA_MOUNT" \
      | awk '$2 != "autofs" { print $1 }' | tail -1)
actual_uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
[ "$actual_uuid" = "$DATA_UUID" ] \
  || die "mounted device $src has UUID '${actual_uuid:-none}', expected '$DATA_UUID'"

log "existing top-level top-level entries (all preserved):"
ls -1 "$DATA_MOUNT" | sed 's/^/    /'

# Dot-prefixed so Nextcloud hides it: the entire disk is published as an
# external storage, and the Restic repository must not be browsable by users.
# Root-owned 0700 as a second layer, so www-data cannot read it either.
mkdir -p "${DATA_MOUNT}/.homelab/backups/internal"
chown 0:0 "${DATA_MOUNT}/.homelab"
chmod 0700 "${DATA_MOUNT}/.homelab"
# This is the only new path created on the existing NTFS archive. It is a
# dedicated mergerfs branch; all pre-existing content remains outside the pool.
mkdir -p "${DATA_MOUNT}/.homelab/storage-branches/hdd"
chown 0:0 "${DATA_MOUNT}/.homelab/storage-branches/hdd"
chmod 0700 "${DATA_MOUNT}/.homelab/storage-branches/hdd"
if [ ! -f "$STORAGE_HDD_MARKER" ]; then
  printf 'homelab-storage-branch hdd\nfilesystem %s\n' "$DATA_UUID" > "$STORAGE_HDD_MARKER"
fi
chown 0:0 "$STORAGE_HDD_MARKER"
chmod 0644 "$STORAGE_HDD_MARKER"

if [ ! -f "$DATA_MARKER" ]; then
  printf 'homelab-data %s\ncreated %s\n' "$DATA_UUID" "$(date -Is)" > "$DATA_MARKER"
  log "wrote marker $DATA_MARKER"
else
  log "marker already present"
fi

log "disk layout ready. Nothing pre-existing was modified."
