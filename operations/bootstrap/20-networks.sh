#!/usr/bin/env bash
# Create the shared Docker network used by the databases and nextcloud projects.
#
# Example private subnet; check your Docker and VPN ranges for overlap before use.

HOMELAB_LOG_TAG=networks
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd docker

NET=homelab-db
SUBNET=10.243.0.0/24

if docker network inspect "$NET" >/dev/null 2>&1; then
  actual=$(docker network inspect "$NET" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
  log "network $NET already exists (subnet ${actual})"
else
  docker network create \
    --driver bridge \
    --subnet "$SUBNET" \
    --opt com.docker.network.bridge.name=br-homelab-db \
    "$NET"
  log "created network $NET on $SUBNET"
fi
