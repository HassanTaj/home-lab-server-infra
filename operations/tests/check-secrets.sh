#!/usr/bin/env bash
# Secret-scanning gate for the repository.
#
# Fails if any tracked file contains a credential, a private key,
# or a live .env. Placeholders containing CHANGE_ME are permitted.

HOMELAB_LOG_TAG=check-secrets
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

# The repo root IS the project root since the YYYY-MM-DD restructure; before
# that, everything lived under Homelab/ and GITROOT was one level up.
REPO=$(cd "$(dirname "$0")/../.." && pwd)
GITROOT="$REPO"
fail=0

echo "=== tracked files that must not exist ==="
while read -r f; do
  case "$f" in
    *.example.env|*example.env) continue ;;
    *.env|*.env.*|*.pem|*.key|*.crt|*.p12|*.pfx)
      printf '  FAIL  tracked secret-like file: %s\n' "$f"; fail=1 ;;
  esac
done < <(cd "$GITROOT" && git ls-files 2>/dev/null)
[ "$fail" -eq 0 ] && printf '  OK    no tracked secret-like files\n'

echo
echo "=== credential patterns in tracked content ==="
patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'
  'PASSWORD=(?!CHANGE_ME)[^\s"'"'"']{8,}'
  'RESTIC_PASSWORD[A-Z_]*=(?!CHANGE_ME)[^\s"'"'"']{8,}'
  'api[_-]?key["'"'"' :=]+[A-Za-z0-9]{16,}'
  'nb_[A-Za-z0-9]{20,}'
)
hits=0
# This file is skipped because it necessarily contains the patterns themselves:
# the literal `PASSWORD=(?!CHANGE_ME)[^\s"']{8,}` on the line above satisfies its
# own regex, so scanning the scanner made the suite permanently red and masked
# real failures. Nothing else may be excluded.
SELF=operations/tests/check-secrets.sh
for p in "${patterns[@]}"; do
  while read -r f; do
    [ -f "${GITROOT}/${f}" ] || continue
    [ "$f" = "${SELF}" ] && continue
    if grep -PIqs "$p" "${GITROOT}/${f}"; then
      printf '  FAIL  %s matches /%s/\n' "$f" "$p"; hits=1; fail=1
    fi
  done < <(cd "$GITROOT" && git ls-files 2>/dev/null)
done
[ "$hits" -eq 0 ] && printf '  OK    no credential patterns found\n'

echo
echo "=== .gitignore coverage ==="
for probe in runtime/environments/live.env secret.pem x/.env; do
  if (cd "$GITROOT" && git check-ignore -q "$probe"); then
    printf '  OK    %s is ignored\n' "$probe"
  else
    printf '  FAIL  %s is NOT ignored\n' "$probe"; fail=1
  fi
done

echo
if [ "$fail" -ne 0 ]; then log "secret scan FAILED"; exit 1; fi
log "secret scan passed"
