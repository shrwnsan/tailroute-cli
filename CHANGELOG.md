# Changelog

All notable changes to tailroute CLI are documented in this file.

## [0.8.11] - 2026-09-03

### Added
- **`tunnel check <peer>`** — the browser's truth. A read-only diagnostic that walks the exact browser path from this Mac — hosts mapping → local listener → TLS/SNI → HTTP → adaptive branch — against the tunnel's registry data, and prints a per-layer verdict naming the repair for the first break. It is the first command that can see the 502 class: a peer's Serve upstream down behind a perfectly valid certificate reports "fix the service on the peer", where `status` (transport facts) and `add` (cert-only verification) both reported healthy. Inert by construction and test-enforced: probes and prints only — byte-identical registry, hosts, and launchd state, zero ssh to the peer. Exit codes: 0 path proven, 1 failure or no verdict, 2 usage, 3 unknown peer.
  - App answers (404/500) are reported as *delivered* — the path is proven; only Serve-generated 502/503/504 fail the verdict, and a multi-forward tunnel degrades only when a real path failure exists.
  - A registry entry with no forwards gets "no verdict", never a false-healthy claim.
  - Deliberate boundaries: explicit peer required (no bare form, no flags, no `--json` in v1); `--allow-unverified-tls` tunnels always show the TLS layer as unverified; the standalone e2e script is untouched.
  - Help now carries the read-only verb map: *status = inventory · drift = the peer's claim · check = the browser's truth*.

### Fixed
- **The stale-tunnel note names the repair** — `status`'s stale case (hosts entry present but job not running) was the only detected-but-verbless state in the renderer; the note now ends with `repair: tailroute tunnel restart <peer>`, matching the plist-missing and orphan precedents.
- Tests: 330 → 348.

## [0.8.10] - 2026-09-03

### Fixed
- **Shutdown can no longer leave MagicDNS in the wrong state** — the poll subshell previously died instantly on daemon shutdown (subshells reset inherited traps), so a reconcile killed mid-toggle orphaned the in-flight `tailscale` RPC and lost its state write — and because shutdown restored MagicDNS *before* killing the poll, an in-flight disable could land after the restore and leave MagicDNS in the opposite of the intended state. The poll now stops cooperatively: it traps TERM/INT, lets an in-flight reconcile run to completion (state written, lock released) and kills only its tick sleep (`sleep` runs as `sleep N & wait` so an idle stop is immediate). A shared `stop_poll` makes the signal and EXIT paths quiesce identically, and shutdown stops the poll *before* reading the manifest, so the restore acts on the state the toggle actually left. A TERM landing in the tick's spawn window is re-checked after the pid is captured, so the stop cannot block out the full poll interval. Worst-case shutdown latency is one in-flight tailscale RPC; launchd's default 20s `ExitTimeOut` remains the backstop (no `ExitTimeOut` is configured; a wedged `tailscaled` can still make shutdown unbounded — same failure shape as earlier releases, not a regression).
- **Steady-state re-asserts log at debug** — the periodic re-assert shared its mode-branch INFO lines with genuine transitions, so a quiet routing table produced ~1440 INFO lines/day (plus the unconditional `[DNS]` audit line per apply). INFO now means "something changed or something's wrong": genuine transitions and `reconcile force` still log INFO; steady-state re-asserts and unchanged ticks log at debug (set `DEBUG=1` via the daemon's launchd `EnvironmentVariables` to see them). The `[DNS]` audit line remains the per-apply heartbeat. Completes the log-noise work begun in 0.8.8.
- Tests: cooperative poll stop (in-flight toggle completes, shutdown ordered after it, spawn-gap stop, prompt idle exit), POLL_PID clear, re-assert log level across all three modes. 324 → 329.

## [0.8.9] - 2026-09-03

### Fixed
- **Time-based re-assert with a uniform self-heal SLA** — the re-assert interval is now wall-clock (`RECONCILE_REASSERT_SECONDS`, default 60, replaces `RECONCILE_REASSERT_TICKS`): out-of-band MagicDNS changes self-heal within ~60s on both the event and safety-net paths, instead of ~15 minutes on a quiet routing table. Implemented with bash's `SECONDS` (no fork per check); system sleep counts as elapsed, so the daemon re-asserts on the first tick after wake, and a backward wall-clock step (NTP) costs at most one interval before a re-assert.
- **The poll subshell no longer outlives the daemon** — a daemon exit without a signal (route-monitor stream death, a `set -e` failure) orphaned the poll: it kept reconciling every 60s forever, reparented to launchd and invisible to `launchctl`, adding a duplicate apply per minute per orphan. The daemon now kills the poll via an EXIT trap, and a dead monitor stream logs a WARN and exits non-zero so launchd restarts a clean daemon.
- **Policy applies at daemon startup** — a freshly started daemon reconciles once instead of waiting up to 60s for the first route event or poll tick; startup failure is non-fatal (the event loop retries) so launchd KeepAlive cannot crash-loop. With applied state inherited at fork, the poll's first tick is a genuine time-gated re-assert rather than a duplicate apply.
- Tests: re-assert interval, clock-step-back guard, invalid-value sanitization, startup reconcile (applies / failure-tolerant / lock-held), monitor-EOF restart with poll cleanup. 318 → 324.

## [0.8.8] - 2026-09-03

### Fixed
- **Reconcile logs and toggles on mode transitions, not every invocation** — route events can fire every few seconds while Tailscale is up, and `reconcile()` re-ran `enable/disable_magicdns` and logged an INFO line on every call (~21k identical lines/day under launchd, each a `tailscale` CLI spawn). Unchanged modes now short-circuit at debug level; MagicDNS is re-asserted every `RECONCILE_REASSERT_TICKS` (default 15) unchanged ticks so out-of-band changes still self-heal (~1 minute while route events flow, up to ~15 minutes on a quiet routing table). `reconcile force` (used by the SIGHUP handler) bypasses the short-circuit. Invalid `RECONCILE_REASSERT_TICKS` values fall back to the default instead of fatally aborting under `set -u`.
- Tests: unchanged-skip, re-assert threshold, force bypass, vpn-transition, tick-input sanitization, log-level pin. 312 → 318.

## [0.8.7] - 2026-09-03

### Fixed
- **`tunnel status` shows every tunnel, not just the first** — the per-forward backend probe's ssh call ran inside the rows loop and consumed its stdin, swallowing every registry entry after the first; multi-tunnel users saw exactly one peer in status while `list` and `peers` showed them all. The probe and the tailscale lookup now close stdin.
- Tests: two-peer registry renders both peers. 311 → 312.

## [0.8.6] - 2026-09-03

### Changed
- **Sanitized test fixtures and docs of real environment values** — a real tailnet hostname, real peer hostnames, and the real peer IP had leaked into test fixtures, the e2e script default, and one changelog line; all replaced with generic equivalents (`prime.tailnet.ts.net`, `micro.tailnet.ts.net`, `100.100.100.100`). No behavior change; 311/311.

## [0.8.5] - 2026-09-03

### Fixed
- **Serve-port autodetect reports the listen port, not the backend port** — the autodetect probe ran `tailscale serve status` without `--json`, and its human-text fallback regex matched the indented `|-- proxy http://127.0.0.1:<backend>` lines while missing implicit-443 listen lines (no port in the URL). A peer serving `https://<peer>.ts.net → http://127.0.0.1:3001` autodetected **3001** — a port with no serve listener — so bare `tunnel add` produced a probe warning and a TLS-verify rollback. The probe now requests `--json` (listen ports from Web/TCP keys), and the text fallback for ancient builds only trusts column-0 listen URLs, defaulting https to 443. Same-port proxying (`:10254 → :10254`) had masked the bug on same-port proxies; implicit-443 peers exposed it.
- Tests: real captured fixtures (implicit-443 text, JSON listen-vs-backend, multi-port order, empty/no-config, end-to-end add). 305 → 311.

## [0.8.4] - 2026-09-02

### Features
- **`tunnel peers`** — registered tunnels at a glance: one line per tunnel with the peer, its ssh alias when it differs from the label, forward count, and the primary URL. Registry-only — no probing, instant, unlike `status`'s per-forward ssh checks; `tunnel list`'s JSON contract is unchanged. Empty registry prints the add hint and exits 0.

### Tests
- Peers index (alias, count, primary URL, zero remote probes) and empty-registry hint. 303 → 305.

## [0.8.3] - 2026-09-02

### Fixed
- **`tunnel status` parses rows without collapsing empty fields** — bash `read` collapses consecutive whitespace-IFS delimiters, so the *empty* notes field of every healthy tunnel (tab-tab in the row) shifted all later fields one slot left: the v0.8.2 `Alias:` line never rendered in production, and the plist state leaked into a ghost `Notes: present` line that real status output has shown all along. The rows themselves were always correct (the JSON view proved it) — only the renderer's parse was broken. Tabs are now translated to the unit separator before the read, so empty fields survive; the preflight lookup parse (where an empty DNS field would shift IP/suffix/online) got the same hardening.
- Found live on 0.8.2: production status showed no `Alias:` line while the JSON view did.
- Tests: regression case with the healthy empty-notes row. 302 → 303.

## [0.8.2] - 2026-09-02

### Fixed
- **Backend probes work on peers without `nc`** — the probe ran `/usr/bin/nc` on the peer; Ubuntu peers without netcat installed made every probe exit 127, so `tunnel status` reported "backend not accepting" even for healthy forwards (found live: the production peer has no `nc` at all — which also masked the v0.7.8 probe-target fix). The probe now uses `nc` from the peer's PATH when present and falls back to bash's built-in `/dev/tcp` when it isn't. Verified against a live listener with `nc` hidden from PATH.

### Added
- **`tunnel status` shows the ssh alias** — an `Alias: <name>` line when a tunnel's stored `--ssh-alias` differs from its peer label (default setups stay uncluttered), and `sshAlias` in `status --json` for parity with `tunnel list`.
- Tests: probe fallback on nc-less peers, refusing-target fidelity, alias-line presence/absence (including legacy entries without the key), JSON parity. 295 → 302.

## [0.8.1] - 2026-09-02

### Features
- **`tunnel drift` with no peer audits every registered tunnel** — one section per peer in registry order (same format as the single-peer report), probed sequentially. Exit 0 when every peer produced a verdict; 1 when any peer's probe failed or its serve reply was unparseable. An empty registry prints a hint and exits 0. `tunnel drift <peer>` is unchanged (including unregistered-peer support), and flags are still refused in both forms — the read-only, applies-nothing invariant holds and is now tested for the loop path too.
- Tests: 5 new (290 → 295).

## [0.8.0] - 2026-09-02

### Features
- **`tunnel drift <peer>`** — a read-only advisor that compares what the peer's `tailscale serve` config claims (queried over ssh) against your local registry: forwards the registry is missing (with the exact `tunnel add` command to run), full forward sets with URLs, serve entries for peers you haven't registered, and "serves nothing" verdicts. The probe has three outcomes (claims / probe failed / unrecognizable reply); the command takes no flags by design — drift applies nothing, ever: it cannot change the registry, hosts, launchd jobs, or the peer's serve config, and prints copy-pasteable commands for you to run instead.
- Safety is tested, not promised: every outcome asserts a byte-identical snapshot of the config dir, hosts file, and LaunchAgents (listings and bytes), and that the only remote command ever executed is `tailscale serve status`.
- Tests: 24 new (probe outcomes, exit-code discipline, unregistered peers, inertness). 262 → 290.

## [0.7.9] - 2026-09-02

Hardening for the incremental-update transaction (T-437/T-438, spec from the adversarial review).

### Fixed
- **Update transactions journal before they mutate anything** — the registry was rewritten *before* the journal write, so a crash in that window left a journal that couldn't vouch for the state it found (and a failed journal write is now fatal to the operation instead of ignored). The update path also replaces its registry entry via a single atomic operation instead of remove-then-add, closing a two-save window where a crash could lose the entry outright.
- **Snapshot failures abort loudly** — a missing job plist or a failed `plist.prev` copy used to be silently ignored, leaving rollback with nothing to restore; the update now refuses to start unless the snapshot exists.
- **`tunnel journal clear [--force]`** — incomplete journals can be cleared by rule instead of `rm`: `add` refuses without `--force` (live hosts mapping), `update` clears with the remove+add remedy printed, `remove` clears freely, completed entries always clear. Status hints now point at the command.

### Added
- **Registry `transactions[]` history** — every add/update/remove records `{op, ts, forwards before/after, source}`, capped at the last 20; evidence of the final transaction survives in the `.bak` even for removed entries.
- Tests: 15 new (journal-before-mutation, fatal boundaries, per-op clear rules, transaction recording/capping, CLI wiring). 251 → 262.

## [0.7.8] - 2026-09-02

### Fixed
- **Backend health checks probe the peer's Tailscale IP, not its loopback** — the `tunnel add` remote-port soft check and `tunnel status`'s per-forward backend check ran `nc` against the peer's loopback address, where Tailscale Serve listeners never bind; every healthy serve target warned "remote port N not accepting" and status showed "backend not accepting" for working forwards. Both now probe the same IP:port the launchd forward actually dials.
- **`Forward added` printed twice** on incremental adds — once before the URL list and once after; now printed exactly once, after the URLs.

### Added
- Tests: probe targets the peer ts IP on both the add and status paths, the WARN still fires when the target refuses, and the single "Forward added" placement. 247 → 251.

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
