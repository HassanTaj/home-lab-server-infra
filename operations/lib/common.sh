#!/usr/bin/env bash
# Shared helpers for every Homelab operations script.
#
# Source, do not execute:
#     . "$(dirname "$0")/../lib/common.sh"
#
# Everything here is written to FAIL CLOSED. A check that cannot prove a
# precondition holds must abort rather than continue on an assumption.

set -Eeuo pipefail

readonly HOMELAB_SECRETS_DIR=/etc/homelab
readonly HOMELAB_ROOT=/srv/homelab
readonly DATA_MOUNT=/mnt/data
readonly DATA_MARKER="${DATA_MOUNT}/.homelab-data-marker"
readonly HOMELAB_LOCK=/run/homelab-storage.lock
readonly STORAGE_SSD_BRANCH="${HOMELAB_ROOT}/storage-branches/ssd"
readonly STORAGE_HDD_BRANCH="${DATA_MOUNT}/.homelab/storage-branches/hdd"
readonly STORAGE_SSD_MARKER="${STORAGE_SSD_BRANCH}/.homelab-storage-branch-marker"
readonly STORAGE_HDD_MARKER="${STORAGE_HDD_BRANCH}/.homelab-storage-branch-marker"
readonly STORAGE_POOL=/mnt/storage
readonly STORAGE_POOL_MARKER="${STORAGE_POOL}/.homelab-storage-pool-marker"
readonly HOME_MOUNT=/home
readonly HOME_UUID=DEMO_HOME_FILESYSTEM_UUID

log()  { printf '%s [%s] %s\n' "$(date -Is)" "${HOMELAB_LOG_TAG:-homelab}" "$*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

trap 'die "unhandled error at line $LINENO (exit $?)"' ERR

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# Load a root-owned 0600 environment file from /etc/homelab.
# Refuses to read a file with permissive modes rather than silently accepting it.
load_env() {
  local name="$1" path="${HOMELAB_SECRETS_DIR}/$1"
  [ -f "$path" ] || die "missing secrets file: $path (see runtime/environments/examples/)"
  local mode owner
  mode=$(stat -c '%a' "$path")
  owner=$(stat -c '%U:%G' "$path")
  [ "$mode" = "600" ] || die "$path has mode $mode, expected 600"
  [ "$owner" = "root:root" ] || die "$path is owned by $owner, expected root:root"

  # Parse literally rather than `. "$path"`. Shell sourcing would expand $VAR,
  # `cmd` and backslashes inside a value, silently corrupting any secret that
  # contains them — and Docker's env_file parser does NOT expand, so the
  # container and these scripts would disagree about the password.
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    # Trim optional surrounding quotes, matching Compose's behaviour.
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$path"

  log "loaded ${name}"
}

# Verify the data disk is genuinely mounted at the expected path, is the expected
# filesystem, and carries the marker file. Any failure aborts.
#
# The marker check is the important one: if the disk is absent, the mountpoint is
# an ordinary empty directory on the root filesystem and writing into it would
# silently fill the SSD instead of the data disk.
verify_data_mounted() {
  local expected_uuid="${DATA_UUID:-}"
  [ -n "$expected_uuid" ] || die "DATA_UUID is not set; load backup.env first"

  mountpoint -q "$DATA_MOUNT" \
    || die "$DATA_MOUNT is not a mountpoint - refusing to continue"

  # findmnt returns one row PER stacked mount at this path. The .automount unit
  # keeps an autofs mount underneath the real filesystem, so --target yields two
  # lines ("systemd-1" and "/dev/sdb1") and passing both to blkid resolves to no
  # UUID at all. Discard the autofs row and take the topmost real device.
  # Latent since the unit was written; surfaced YYYY-MM-DD by the /mnt/data rename.
  local src actual_uuid
  src=$(findmnt -nr -o SOURCE,FSTYPE --target "$DATA_MOUNT" \
        | awk '$2 != "autofs" { print $1 }' | tail -1)
  [ -n "$src" ] || die "no real filesystem mounted at $DATA_MOUNT (autofs only)"
  actual_uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
  [ "$actual_uuid" = "$expected_uuid" ] \
    || die "mounted device $src has UUID '${actual_uuid:-none}', expected '$expected_uuid'"

  [ -f "$DATA_MARKER" ] \
    || die "marker $DATA_MARKER absent - mount is not the expected data filesystem"

  log "data disk verified: $src ($expected_uuid) at $DATA_MOUNT"
}

# Confirm the data mountpoint is NOT mounted and is empty. Used before mounting so
# a stale directory full of files never hides underneath the real filesystem.
verify_data_mountpoint_clean() {
  if mountpoint -q "$DATA_MOUNT"; then
    log "$DATA_MOUNT already mounted"
    return 0
  fi
  if [ -d "$DATA_MOUNT" ] && [ -n "$(ls -A "$DATA_MOUNT" 2>/dev/null)" ]; then
    die "$DATA_MOUNT is unmounted but not empty - refusing to mount over local data"
  fi
  return 0
}

# Serialise every storage-touching job through one lock. Backups, checks, restore
# drills and teardown must never interleave.
with_storage_lock() {
  exec 9>"$HOMELAB_LOCK"
  flock -n 9 || die "another storage job holds $HOMELAB_LOCK"
  log "acquired storage lock"
}

# Abort if free space on a path is under the given threshold in GiB.
require_free_gib() {
  local path="$1" need="$2" avail
  avail=$(df -BG --output=avail "$path" | tail -1 | tr -dc '0-9')
  [ -n "$avail" ] || die "cannot determine free space on $path"
  [ "$avail" -ge "$need" ] \
    || die "only ${avail}GiB free on $path, need at least ${need}GiB"
  log "free space on $path: ${avail}GiB (>= ${need}GiB)"
}

compose_file_for() {
  local project="$1"
  local repo_root
  repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  printf '%s/runtime/compose/%s/docker-compose.yml' "$repo_root" "$project"
}
