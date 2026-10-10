#!/usr/bin/env bash
# Post-installation Nextcloud configuration.
#
# Applies everything the container image does not set reliably on an existing
# instance: reverse-proxy trust, Redis transactional locking, cron mode, mail
# (password reset and recovery), and the data-disk external storage mount.
#
# Idempotent. Safe to re-run after any configuration drift.

HOMELAB_LOG_TAG=configure-nc
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker
load_env nextcloud.env

CT=homelab-nextcloud
docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true \
  || die "$CT is not running"

occ() { docker exec -u www-data "$CT" php occ "$@"; }

occ status | grep -q 'installed: true' || die "Nextcloud is not installed yet"

# --- reverse proxy --------------------------------------------------------
# edge VPS Traefik is the only TLS edge. Trust exactly one proxy address.
[ -n "${TRUSTED_PROXIES:-}" ] && [ "$TRUSTED_PROXIES" != "CHANGE_ME_EDGE_VPS_NETBIRD_IP" ] \
  || die "TRUSTED_PROXIES is not set to the real edge VPS NetBird address"

log "configuring reverse proxy trust"
occ config:system:set trusted_proxies 0 --value="$TRUSTED_PROXIES"
occ config:system:set overwriteprotocol --value=https
occ config:system:set overwritehost --value=next.home.example.com
occ config:system:set overwrite.cli.url --value=https://next.home.example.com
occ config:system:set trusted_domains 0 --value=next.home.example.com
occ config:system:set forwarded_for_headers 0 --value=HTTP_X_FORWARDED_FOR

# --- Redis transactional locking -----------------------------------------
log "configuring Redis locking"
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set redis host --value=homelab-nextcloud-redis
occ config:system:set redis port --value=6379 --type=integer
occ config:system:set redis password --value="$REDIS_HOST_PASSWORD" >/dev/null 2>&1 \
  || die "failed to set redis password"
occ config:system:set redis timeout --value=1.5 --type=double

# --- background jobs ------------------------------------------------------
log "setting cron background mode"
occ background:cron

# --- mail: password reset and recovery ------------------------------------
# Nextcloud will not send a reset link at all unless mail is configured, so this
# is what makes the "forgot password" flow work rather than fail silently.
if [ -n "${SMTP_HOST:-}" ] && [ "${SMTP_PASSWORD:-}" != "CHANGE_ME_SMTP_PASSWORD" ]; then
  log "configuring SMTP (${SMTP_HOST}:${SMTP_PORT}, ${SMTP_SECURE})"
  occ config:system:set mail_smtpmode      --value=smtp
  occ config:system:set mail_smtphost      --value="$SMTP_HOST"
  occ config:system:set mail_smtpport      --value="$SMTP_PORT" --type=integer
  occ config:system:set mail_smtpsecure    --value="$SMTP_SECURE"
  occ config:system:set mail_smtpauth      --value=true --type=boolean
  occ config:system:set mail_smtpauthtype  --value="${SMTP_AUTHTYPE:-LOGIN}"
  occ config:system:set mail_smtpname      --value="$SMTP_NAME"
  # occ echoes the value it sets, so this one must never reach the terminal or
  # the systemd journal.
  occ config:system:set mail_smtppassword  --value="$SMTP_PASSWORD" >/dev/null 2>&1 \
    && log "System config value mail_smtppassword set to string <redacted>" \
    || die "failed to set mail_smtppassword"
  occ config:system:set mail_from_address  --value="$MAIL_FROM_ADDRESS"
  occ config:system:set mail_domain        --value="$MAIL_DOMAIN"
  occ config:system:set mail_sendmailmode  --value=smtp
  log "SMTP configured; verify with operations/tests/test-mail.sh <address>"
else
  warn "SMTP not configured - password reset and recovery mail will NOT work"
fi

# --- uploads and locale ---------------------------------------------------
occ config:system:set default_phone_region --value=IN
occ config:system:set maintenance_window_start --value=1 --type=integer

# --- data-disk external storage -----------------------------------------
log "enabling external storage app"
occ app:enable files_external >/dev/null

if occ files_external:list --output=json | grep -q '/mnt/data'; then
  log "external storage mount already present"
else
  log "creating data disk shared external storage mount"
  mount_id=$(occ files_external:create "Data" local null::null \
    --config datadir=/mnt/data --output=json | tr -dc '0-9')
  [ -n "$mount_id" ] || die "failed to create external storage mount"
  # Not visible to anyone until a group is explicitly granted below.
  occ files_external:option "$mount_id" enable_sharing false
  # Do NOT let Nextcloud rescan this storage on access. On YYYY-MM-DD a cron scan
  # ran against the mountpoint while the disk was detached, saw an empty
  # directory, and purged 263,255 oc_filecache rows -- reconciling that took a
  # per-folder rescan of a large library. The unit is fail-closed on the disk, so the only
  # way this storage is ever empty is a fault, and a scan is the wrong response
  # to a fault.
  occ files_external:option "$mount_id" filesystem_check_changes 0
  log "created mount ${mount_id} (no group assigned yet)"
fi

log "configuration applied. Remaining manual steps:"
cat <<'NOTE'
    1. Create groups and assign the "Data" mount to them:
         occ files_external:applicable <mount-id> --add-group <group>
    2. Set per-user quotas:
         occ user:setting <uid> files quota "50 GB"
    3. Install and configure Group folders if shared team spaces are needed:
         occ app:install groupfolders
    4. Send a test message and confirm delivery:
         operations/tests/test-mail.sh you@example.com
NOTE
