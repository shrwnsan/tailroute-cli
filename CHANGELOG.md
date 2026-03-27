# Changelog

All notable changes to tailroute are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-03-24

### Changed
- **Performance** — Async file I/O for logging, non-blocking process management
- **Reliability** — Timer scheduling on main RunLoop, timeout protection for CLI commands
- **Documentation** — Consolidated and streamlined reference docs

### Technical
- Logger: async writes via dedicated DispatchQueue
- ProxyManager: non-blocking stop/restart
- ReconciliationEngine: guarded proxy starts, fixed health timer
- TailscaleDNS: 10s timeout prevents indefinite hangs

## [0.2.0] - 2026-03-24

### Added
- **SOCKS5 Proxy** — Built-in SOCKS5 proxy (`tailroute-proxy`) routes traffic through Tailscale mesh while VPN is active
- **Auto-start/stop** — Proxy automatically starts when VPN + Tailscale both active, stops when either disconnects
- **Proxy config commands**:
  - `tailroute proxy-config ssh` — Generate SSH config snippets for Tailscale peers
  - `tailroute proxy-config shell` — Generate shell helpers (`sshproxy`, `curlproxy`)
- **Status display** — `tailroute status` shows proxy running/stopped with PID
- **Menu bar indicator** — Swift app menu bar shows proxy status (Active/Inactive)

### Technical
- Go-based proxy binary using Tailscale's `tsnet` for Tailscale-native routing
- SOCKS5 binds to `127.0.0.1:1055` (localhost only, no-auth safe)
- Integrated into main install script

## [0.1.1] - 2026-03-20

### Fixed
- **Status detection** — Now detects system-level launchd daemons started by root via `pgrep` fallback
- **Install optimization** — Only copies files when source is newer, avoiding "identical file" warnings

### Added
- **Version flag** — `tailroute --version` shows current version
- **Version in status** — `tailroute status` now displays version number

## [0.1.0] - 2026-02-17

### Added
- **Event-driven daemon** — Monitors routing table changes in real-time via `route -n monitor`
- **Tailscale + VPN coexistence** — Automatically toggles MagicDNS to prevent DNS conflicts
- **Interface detection** — Identifies Tailscale (CGNAT `100.x.x.x`) and VPN (`utun` default route) interfaces
- **MagicDNS toggle** — Disables DNS when VPN active, restores when VPN disconnects
- **Debounce logic** — 2-second stability window prevents cascading reconciliations on VPN flapping
- **Safety-net polling** — 60-second fallback poll catches missed `route monitor` events
- **Signal handlers** — Clean shutdown (SIGTERM), manual trigger (SIGHUP), MagicDNS restoration on exit
- **State manifest** — Persistent tracking of MagicDNS state (`/var/db/tailroute/state.manifest`)
- **Concurrency lock** — File-based lock prevents overlapping reconcile operations
- **launchd integration** — Daemon auto-starts at login, auto-restarts on failure
- **CLI subcommands** — `status`, `--dry-run`, `install`, `uninstall`
- **Security hardening**:
  - Absolute paths for all system commands
  - Strict input validation (interface names, IPs, CIDRs)
  - `root:wheel` ownership on installed files
  - Robust JSON parsing with `plutil`
  - Secure debug logging to `/var/db/tailroute/debug.log` (0600)
  - Lock directory ownership validation
  - Console user validation to prevent injection
  - Lock PID validation to prevent hijacking
- **Comprehensive testing** — 124 unit tests across 8 library modules
- **Documentation**:
  - User guide (README.md)
  - Product spec (docs/plans/prd-001-tailroute.md)
  - Technical design (upcoming ARCHITECTURE.md)
  - Phase summaries (9 phases documented)
  - Security audit (Eval-002)

### Support
- **macOS 12+** (Monterey or later)
- **Tailscale** — CLI daemon (recommended) or GUI app (limited)
- **VPNs** — Any that use `utun` interface with default route (NordVPN, ProtonVPN, ExpressVPN, Surfshark, etc.)

### Known Limitations
- **MagicDNS hostnames disabled** — While VPN is active, `hostname.tailnet.ts.net` won't resolve. Use IP addresses or disconnect VPN for hostname access.
- **GUI app limitations** — `tailscale set --accept-dns` may not reliably toggle with GUI app. CLI daemon recommended.
- **Single VPN detection** — Logs warning and skips action when multiple VPN interfaces detected.

### Security & Performance
- **Memory**: 3-5 MB RSS
- **CPU idle**: <0.1%
- **Disk I/O**: <1 KB/min
- **Battery impact**: Negligible (~0.3% over 8 hours)
- **No external network calls** — Fully offline operation
- **No telemetry** — Open source, auditable

### Testing
- 124/124 unit tests passing (100%)
- Real-world verified with Tailscale + NordVPN
- All security hardening tested

### Files
- `bin/tailroute.sh` — Main daemon (v0.1.0)
- `bin/lib-*.sh` — 8 modular libraries
- `tests/run-tests.sh` — Test harness + 8 test suites
- `install.sh` / `uninstall.sh` — Installation scripts
- `README.md` — User guide
- `LICENSE` — Apache 2.0

---

## [0.2.0] - 2026-02-18 (Beta)

### Added
- **Native Swift app** — Rewritten in Swift 5.9 with 656 LOC across 10 modules
- **Menu bar UI** — Real-time status icon in system menu bar (NSStatusBar integration)
- **State machine** — Three-state tracking (Idle, Tailscale Only, VPN Active)
- **Preferences window** — SwiftUI controls for debounce and polling intervals
- **DMG installer** — Drag-to-install workflow (88K compressed)
- **Notification system** — UNUserNotificationCenter for MagicDNS state changes
- **Release build** — Optimized arm64 binary with automatic app bundling

### Architecture
- 5 core logic modules: Config, InterfaceDetection, TailscaleDNS, ReconciliationEngine, RouteMonitor
- 5 UI modules: StatusMenuController, PreferencesWindow, NotificationManager, AppDelegate, tailroute
- Combine reactive binding for state updates
- UserDefaults persistence for settings

### Fixed in Phase 9D
- **Preferences window** — Converted to SwiftUI-hosted NSWindow with floating level
- **Logging system** — Structured logging to `~/Library/Logs/Tailroute/tailroute.log`
- **Interface detection** — Fixed ifconfig/inet parsing, Tailscale now detected correctly
- **Close button** — Wired to NSWindow.close() (SwiftUI dismiss() doesn't work in NSHostingView)
- **RouteMonitor debounce** — Timer now dispatches to main RunLoop (was silent no-op on GCD queue)
- **Subprocess timeouts** — 5s timeout on ifconfig/netstat to prevent indefinite hangs
- **UI thread safety** — reconcile() subprocess work moved off main thread
- **LSUIElement** — App no longer shows in Dock (menu bar–only)
- **Unit tests** — Added InterfaceDetection, Config, and NotificationManager test suites

### Platform Support
- macOS 12+ (same as v0.1.0)
- Tailscale CLI daemon or GUI app
- Works alongside any VPN using `utun` interface

---

## Future Versions

### [0.3.0+] — Roadmap
- **Notarization** — Apple code signing for frictionless distribution (T-204, high priority)
- ⏸️ **Auto-updates** — Sparkle framework (deferred; Homebrew handles updates)

#### Cancelled
- ~~MagicDNS split DNS~~ — Research completed 2026-02-23: not viable (VPN captures CGNAT-range packets)
- ~~Multi-VPN support~~ — Edge case; current fail-safe is appropriate
- ~~Preferences UI~~ — Already shipped in v0.2.0

---

## Links

- [README](README.md) — User guide
- [Contributing](CONTRIBUTING.md) — How to contribute
- [Architecture](docs/ref/ARCHITECTURE.md) — Technical design (v0.1.0)
- [Swift Architecture](docs/ref/SWIFT-ARCHITECTURE.md) — Technical design (v0.2.0)
- [FAQ](docs/ref/FAQ.md) — Common questions
- [Security](docs/ref/SECURITY.md) — Threat model
- [Product Spec](docs/plans/prd-001-tailroute.md) — Full PRD
