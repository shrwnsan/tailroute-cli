# Changelog

All notable changes to tailroute CLI are documented in this file.

## [0.7.7] - 2026-09-02

### Fixed
- **Incremental adds no longer demand a new ssh config entry** — `tunnel add <peer> --remote-port …` on an already-registered tunnel ran the ssh preflight with a default `proxy-<peer>` alias and prompted to generate a config entry, even though the tunnel's registry entry stores the alias it was created with (`--ssh-alias`). The stored alias is now adopted when no `--ssh-alias` is given; an explicit flag still wins. First-time adds are unchanged.

## [0.7.6] - 2026-09-02

### Features
- **Comma-separated `--remote-port` lists** — `tunnel add <peer> --remote-port 8000,8765,10254,10255` replaces four invocations with one. Mixing forms works (`--remote-port 8000 --remote-port 8765,10254`); all new forwards still land in ONE incremental transaction: one journal, one job regeneration, one restart, all-or-nothing rollback.

### Fixed
- **Local-port collision when appending multiple forwards at once** — the first multi-forward incremental update handed every new forward the same local port: `tunnel_pick_port` consulted only the registry, which doesn't yet reflect ports allocated earlier in the same transaction. Allocation now excludes ports picked earlier in the call. Latent since the incremental-forward work (existing tests only ever appended one forward at a time); found by the new comma-list test.

## [0.7.5] - 2026-09-02

Hotfix: two launchd-vs-shell asymmetry bugs found by the first real tunnel add on a Homebrew install — both passed every sandboxed test and failed only in production.

### Fixes
- **TLS verification no longer misreads LibreSSL success as failure** — `/usr/bin/openssl` (LibreSSL) exits non-zero after a *successful* verified handshake, reporting the server's post-handshake close as an error. The verifier treated that as "TLS handshake failed" and rolled back every real `tunnel add` on macOS. Verification now judges the output (certificate present, `Verify return code: 0 (ok)`) instead of the exit status, and distinguishes untrusted/expired certificates from failed handshakes. The tests' fabricated openssl fixtures (exit 0, no certificate text) never exercised the real binary; the mock now mirrors captured LibreSSL behavior.
- **Preflight warns when tunnel auth can't survive launchd** — launchd jobs run without `SSH_AUTH_SOCK`, so a passphrase-protected key reachable only through the ssh-agent authenticates the interactive preflight but kills the tunnel job afterward. Preflight now re-tests auth without the agent socket and prints the fix (`ssh-add --apple-use-keychain` plus `UseKeychain yes` in the Host block) before any state is created.

### Added
- Tests: LibreSSL exit-status regression, untrusted-chain rejection, agent-dependent-auth warning.

## [0.7.4] - 2026-09-02

Hotfix batch for the production-asymmetry bugs found by the first real tunnel adds: code paths that only run as a non-root user against root-owned system paths — invisible to the test sandbox until now.

### Fixes
- **`/etc/hosts` temp files now land in a writable directory** — `hosts apply`/`adopt` asked `mktemp` to create their temp file *inside the hosts directory*, which only root can write; every non-root `tunnel add` failed before touching a single byte. The temp file is now created in the caller's `TMPDIR` and the privileged step installs it.
- **Hosts lock creation falls back to cached sudo** — the machine-wide lock lives under root-owned `/var/db/tailroute`, so a user-run CLI could never create it and reported the lock as busy forever. `acquire` now uses the cached sudo credential once per call to create the directory, hand it to the invoking user, and set it group/other-readable (0755, so stale-lock detection stays possible).
- **The sudo fallback actually fires** — the once-per-call guard referenced an uninitialised variable; under the CLI's `set -u` the first attempt at a root-owned lock parent aborted instead of falling back. Found by its own new regression test.
- **SSH preflight failures now say why** — the preflight check swallowed ssh's stderr; a `tunnel add` stopped on "ssh proxy-A failed" with no clue. It now surfaces what ssh said, with targeted hints (tailnet SSH policy denial, key auth failure, untrusted host key) and the exact re-run command including `--ssh-alias`.
- **`sudo -v` runs before prototype adoption** — the credential cache is now warmed before the hosts work that needs it, so a mid-transaction expiry can't strand a rollback.

### Added
- Top-level help documents `tunnel open`; `tunnel add` help documents serve-port autodetect, incremental `--remote-port`, and `--allow-unverified-tls`; `tunnel status` help matches what it actually reports.
- Tests: hosts edits via writable mktemp, lock acquisition via the sudo fallback, preflight policy-denial hints, help surface coverage.

## [0.7.3] - 2026-09-01

Hotfix: the daemon crashed at startup when run as a root launchd service.

### Fixes
- **Missing HOME under launchd** — system services run without `$HOME`, and the library path defaults expanded it under `set -u`, killing `tailroute daemon` instantly (services showed `error`, exit 78). The entry point now defaults `HOME` to `/var/root` when unset. Found by the first real `brew services start`.
- New integration test invoking the CLI with `HOME` unset.

## [0.7.2] - 2026-09-01

Completes the 0.7.1 hotfix: the library-location whitelist fix and its regression test were omitted from the 0.7.1 tag.

### Fixes
- **Location warning under Homebrew** — the sanity check in `lib-dns.sh` only accepted `bin/` directories; Homebrew installs load libraries from `lib/` and warned on every invocation. (The layout-resolution fix itself shipped in 0.7.1.)
- The Homebrew-layout integration test claimed in the 0.7.1 notes is actually in this release.

## [0.7.1] - 2026-09-01

Hotfix: the Homebrew formula was broken on first run.

### Fixes
- **Homebrew layout** — the entry script looked for its libraries beside itself, but the formula installs them to `../lib`; it now resolves both layouts (source checkout and Homebrew) and exits with a clear error if neither is found. First reported by the first-ever `brew install` of 0.7.0.
- **Location warning under Homebrew** — the library-path sanity check only accepted `bin/` directories, so Homebrew installs (`lib/`) emitted a warning on every invocation.
- New integration test simulating the Homebrew prefix layout (script in `bin/`, libraries in `../lib`), asserting clean and warning-free invocation.

## [0.7.0] - 2026-09-01

Hardening release for browser tunnels (PRD-004): valid TLS is mandatory at `add`, tunnels survive crashes mid-setup, and `status` reports the full truthful state. Plus incremental forwards, serve port autodetect, and `tunnel open`.

### Features
- **TLS identity verification at `add`** — the peer's Serve certificate must match its hostname or the add rolls back completely (no partial state); `--allow-unverified-tls` is the explicit opt-out, recorded in the registry (#6).
- **Durable, crash-safe transactions** — every add/update/remove step is journaled before it runs; after a crash, `status` reports the incomplete journal with recovery steps, and every failure path rolls back cleanly. `/etc/hosts` edits are serialized machine-wide (hosts lock), so concurrent users can't interleave. Registry schema bumped to v2 (`peerID`, `jobID`, `allowUnverifiedTLS`, `transactions[]`) with automatic in-place v1 migration (#9).
- **Unattended-proof SSH jobs** — LaunchAgent jobs now carry `BatchMode=yes`, `ConnectTimeout=10`, `StrictHostKeyChecking=yes`: they fail fast instead of hanging on a prompt, and pre-flight failures explain how to establish trust first. Per-tunnel logs are cleaned up on remove (#10).
- **Incremental forwards** — `tunnel add <peer> --remote-port N` on an existing tunnel appends a forward to the *running* job transactionally; any failure restores the previous healthy job, plist, and registry entry. Forward identity is `(peer, localPort, remotePort)`; duplicates are refused (#11).
- **Per-forward, self-repairing status** — `status` reports listener, backend, and TLS state for *every* forward (human + JSON `forwards` array), the adaptive path in use (socks5/direct), plist presence, and recognized orphans (stray hosts lines / launchd jobs) with exact repair commands. Mixed healthy/degraded forwards degrade the exit code (#11, #15).
- **Serve port autodetect** — `add` without `--remote-port` probes the peer's `tailscale serve status` and forwards to its real listen ports (silent fallback to 443 on locked-down peers) (#13).
- **`tunnel open <peer>`** — opens the tunnel's bookmarkable URL in the default browser; unknown peers exit 3 like `status` (#14).

### Fixes
- **`sudo tailroute uninstall` cleans the correct user** — resolves the invoking user via `SUDO_USER`/dscl instead of root's `$HOME`; removes that user's tunnels, registry, LaunchAgents, and logs (#8).
- **Target-aware SOCKS5 probe** — the adaptive wrapper checks SOCKS readiness per peer and falls back to direct; legacy always-proxy wrappers migrate automatically (#7).

### Internal
- `TUNNEL_WAIT_TRIES` knob — listener-wait depth configurable; test suite ~9 min → ~80 s, production default unchanged (#12).

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
