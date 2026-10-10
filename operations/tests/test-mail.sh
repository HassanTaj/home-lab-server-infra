#!/usr/bin/env bash
# Verify the Nextcloud mail path actually delivers, which is what the
# "forgot password" and account-recovery flows depend on.
#
#   test-mail.sh <recipient-address>
#
# A clean Nextcloud startup does NOT prove SMTP works; Nextcloud only contacts
# the server when it sends. This script forces a real send.

HOMELAB_LOG_TAG=test-mail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

require_root
require_cmd docker

to="${1:-}"
[ -n "$to" ] || die "usage: $0 <recipient-address>"

CT=homelab-nextcloud
occ() { docker exec -u www-data "$CT" php occ "$@"; }

echo "=== current mail configuration ==="
for k in mail_smtpmode mail_smtphost mail_smtpport mail_smtpsecure \
         mail_smtpauth mail_smtpauthtype mail_smtpname \
         mail_from_address mail_domain; do
  v=$(occ config:system:get "$k" 2>/dev/null || echo '<unset>')
  printf '  %-22s %s\n' "$k" "$v"
done
# Never print the password; just confirm one exists.
if occ config:system:get mail_smtppassword >/dev/null 2>&1; then
  printf '  %-22s %s\n' "mail_smtppassword" "<set>"
else
  printf '  %-22s %s\n' "mail_smtppassword" "<UNSET>"
fi

echo
echo "=== sending test message to ${to} ==="
if occ mail:test "$to"; then
  log "SMTP accepted the message"
else
  die "SMTP send FAILED - password reset mail will not work"
fi

echo
cat <<NOTE
Now confirm actual delivery, not just acceptance:

  1. Check the inbox for ${to}, including spam.
  2. If the address is Outlook/Hotmail and nothing arrives, that matches the
     known example.com DMARC gap recorded in the edge VPS docs. SPF and
     DKIM pass; add a DMARC record before relying on it.
  3. Exercise the real flow end to end: open
       https://next.home.example.com
     click "Forgot password", and confirm the reset link arrives and works.
NOTE
