# Changelog

All notable changes to tailroute CLI are documented in this file.

## [0.6.0] - 2026-08-25

### Features
- **Browser tunnels (PRD-004 Phase 1)** — `tailroute tunnel add <peer>` opens a peer's Tailscale Serve endpoint in any browser with valid TLS while the VPN stays connected: launchd-managed SSH forwards + managed `/etc/hosts` block. `add`/`remove` are transactional (user-space lock, rollback with manual-revert guidance); `status` distinguishes transport from backend health, detects IP/tailnet-suffix drift and SSH key rotation, and supports `--json` with exit codes 0/1/2/3; `list`, `restart`, `--remote-port`, and `--ssh-alias` included. Existing hand-rolled prototype jobs are adopted via `--adopt` instead of colliding.
- **Adaptive ProxyCommand by default** — `tailroute proxy-config ssh` now generates an ssh config that routes through the SOCKS5 proxy when it is up and connects directly when it is not (works in router-side-VPN topologies where the always-proxy form broke every connection). `--no-adaptive` keeps the previous raw form; `--replace-wrapper` guards the installed `~/.ssh/tailroute-proxy.sh`.
- **Install-time integrity** — `do_install()` records a SHA-256 manifest of the installed wrapper and libs (`/var/db/tailroute/installed.checksums`, root:wheel 0600); the daemon verifies it before sourcing any lib and refuses to start on mismatch; the proxy binary is `codesign`-verified at install and daemon start.
- `tailroute uninstall` now removes per-user browser tunnels (hosts entries, plists, launchd jobs).

### Fixes
- Proxy download URL now points at tailroute-cli releases (was the main repo, which never hosted the assets).
- Release binaries are built on a macOS runner so the Go linker adhoc-signs them (arm64 macOS refuses to run unsigned binaries, and the new install-time verification requires a valid signature).

### Security
- Peer-derived data (hostnames self-reported by other tailnet members) is validated before any use in plists, /etc/hosts, ssh config, or the registry; `/etc/hosts` mappings are structurally limited to the current tailnet's MagicDNS suffix — arbitrary-domain mapping is impossible.
- Tunnel ssh jobs pin loopback binds (`127.0.0.1`), disable ControlMaster sharing, and log under `~/Library/Logs/Tailroute` with `0600` files.

## [0.5.0-beta.2] - 2026-04-09

### Fixes
- Proxy node now persists identity across restarts (`--ephemeral` defaults to `false`). Previously, ephemeral mode required re-authentication on every start.
- `tailroute proxy start` now passes `TS_AUTHKEY` to the proxy binary, enabling automatic authentication when the env var is set.
- Proxy auth wait loop now polls for up to 2 minutes for the `Running` state, reliably printing the browser auth URL. Previously, the one-shot check often missed the URL before the SOCKS5 server started.

## [0.5.0-beta.1] - 2026-03-27

First public beta release.

### Features
- Automatic MagicDNS toggle when Tailscale + VPN are both active
- SOCKS5 proxy (`tailroute-proxy`) for Tailscale mesh access through VPN
- SSH config helpers (`tailroute proxy-config ssh`)
- Shell helpers (`tailroute proxy-config shell`)

### Install
```bash
brew install shrwnsan/tap/tailroute-cli
sudo tailroute install
```

### Requirements
- macOS 12+ (Monterey or later)
- Tailscale CLI daemon
- VPN using `utun` interface

[Apache License 2.0](LICENSE)
