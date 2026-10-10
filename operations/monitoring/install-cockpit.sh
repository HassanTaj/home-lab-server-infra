#!/usr/bin/env bash
# Install Cockpit from Ubuntu packages with a minimal module set, bound to the
# NetBird address only.
#
# Cockpit is a full host-administration surface. It must never be reachable from
# the LAN or the Internet.

HOMELAB_LOG_TAG=cockpit
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

require_root
require_cmd apt-get systemctl

export DEBIAN_FRONTEND=noninteractive

log "installing Cockpit (minimal module set)"
apt-get update -qq
# Deliberately excluding cockpit-networkmanager (NetBird/wt0 is managed
# elsewhere) and cockpit-packagekit (unattended upgrades are not wanted).
apt-get install -y --no-install-recommends \
  cockpit-ws \
  cockpit-bridge \
  cockpit-system \
  cockpit-storaged

# Cockpit ships as a socket-activated service. Override the listen address so it
# binds only to the NetBird overlay.
install -d -m 0755 /etc/systemd/system/cockpit.socket.d
cat > /etc/systemd/system/cockpit.socket.d/listen.conf <<'EOF'
[Socket]
# Clear the default 0.0.0.0:9090 before adding the restricted binding.
ListenStream=
ListenStream=100.64.0.10:9090
FreeBind=yes
EOF

# Cockpit is reached DIRECTLY over the NetBird overlay, not through Traefik.
#
# There is deliberately no cockpit.home.* router on edge VPS (see
# integrations/edge-vps/homelab.yml for why sharing one Cockpit across hosts was
# rejected). The Traefik origin is listed anyway so the config keeps working if a
# router is ever added, but the direct origin is the one in use.
#
# AllowUnencrypted is safe here and is not a downgrade: the only route to this
# port is the NetBird overlay, which is WireGuard, so the request is already
# encrypted end to end between peers. Cockpit refuses a request whose Origin
# header is not listed, which is why the direct address must appear explicitly.
install -d -m 0755 /etc/cockpit
cat > /etc/cockpit/cockpit.conf <<'EOF'
[WebService]
Origins = http://100.64.0.10:9090 https://cockpit.home.example.com
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
AllowUnencrypted = true
EOF

# Keep Cockpit within the low-memory host budget.
install -d -m 0755 /etc/systemd/system/cockpit.service.d
cat > /etc/systemd/system/cockpit.service.d/limits.conf <<'EOF'
[Service]
MemoryMax=256M
CPUQuota=30%
EOF

systemctl daemon-reload
systemctl restart cockpit.socket
systemctl enable cockpit.socket

log "Cockpit listening on:"
ss -tlnp | grep 9090 | sed 's/^/    /' || warn "no listener on 9090 yet"
log "reachable at https://cockpit.home.example.com via edge VPS (NetBird-only)"
