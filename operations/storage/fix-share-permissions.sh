#!/usr/bin/env bash
# Make files dropped into a Nextcloud share readable and writable by Nextcloud,
# then tell Nextcloud they exist.
#
# WHY THIS EXISTS
# Nextcloud runs as www-data (uid 33). Anything copied in as root or admin keeps
# the copier's ownership, and a 0770 directory grants nothing to "other", so
# Nextcloud sees the folder name and is denied entry. Measured YYYY-MM-DD:
#
#   mv (same filesystem)   admin:admin  drwxrwx---   DENIED
#   cp -a / rsync -a       admin:admin  drwxrwx---   DENIED
#   plain cp -r            root:www-data drwxr-s---  visible but READ-ONLY
#
# `mv` is the worst case and the most natural command to reach for: within one
# filesystem it only relinks the inode, so no new file is created and the setgid
# bit on the parent never applies. There is no copy flag that gets this right,
# which is why this script exists rather than a documented one-liner.
#
#   fix-share-permissions.sh                    # whole internal share
#   fix-share-permissions.sh "/mnt/data/media-library"  # one subfolder
#   fix-share-permissions.sh --no-scan ...      # fix permissions only

HOMELAB_LOG_TAG=fix-share-perms
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker find chown chmod

readonly SHARE_ROOT="${HOMELAB_ROOT}/shared-internal"
readonly NC_UID=33          # www-data inside the Nextcloud image
readonly CT=homelab-nextcloud

do_scan=true
[ "${1:-}" = "--no-scan" ] && { do_scan=false; shift; }

targets=()
if [ "$#" -eq 0 ]; then
  targets=("$SHARE_ROOT")
else
  for a in "$@"; do
    # Accept a bare subfolder name or a full path, but never escape the share.
    case "$a" in
      /*) p="$a" ;;
      *)  p="${SHARE_ROOT}/${a}" ;;
    esac
    real=$(readlink -f "$p" 2>/dev/null || true)
    [ -n "$real" ] && [ -e "$real" ] || die "no such path: $p"
    case "$real" in
      "$SHARE_ROOT"|"$SHARE_ROOT"/*) ;;
      *) die "$real is outside ${SHARE_ROOT} - refusing" ;;
    esac
    targets+=("$real")
  done
fi

for t in "${targets[@]}"; do
  n=$(find "$t" | wc -l)
  log "fixing ${t} (${n} entries)"
  chown -R "${NC_UID}:${NC_UID}" "$t"
  # 2770 on directories: owner and group get full access, others nothing, and the
  # setgid bit makes anything created inside inherit group www-data so a later
  # plain `cp` needs no fixing. 0660 on files for the same owner/group access.
  find "$t" -type d -exec chmod 2770 {} +
  find "$t" -type f -exec chmod 0660 {} +
done

# The share root itself must stay setgid even when only a subfolder was fixed.
chown "${NC_UID}:${NC_UID}" "$SHARE_ROOT"
chmod 2770 "$SHARE_ROOT"

log "verifying Nextcloud can read it"
docker exec -u www-data "$CT" sh -c 'ls -A /mnt/internal-shared >/dev/null 2>&1' \
  || die "www-data still cannot read /mnt/internal-shared inside ${CT}"

if [ "$do_scan" = true ]; then
  # Only users with the mount need scanning. Discover them from the mount's
  # applicable groups rather than hardcoding names.
  users=$(docker exec -u www-data "$CT" php occ files_external:list --output=json 2>/dev/null \
    | python3 -c "
import json,sys,subprocess
mounts=json.load(sys.stdin)
groups=set()
for m in mounts:
    if m.get('configuration',{}).get('datadir')=='/mnt/internal-shared':
        groups.update(m.get('applicable_groups') or [])
out=subprocess.run(['docker','exec','-u','www-data','$CT','php','occ','group:list','--output=json'],
                   capture_output=True,text=True).stdout
allg=json.loads(out) if out.strip() else {}
u=set()
for g in groups: u.update(allg.get(g,[]))
print(' '.join(sorted(u)))" 2>/dev/null)

  if [ -z "$users" ]; then
    warn "could not determine which users have the share; skipping scan"
  else
    for u in $users; do
      log "scanning ${u}"
      # The .homelab Restic repo on the data disk is root-owned 0700 on purpose, so a
      # 'Permission denied' for that path is expected and is not a failure.
      docker exec -u www-data "$CT" php occ files:scan "$u" 2>&1 \
        | grep -vE 'opendir\(/mnt/data/\.homelab|storage not available' \
        | sed 's/^/    /'
    done
  fi
fi

log "done"
