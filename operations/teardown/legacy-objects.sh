#!/usr/bin/env bash
# The EXACT legacy objects that teardown is authorised to touch.
#
# Verified against the live host on YYYY-MM-DD. Nothing outside these lists may
# ever be removed by a teardown script, and no script may use a global prune.
#
# Source only. Do not execute.

LEGACY_CONTAINERS=(
  nextcloud
  uptime-kuma
  n8n
  portainer
  coredns
  traefik
  postgres
  pgadmin
  mssql
)

LEGACY_VOLUMES=(
  databases_postgres-data
  databases_pgadmin-data
  databases_mssql-data
)

LEGACY_NETWORKS=(
  homearpa_default
  databases_postgres-network
  mssql-network
  proxy
)

LEGACY_IMAGES=(
  nextcloud:latest
  louislam/uptime-kuma:latest
  n8nio/n8n:latest
  portainer/portainer-ce:latest
  coredns/coredns:latest
  traefik:v3.6
  postgis/postgis:18-3.6
  dpage/pgadmin4:latest
  mcr.microsoft.com/mssql/server:2022-latest
)

# The ONLY two paths approved for deletion, and only after acceptance plus a
# successful restore drill. Everything else under /srv/docker is preserved.
LEGACY_DELETE_PATHS=(
  /srv/legacy/nextcloud-data
  /srv/docker/data/nextcloud
)

LEGACY_COMPOSE_PROJECTS=(
  homearpa
  databases
)
