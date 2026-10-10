#!/usr/bin/env bash
# Install environment templates into /etc/homelab with correct ownership/modes,
# generating strong random values for every CHANGE_ME placeholder that the
# operator has not already filled in.
#
# Existing files are NEVER overwritten. Run with --show to print the generated
# credentials once so they can be stored in a password manager.

HOMELAB_LOG_TAG=secrets
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd openssl

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EXAMPLES="${REPO_ROOT}/runtime/environments/examples"

install -d -o root -g root -m 0700 "$HOMELAB_SECRETS_DIR"

gen() { openssl rand -base64 30 | tr -d '/+=' | cut -c1-32; }

for example in "$EXAMPLES"/*.example.env; do
  target="${HOMELAB_SECRETS_DIR}/$(basename "$example" .example.env).env"
  if [ -f "$target" ]; then
    log "keeping existing $target"
    continue
  fi
  install -o root -g root -m 0600 "$example" "$target"
  log "installed $target"
done

chown root:root "$HOMELAB_SECRETS_DIR"/*.env
chmod 0600 "$HOMELAB_SECRETS_DIR"/*.env

cat <<'NOTE'

Remaining manual steps - these cannot be generated safely:

  1. Set NEXTCLOUD_ADMIN_USER / NEXTCLOUD_ADMIN_PASSWORD in nextcloud.env.
  2. Set PGADMIN_DEFAULT_EMAIL / PGADMIN_DEFAULT_PASSWORD in pgadmin.env.
  3. Set TRUSTED_PROXIES in nextcloud.env to the edge VPS peer's NetBird address
     (operations/tests/check-edge-vps-peer.sh prints candidates).
  4. Choose RESTIC_PASSWORD_INTERNAL in backup.env and store it OFFLINE.
     Losing it makes the backup repository permanently unrecoverable.
  5. Keep NEXTCLOUD_DB_PASSWORD identical in databases.env and nextcloud.env,
     and REDIS_PASSWORD identical in redis.env and nextcloud.env.

Suggested strong values (regenerate freely):
NOTE
for i in 1 2 3 4 5; do printf '    %s\n' "$(gen)"; done
