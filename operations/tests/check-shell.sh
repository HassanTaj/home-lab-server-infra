#!/usr/bin/env bash
# Syntax-check every Homelab shell script, and run shellcheck when available.

HOMELAB_LOG_TAG=check-shell
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

REPO=$(cd "$(dirname "$0")/../.." && pwd)
fail=0

echo "=== bash -n ==="
while read -r f; do
  if bash -n "$f" 2>/dev/null; then
    printf '  OK    %s\n' "${f#"$REPO"/}"
  else
    printf '  FAIL  %s\n' "${f#"$REPO"/}"
    bash -n "$f" 2>&1 | sed 's/^/        /'
    fail=1
  fi
done < <(find "$REPO" -name '*.sh' -type f | sort)

echo
echo "=== executable bits ==="
while read -r f; do
  case "$(basename "$f")" in
    common.sh|legacy-objects.sh) continue ;;   # sourced, not executed
  esac
  if [ -x "$f" ]; then
    printf '  OK    %s\n' "${f#"$REPO"/}"
  else
    printf '  FAIL  %s is not executable\n' "${f#"$REPO"/}"; fail=1
  fi
done < <(find "$REPO" -name '*.sh' -type f | sort)

echo
if command -v shellcheck >/dev/null 2>&1; then
  echo "=== shellcheck ==="
  while read -r f; do
    if shellcheck -x -S warning "$f" >/dev/null 2>&1; then
      printf '  OK    %s\n' "${f#"$REPO"/}"
    else
      printf '  WARN  %s\n' "${f#"$REPO"/}"
      shellcheck -x -S warning "$f" 2>&1 | sed 's/^/        /' | head -20
    fi
  done < <(find "$REPO" -name '*.sh' -type f | sort)
else
  echo "(shellcheck not installed - skipping lint)"
fi

echo
[ "$fail" -eq 0 ] || { log "shell checks FAILED"; exit 1; }
log "shell checks passed"
