#!/usr/bin/env bash
# Weekly structural check of the Restic repository.
#
# Never prunes. A failing check must leave the repository exactly as it is.

HOMELAB_LOG_TAG=check-repos
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd restic
load_env backup.env

with_storage_lock
verify_data_mounted

fail=0

check_one() {
  local name="$1" repo="$2" pass="$3"
  log "checking ${name} (${repo})"
  if RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
       restic check --read-data-subset=10%; then
    log "OK    ${name}"
  else
    warn "FAIL  ${name} - do not prune, investigate before the next backup"
    fail=1
  fi
}

check_one internal "$RESTIC_REPO_INTERNAL" "$RESTIC_PASSWORD_INTERNAL"

[ "$fail" -eq 0 ] || die "one or more repository checks failed"
log "all repository checks passed"
