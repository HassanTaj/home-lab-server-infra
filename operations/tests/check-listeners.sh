#!/usr/bin/env bash
# Assert that Homelab services listen only on their explicitly approved address.
#
# The acceptable bindings are 100.64.0.10 (NetBird), 127.0.0.1 (strictly
# host-local), and the explicitly reviewed Pi-hole DNS listener on
# 192.0.2.10:53 (Pi-hole) and 192.0.2.10:443 (local HTTPS edge). A
# 0.0.0.0 binding is a security failure.

HOMELAB_LOG_TAG=check-listeners
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR

require_root
require_cmd ss systemctl

NETBIRD_IP=100.64.0.10
LAN_IP=192.0.2.10
fail=0

declare -A EXPECT=(
  [8053]="$NETBIRD_IP"
  [8080]="$NETBIRD_IP"
  [9000]="$NETBIRD_IP"
  [45876]="$NETBIRD_IP"
  [8123]="$NETBIRD_IP"
  [5432]="127.0.0.1"
)

echo "=== Homelab service bindings ==="
for port in "${!EXPECT[@]}"; do
  want="${EXPECT[$port]}"
  mapfile -t got < <(ss -tlnH "sport = :${port}" | awk '{print $4}' | sed 's/:[0-9]*$//')
  if [ "${#got[@]}" -eq 0 ]; then
    printf '  %-6s not listening (service may not be deployed yet)\n' "$port"
    continue
  fi
  for addr in "${got[@]}"; do
    if [ "$addr" = "$want" ]; then
      printf '  %-6s OK    %s\n' "$port" "$addr"
    else
      printf '  %-6s FAIL  bound to %s, expected %s\n' "$port" "$addr" "$want"
      fail=1
    fi
  done
done

echo
echo "=== DNS bindings (NetBird and Pi-hole coexist) ==="
for protocol in tcp udp; do
  if [ "$protocol" = tcp ]; then
    mapfile -t dns_addrs < <(ss -tlnH "sport = :53" | awk '{print $4}' | sed 's/:[0-9]*$//')
  else
    mapfile -t dns_addrs < <(ss -ulnH "sport = :53" | awk '{print $4}' | sed 's/:[0-9]*$//')
  fi

  lan_seen=0
  for addr in "${dns_addrs[@]}"; do
    case "$addr" in
      "$LAN_IP")     printf '  %-6s OK    %s (Pi-hole)\n' "53/${protocol}" "$addr"; lan_seen=1 ;;
      "$NETBIRD_IP") printf '  %-6s OK    %s (NetBird)\n' "53/${protocol}" "$addr" ;;
      *) printf '  %-6s FAIL  bound to %s\n' "53/${protocol}" "$addr"; fail=1 ;;
    esac
  done

  if [ "$(systemctl is-active homelab-networking.service 2>/dev/null || true)" = active ] \
     && [ "$lan_seen" -ne 1 ]; then
    printf '  %-6s FAIL  Pi-hole unit is active but %s:53 is absent\n' "53/${protocol}" "$LAN_IP"
    fail=1
  fi
done

echo
echo "=== wildcard / LAN listeners (excluding SSH and system services) ==="
ss -tlnH | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\[::\]|${LAN_IP})" | sort -u | while read -r a; do
  case "$a" in
    *:22) printf '  allowed   %s (SSH)\n' "$a" ;;
    "$LAN_IP:53") printf '  allowed   %s (Pi-hole LAN DNS)\n' "$a" ;;
    "$LAN_IP:443") printf '  allowed   %s (local HTTPS edge)\n' "$a" ;;
    *)    printf '  REVIEW    %s\n' "$a" ;;
  esac
done

echo
if [ "$fail" -ne 0 ]; then log "listener check FAILED"; exit 1; fi
log "listener check passed"
