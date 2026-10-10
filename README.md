# Home Lab Server Infrastructure Demo

Sanitized reference implementation for a self-hosted server. It includes the
maintained Docker Compose stacks, Linux operations scripts, systemd templates,
configuration examples, and operator guides. Values tied to the original
deployment have been replaced with demo paths, reserved example addresses,
and placeholders.

## Reference host

The live host was checked read-only over SSH for this demo. It currently runs
Ubuntu 26.04.1 LTS on an Intel Core i5-7200U with 16 GB RAM, a 1 TB SSD, and a
separate 1 TB data disk. These specifications describe the example host; adjust
resource limits and storage paths for other hardware.

## Repository map

| Path | Contents |
|---|---|
| [`runtime/compose/`](runtime/compose/) | Databases, Nextcloud, media, Immich, networking, management, local edge, landing page, and assistant stacks |
| [`runtime/environments/examples/`](runtime/environments/examples/) | Sanitized environment templates; replace every `CHANGE_ME` value before use |
| [`operations/`](operations/) | Bootstrap, storage, backup/restore, networking, maintenance, and validation scripts with systemd templates |
| [`guides/`](guides/index.mdx) | Setup, architecture, runbook, maintenance, and script documentation |
| [`integrations/edge-vps/homelab.yml`](integrations/edge-vps/homelab.yml) | Example reverse-proxy routes for a separate edge VPS |

## Start with the guides

- [Operator index](guides/index.mdx) maps the stacks and their dependencies.
- [Setup guide](guides/setup.mdx) explains the configuration and deployment order.
- [Architecture](guides/architecture.mdx) documents network, storage, and failure boundaries.
- [Infrastructure and flow diagrams](guides/diagrams.mdx) show the network layout, request paths, and deployment sequence.
- [Runbook](guides/runbook.mdx) covers common service and recovery tasks.
- [Script reference](guides/scripts.mdx) explains the operational scripts.

## Safety before use

This is a demo, not a ready-to-deploy configuration. Review the guides and edit
all hostnames, addresses, disk identifiers, paths, service credentials, and
firewall rules for your environment. Environment templates contain placeholders
only. Keep live `.env` files, private keys, certificates, database data, and
backup repositories outside Git.

Storage and teardown scripts can change or remove data. Read the target paths
and safeguards in each script before running it. Host-specific validation uses
example values and must be adapted before it can pass on a real machine.

## Documentation preview

The guides are Mintlify-compatible. Install Mintlify CLI and run `mint dev` from
the repository root to preview them locally.
