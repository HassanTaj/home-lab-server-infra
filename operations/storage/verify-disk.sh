#!/usr/bin/env bash
# Verify the data disk is correctly mounted. Exits non-zero if it is not.
#
# This is the gate that every storage-touching unit depends on. It is
# deliberately cheap so it can run before each backup and before the Compose
# launcher starts Nextcloud.

HOMELAB_LOG_TAG=verify-disk
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd findmnt blkid mountpoint
load_env backup.env
verify_data_mounted

# The Homelab area must exist on the data filesystem itself. It is named with a
# leading dot so Nextcloud hides it: the whole disk is exposed as an external
# storage, and the Restic repository inside must not show up as a browsable
# folder for anyone in the data-shared group.
[ -d "${DATA_MOUNT}/.homelab/backups" ] \
  || die "${DATA_MOUNT}/.homelab/backups missing - run operations/storage/init-disk-layout.sh"

log "data disk OK"
