#!/usr/bin/env bash
# Install the Beszel hub and agent as pinned host binaries under systemd, with
# upstream checksum verification.
#
#   BESZEL_VERSION=0.x.y ./install-beszel.sh
#
# Hub binds to the NetBird address; the agent binds to loopback only.

HOMELAB_LOG_TAG=beszel
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd curl tar sha256sum systemctl

VERSION="${BESZEL_VERSION:-}"
[ -n "$VERSION" ] || die "set BESZEL_VERSION to a pinned release, e.g. BESZEL_VERSION=0.14.1 $0"

BASE="https://github.com/henrygd/beszel/releases/download/v${VERSION}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch_verified() {
  local asset="$1"
  log "downloading ${asset}"
  curl -fsSL -o "${WORK}/${asset}" "${BASE}/${asset}"
  curl -fsSL -o "${WORK}/checksums.txt" "${BASE}/beszel_${VERSION}_checksums.txt" 2>/dev/null \
    || curl -fsSL -o "${WORK}/checksums.txt" "${BASE}/checksums.txt"
  ( cd "$WORK" && grep " ${asset}\$" checksums.txt | sha256sum -c - ) \
    || die "checksum verification FAILED for ${asset}"
  log "checksum verified: ${asset}"
}

# AGENT ONLY. The hub runs on edge VPS (beszel.example.com) and this host
# reports to it, so no hub binary and no hub service are installed here.
fetch_verified "beszel-agent_linux_amd64.tar.gz"

tar -xzf "${WORK}/beszel-agent_linux_amd64.tar.gz" -C "$WORK"
install -o root -g root -m 0755 "${WORK}/beszel-agent" /usr/local/bin/beszel-agent

id -u beszel >/dev/null 2>&1 || useradd --system --home /var/lib/beszel --shell /usr/sbin/nologin beszel
install -d -o beszel -g beszel -m 0750 /var/lib/beszel

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
sed "s|@VERSION@|${VERSION}|g" "${REPO_ROOT}/operations/monitoring/systemd/beszel-agent.service" \
  > /etc/systemd/system/beszel-agent.service
chmod 0644 /etc/systemd/system/beszel-agent.service

systemctl daemon-reload
log "agent ${VERSION} installed."
log "Next: in the hub UI add a system with"
log "    host 100.64.0.10   port 45876"
log "put the public key it shows into KEY in /etc/homelab/beszel.env, then:"
log "    systemctl enable --now beszel-agent"
