# Home Assistant example

This Compose project runs Home Assistant with host networking so it can discover
devices on the local network. The systemd unit starts it after Docker and
NetBird. Review the host firewall and the example reverse-proxy route before
making the service reachable from other devices.

The service name and `example.com` hostnames are demo values. Do not expose the
Home Assistant administration interface publicly; keep remote access behind a
private overlay and an explicit access policy.

The Hermes integration is documented in [its local README](../hermes/README.md).
The example keeps Hermes without Home Assistant control tools enabled.
