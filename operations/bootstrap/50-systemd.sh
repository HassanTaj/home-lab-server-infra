#!/usr/bin/env bash
# Install and enable every Homelab systemd unit. Idempotent.
#
# Units are copied rather than symlinked so a repo checkout move cannot break a
# running system.

HOMELAB_LOG_TAG=systemd
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd systemctl

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OPS="${REPO_ROOT}/operations"
UNIT_DIR=/etc/systemd/system

# Units ending in .in embed the repository path and must be rendered, so the
# tree can be relocated without leaving stale absolute paths in /etc/systemd.
# Plain units are copied verbatim.
install_unit() {
  local src="$1" name
  name=$(basename "$src")
  if [ "${name%.in}" != "$name" ]; then
    name=${name%.in}
    sed "s|@REPO_ROOT@|${REPO_ROOT}|g" "$src" > "${UNIT_DIR}/${name}"
    chown root:root "${UNIT_DIR}/${name}"
    chmod 0644 "${UNIT_DIR}/${name}"
    log "rendered ${name}"
  else
    install -o root -g root -m 0644 "$src" "${UNIT_DIR}/${name}"
    log "installed ${name}"
  fi
}

for u in "${OPS}"/storage/systemd/* \
         "${OPS}"/backups/systemd/* \
         "${OPS}"/monitoring/systemd/* \
         "${OPS}"/bootstrap/homelab-*.service.in \
         "${OPS}"/bootstrap/homelab-*.timer.in; do
  [ -e "$u" ] || continue
  install_unit "$u"
done
log "repo root: ${REPO_ROOT}"

# --- retire the old single unit --------------------------------------------
# homelab-compose.service drove all three Compose projects from one oneshot
# unit that carried RequiresMountsFor=/mnt/data. On YYYY-MM-DD a
# two-second disk fault therefore cascade-stopped the entire stack and
# its `down` ExecStop destroyed every container and network. It is replaced by
# homelab-{databases,nextcloud,management}.service; only Nextcloud keeps the
# data-disk dependency. Leaving both installed would have the two fight over the
# same containers, so the old unit is disabled and removed.
if [ -e "${UNIT_DIR}/homelab-compose.service" ]; then
  systemctl disable --now homelab-compose.service 2>/dev/null || true
  rm -f "${UNIT_DIR}/homelab-compose.service"
  log "retired homelab-compose.service"
fi

systemctl daemon-reload

systemctl enable 'mnt-data.automount'
systemctl enable 'mnt-storage.mount'
systemctl enable homelab-databases.service
systemctl enable homelab-nextcloud.service
systemctl enable homelab-management.service
systemctl enable homelab-media.service
systemctl enable homelab-landing.service
systemctl enable homelab-immich.service
systemctl enable homelab-yui.service
systemctl enable homelab-networking.service
systemctl enable homelab-local-edge.service
systemctl enable homelab-local-edge-certsync.timer
systemctl enable homelab-stack-watchdog.timer
for t in "${OPS}"/backups/systemd/*.timer; do
  [ -e "$t" ] || continue
  systemctl enable "$(basename "$t")"
done

log "units installed and enabled (not started - start them deliberately)"
systemctl --no-pager list-unit-files | grep -E 'homelab' || true
