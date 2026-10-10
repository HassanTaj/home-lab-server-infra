#!/usr/bin/env bash
# Read-only inventory of the exact legacy objects that teardown will remove.
#
# Run this before and after every teardown step and keep the output as evidence.
# Changes nothing.

HOMELAB_LOG_TAG=legacy-inventory
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker

# shellcheck source=./legacy-objects.sh
. "$(dirname "$0")/legacy-objects.sh"

echo "=== legacy containers ==="
for c in "${LEGACY_CONTAINERS[@]}"; do
  s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo absent)
  i=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || echo -)
  printf '  %-14s %-10s %s\n' "$c" "$s" "$i"
done

echo
echo "=== legacy volumes ==="
for v in "${LEGACY_VOLUMES[@]}"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v")
    sz=$(du -sh "$mp" 2>/dev/null | cut -f1)
    printf '  %-28s present  %-8s %s\n' "$v" "${sz:-?}" "$mp"
  else
    printf '  %-28s absent\n' "$v"
  fi
done

echo
echo "=== legacy networks ==="
for n in "${LEGACY_NETWORKS[@]}"; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    used=$(docker network inspect -f '{{len .Containers}}' "$n")
    printf '  %-28s present  %s attached container(s)\n' "$n" "$used"
  else
    printf '  %-28s absent\n' "$n"
  fi
done

echo
echo "=== legacy images ==="
for i in "${LEGACY_IMAGES[@]}"; do
  id=$(docker image inspect -f '{{.Id}}' "$i" 2>/dev/null || echo absent)
  printf '  %-46s %s\n' "$i" "${id:0:19}"
done

echo
echo "=== legacy data paths ==="
for p in /srv/docker/data/nextcloud /srv/legacy/nextcloud-data; do
  if [ -e "$p" ]; then
    printf '  %-34s %s\n' "$p" "$(du -sh "$p" 2>/dev/null | cut -f1)"
  else
    printf '  %-34s absent\n' "$p"
  fi
done

echo
echo "=== other /srv/docker content (MUST BE PRESERVED) ==="
find /srv/docker -maxdepth 2 -mindepth 1 \
  -not -path '/srv/docker/data/nextcloud*' -printf '  %p\n' 2>/dev/null | sort
