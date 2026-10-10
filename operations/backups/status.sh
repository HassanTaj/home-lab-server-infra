#!/usr/bin/env bash
# Backup diagnostics: last success, repository age, free space, mount health.
# Read-only. Safe to run at any time.

HOMELAB_LOG_TAG=backup-status
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd restic systemctl
load_env backup.env

echo "=== mount health ==="
if mountpoint -q "$DATA_MOUNT"; then
  src=$(findmnt -n -o SOURCE --target "$DATA_MOUNT")
  uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || echo none)
  marker=$([ -f "$DATA_MARKER" ] && echo present || echo MISSING)
  printf '  mounted   %s (uuid %s, marker %s)\n' "$src" "$uuid" "$marker"
else
  printf '  NOT MOUNTED - backups involving the data disk will refuse to run\n'
fi

echo
echo "=== free space ==="
df -h /home "$DATA_MOUNT" 2>/dev/null | sed 's/^/  /'

echo
echo "=== timers ==="
systemctl list-timers --no-pager 'homelab-*' 2>/dev/null | sed 's/^/  /'

echo
echo "=== last unit results ==="
for u in homelab-backup-internal homelab-backup-check homelab-restore-drill; do
  res=$(systemctl show -p Result --value "${u}.service" 2>/dev/null || echo unknown)
  when=$(systemctl show -p ExecMainExitTimestamp --value "${u}.service" 2>/dev/null)
  printf '  %-28s %-10s %s\n' "$u" "$res" "${when:-never run}"
done

echo
echo "=== repository snapshots ==="
for pair in "internal:${RESTIC_REPO_INTERNAL}:${RESTIC_PASSWORD_INTERNAL}"; do
  name=${pair%%:*}; rest=${pair#*:}; repo=${rest%%:*}; pass=${rest#*:}
  printf '  --- %s (%s) ---\n' "$name" "$repo"
  if [ -d "$repo" ] && RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" restic cat config >/dev/null 2>&1; then
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
      restic snapshots --latest 3 --compact 2>/dev/null | sed 's/^/    /'
  else
    printf '    unavailable (not initialised, or disk absent)\n'
  fi
done

echo
echo "=== staging residue (indicates a failed run) ==="
find "${HOMELAB_ROOT}/backup-staging" -maxdepth 1 -name '*.partial' -printf '  %p\n' 2>/dev/null \
  || printf '  none\n'
