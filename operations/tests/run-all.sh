#!/usr/bin/env bash
# Run the full Homelab test suite.
#
#   run-all.sh            repo-only checks (safe anywhere)
#   run-all.sh --host     also run checks that require the deployed host
#
# Reports every result and exits non-zero if anything failed.

HOMELAB_LOG_TAG=test-suite
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

TESTS=$(cd "$(dirname "$0")" && pwd)
mode="${1:-}"
declare -a names results
fail=0

run() {
  local name="$1"; shift
  printf '\n################ %s ################\n' "$name"
  if "$@"; then
    names+=("$name"); results+=(PASS)
  else
    names+=("$name"); results+=(FAIL); fail=1
  fi
}

run "compose validation" "${TESTS}/validate-compose.sh"
run "secret scan"        "${TESTS}/check-secrets.sh"
run "shell syntax"       "${TESTS}/check-shell.sh"

if [ "$mode" = "--host" ]; then
  run "listener bindings" "${TESTS}/check-listeners.sh"
  run "fail-closed gates" "${TESTS}/test-fail-closed.sh"
else
  printf '\n(skipping host checks; pass --host to include them)\n'
fi

printf '\n================ SUMMARY ================\n'
for i in "${!names[@]}"; do
  printf '  %-22s %s\n' "${names[$i]}" "${results[$i]}"
done

[ "$fail" -eq 0 ] || { printf '\nSUITE FAILED\n'; exit 1; }
printf '\nSUITE PASSED\n'
