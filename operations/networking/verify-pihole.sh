#!/usr/bin/env bash
# Verify staged Pi-hole DNS without changing any client or router configuration.

HOMELAB_LOG_TAG=verify-pihole
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd curl dig docker grep

readonly LAN_IP=192.0.2.10
readonly ROUTER_IP=192.0.2.1
readonly NETBIRD_IP=100.64.0.10
readonly PUBLIC_EDGE_IP=203.0.113.10

container_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' homelab-pihole 2>/dev/null || true)
[ "$container_health" = healthy ] || die "homelab-pihole health is '${container_health:-missing}', expected healthy"
log "container healthy"

for name in \
  home.example.com \
  next.home.example.com \
  images.home.example.com \
  media.home.example.com; do
  answer=$(dig +time=2 +tries=1 +short A "@$LAN_IP" "$name" | sort -u)
  [ "$answer" = "$LAN_IP" ] \
    || die "$name returned '${answer:-no answer}' from Pi-hole, expected $LAN_IP"
  log "local A record: ${name} -> ${answer}"
done

tcp_answer=$(dig +tcp +time=2 +tries=1 +short A "@$LAN_IP" next.home.example.com | sort -u)
[ "$tcp_answer" = "$LAN_IP" ] || die "TCP DNS returned '${tcp_answer:-no answer}', expected $LAN_IP"
log "TCP DNS query passed"

upstream_answer=$(dig +time=3 +tries=1 +short A "@$LAN_IP" example.com | head -1)
[ -n "$upstream_answer" ] || die "upstream DNS forwarding returned no answer"
log "upstream DNS forwarding passed"

router_answer=$(dig +time=3 +tries=1 +short A "@$ROUTER_IP" next.home.example.com | sort -u)
[ "$router_answer" = "$PUBLIC_EDGE_IP" ] \
  || die "router DNS returned '${router_answer:-no answer}', expected unchanged public edge $PUBLIC_EDGE_IP"
log "router DNS remains unchanged: next.home.example.com -> ${router_answer}"

curl -fsSL --max-time 5 "http://${NETBIRD_IP}:8053/admin/" >/dev/null \
  || die "Pi-hole NetBird-only dashboard did not answer"
log "NetBird-only dashboard answered"

sleep 2
query_log=$(docker exec homelab-pihole sh -c \
  "grep -F 'next.home.example.com' /var/log/pihole/pihole.log | tail -n 1" 2>/dev/null || true)
[ -n "$query_log" ] || die "test query did not appear in Pi-hole's query log"
log "query log contains the split-DNS test"

log "Pi-hole staged validation passed; router DHCP/DNS remains unchanged"
