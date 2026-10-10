#!/usr/bin/env bash
# Validate every Compose file renders, uses no `latest` tag, pins a digest on
# every image, and publishes ports only on explicitly approved addresses.
#
# Runs without the live secrets present by substituting a throwaway env set, so
# it is safe in CI and on a workstation.

HOMELAB_LOG_TAG=validate-compose
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap - ERR   # this script reports all failures rather than aborting on the first

require_cmd docker

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NETBIRD_IP=100.64.0.10
LAN_IP=192.0.2.10
fail=0

# Provide stand-in secrets if the real ones are absent.
STUB=""
if [ ! -r /etc/homelab/databases.env ] || [ ! -r /etc/homelab/pihole-web-password ]; then
  STUB=$(mktemp -d)
  for f in databases pgadmin nextcloud redis immich; do
    sed 's/CHANGE_ME[A-Z_]*/stub/' "${REPO_ROOT}/runtime/environments/examples/${f}.example.env" \
      > "${STUB}/${f}.env"
  done
  printf 'stub-password\n' > "${STUB}/pihole-web-password"
  log "using stub env files in ${STUB}"
fi

render() {
  local file="$1" project profile_args=()
  project=$(basename "$(dirname "$file")")
  [ "$project" != hermes ] || profile_args+=(--profile home-assistant)
  if [ -n "$STUB" ]; then
    sed "s|/etc/homelab/|${STUB}/|g" "$file" > "${STUB}/${project}.yml"
    docker compose "${profile_args[@]}" -f "${STUB}/${project}.yml" config 2>&1
  else
    docker compose "${profile_args[@]}" -f "$file" config 2>&1
  fi
}

for project in databases nextcloud management networking local-edge media immich hermes; do
  file="${REPO_ROOT}/runtime/compose/${project}/docker-compose.yml"
  echo "=== ${project} ==="

  if out=$(render "$file"); then
    log "OK    renders"
  else
    warn "FAIL  does not render:"; printf '%s\n' "$out" | sed 's/^/      /'; fail=1; continue
  fi

  # No floating tags.
  if printf '%s\n' "$out" | grep -E '^\s+image:' | grep -qE ':latest|image: [^@]*$'; then
    warn "FAIL  image without pinned digest or using :latest"
    printf '%s\n' "$out" | grep -E '^\s+image:' | sed 's/^/      /'
    fail=1
  else
    log "OK    all images pinned by digest, none use :latest"
  fi

  # Published ports must be NetBird-only.
  mapfile -t published < <(printf '%s\n' "$out" | grep -E '^\s+published:' | awk '{print $2}' | tr -d '"')
  mapfile -t hostips   < <(printf '%s\n' "$out" | grep -E '^\s+host_ip:'   | awk '{print $2}' | tr -d '"')
  if [ "${#published[@]}" -eq 0 ]; then
    log "OK    publishes no host ports"
  elif [ "${#hostips[@]}" -ne "${#published[@]}" ]; then
    warn "FAIL  ${#published[@]} published port(s) but only ${#hostips[@]} host_ip binding(s)"
    fail=1
  else
    # Three bindings are acceptable, and nothing else:
    #   the NetBird address, for services edge VPS Traefik must reach;
    #   127.0.0.1, for services reachable only through an SSH tunnel (stricter).
    #   the exact LAN address, only for networking (Pi-hole DNS) and local-edge
    #   (the LAN HTTPS listener).
    # A wildcard or any other LAN address is a failure.
    bad=0
    for ip in "${hostips[@]}"; do
      case "${project}:${ip}" in
        *:"$NETBIRD_IP"|*:127.0.0.1|networking:"$LAN_IP"|local-edge:"$LAN_IP") ;;
        *) warn "FAIL  ${project} port bound to unapproved address ${ip}"; bad=1 ;;
      esac
    done
    if [ "$bad" -eq 0 ]; then
      log "OK    all ${#published[@]} published port(s) use approved host addresses"
    else
      fail=1
    fi
  fi
  echo
done

echo "=== yui ==="
yui_file="${REPO_ROOT}/runtime/compose/yui/docker-compose.yml"
if out=$(docker compose -f "$yui_file" config 2>&1); then
  log "OK    renders"
  if printf '%s\n' "$out" | grep -E '^\s+image:' | grep -qE ':latest|image: [^@]*$'; then
    warn "FAIL  yui image is not pinned by digest"; fail=1
  else
    log "OK    image pinned by digest"
  fi
  if printf '%s\n' "$out" | grep -q 'network_mode: host' \
     && ! printf '%s\n' "$out" | grep -qE '^\s+ports:'; then
    log "OK    host networking without wildcard port publishing"
  else
    warn "FAIL  unexpected yui network/port configuration"; fail=1
  fi
else
  warn "FAIL  yui compose does not render:"; printf '%s\n' "$out" | sed 's/^/      /'; fail=1
fi

echo
# The Nextcloud web and cron containers must share one digest.
web=$(grep -A1 'x-nextcloud-image' "${REPO_ROOT}/runtime/compose/nextcloud/docker-compose.yml" | grep -c 'image:')
[ "$web" -eq 1 ] && log "OK    nextcloud web and cron share a single image anchor" \
                 || { warn "FAIL  nextcloud image anchor is not single-sourced"; fail=1; }

[ -n "$STUB" ] && rm -rf "$STUB"

if [ "$fail" -ne 0 ]; then log "compose validation FAILED"; exit 1; fi
log "compose validation passed"
