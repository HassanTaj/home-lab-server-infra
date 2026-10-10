#!/usr/bin/env bash
# Fail closed until the exact addresses are present and Pi-hole's ports are free.

HOMELAB_LOG_TAG=pihole-preflight
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker ip ss

readonly LAN_IP=192.0.2.10
readonly NETBIRD_IP=100.64.0.10
readonly WAIT_SECONDS=${PIHOLE_WAIT_SECONDS:-180}

wait_for_address() {
  local address="$1" elapsed=0
  while ! ip -4 -o address show | awk '{print $4}' | grep -q "^${address}/"; do
    [ "$elapsed" -lt "$WAIT_SECONDS" ] \
      || die "address ${address} did not appear within ${WAIT_SECONDS}s"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log "address ready: ${address}"
}

port_is_bound() {
  local protocol="$1" address="$2" port="$3"
  if [ "$protocol" = tcp ]; then
    ss -H -lnt4 "sport = :${port}" | awk '{print $4}' | grep -Fxq "${address}:${port}"
  else
    ss -H -lnu4 "sport = :${port}" | awk '{print $4}' | grep -Fxq "${address}:${port}"
  fi
}

assert_port_available() {
  local protocol="$1" address="$2" port="$3"
  if ! port_is_bound "$protocol" "$address" "$port"; then
    log "port ready: ${address}:${port}/${protocol}"
    return
  fi

  # An already-running managed container is safe for an idempotent Compose up.
  if docker ps --format '{{.Names}}' | grep -Fxq homelab-pihole; then
    log "port already held by running homelab-pihole: ${address}:${port}/${protocol}"
    return
  fi

  die "${address}:${port}/${protocol} is already in use by another process"
}

wait_for_address "$LAN_IP"
wait_for_address "$NETBIRD_IP"
assert_port_available tcp "$LAN_IP" 53
assert_port_available udp "$LAN_IP" 53
assert_port_available tcp "$NETBIRD_IP" 8053

log "Pi-hole prerequisites passed"
