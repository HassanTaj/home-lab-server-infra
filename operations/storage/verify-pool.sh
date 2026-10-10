#!/usr/bin/env bash
# Verify both mergerfs branches and the mounted pool before bulk-data services start.
HOMELAB_LOG_TAG=verify-pool
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd findmnt blkid mountpoint stat
load_env backup.env
verify_data_mounted

home_src=$(findmnt -nr -o SOURCE,FSTYPE --target "$HOME_MOUNT" \
  | awk '$2 != "autofs" { print $1 }' | tail -1)
home_fstype=$(findmnt -nr -o FSTYPE --target "$HOME_MOUNT" \
  | awk '$1 != "autofs" { print $1 }' | tail -1)
home_uuid=$(blkid -s UUID -o value "$home_src" 2>/dev/null || true)
[ "$home_uuid" = "$HOME_UUID" ] || die "home filesystem UUID '$home_uuid', expected $HOME_UUID"
[ "$home_fstype" = "ext4" ] || die "home filesystem type '$home_fstype', expected ext4"

[ -d "$STORAGE_SSD_BRANCH" ] || die "SSD branch missing: $STORAGE_SSD_BRANCH"
[ -f "$STORAGE_SSD_MARKER" ] || die "SSD branch marker missing: $STORAGE_SSD_MARKER"
grep -q '^homelab-storage-branch ssd$' "$STORAGE_SSD_MARKER" || die "SSD branch marker is not for the ssd role"

[ -d "$STORAGE_HDD_BRANCH" ] || die "HDD branch missing: $STORAGE_HDD_BRANCH"
[ -f "$STORAGE_HDD_MARKER" ] || die "HDD branch marker missing: $STORAGE_HDD_MARKER"
grep -q '^homelab-storage-branch hdd$' "$STORAGE_HDD_MARKER" || die "HDD branch marker is not for the hdd role"
grep -q "^filesystem $DATA_UUID$" "$STORAGE_HDD_MARKER" || die "HDD branch marker UUID does not match DATA_UUID"

mountpoint -q "$STORAGE_POOL" || die "$STORAGE_POOL is not a mountpoint"
pool_fstype=$(findmnt -nr -o FSTYPE --target "$STORAGE_POOL" | tail -1)
[ "$pool_fstype" = "fuse.mergerfs" ] || die "$STORAGE_POOL has filesystem type '$pool_fstype', expected fuse.mergerfs"
[ -f "$STORAGE_POOL_MARKER" ] || die "pool marker missing: $STORAGE_POOL_MARKER"
grep -q '^homelab-storage-pool$' "$STORAGE_POOL_MARKER" || die "pool marker has unexpected content"

log "storage pool verified: $STORAGE_POOL (ssd + hdd branches, reserves 200G/50G)"
