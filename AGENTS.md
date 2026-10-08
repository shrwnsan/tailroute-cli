# AGENTS.md

Guidance for AI agents and coding assistants working on tailroute-cli.

## Overview

**tailroute-cli** is the free, open-source core of tailroute: a bash
CLI + launchd daemon that toggles MagicDNS so Tailscale and a VPN work
simultaneously on macOS, plus `tailroute-proxy` (a Go SOCKS5 proxy on
tsnet) and the marketing/docs website in `site/`. Distributed via
Homebrew (`shrwnsan/tap/tailroute-cli`); a closed-source menu-bar app
is the other frontend.

## Layout

| Path | What it is |
|---|---|
| `bin/tailroute.sh` | main executable: command dispatch, install/uninstall, integrity gate |
| `bin/lib-*.sh` | detection, DNS, event loop, locking, logging, validation, tunnel libs |
| `proxy/` | Go SOCKS5 proxy (`tailroute-proxy`), built for darwin arm64/amd64 |
| `site/` | landing page + `/docs` (vanilla HTML/CSS/JS; PR-checked by `tests/test-check-site.sh`) |
| `tests/` | test harness — `bash tests/run-tests.sh` runs everything |
| `etc/` | launchd plist, newsyslog config |

## Commands

```bash
bash tests/run-tests.sh      # full suite — must pass before any PR
shellcheck bin/*.sh          # linting — must pass, no exceptions
```

Add unit tests to `tests/test-lib-*.sh` for lib changes. Site changes
should pass `tests/test-check-site.sh`.

## Code Style

- **Language**: bash, POSIX-compatible
- **Shellcheck**: must pass — zero warnings tolerated
- **Indentation**: 2 spaces
- **Security**: absolute paths for every system invocation, validate all
  inputs (interface names `utun\d+`, CIDR against `100.64.0.0/10`), no
  `eval`, escape everything that reaches a shell
- The daemon runs as root: fail-safe first — when in doubt, do nothing

## Release & Versioning

Two independent version streams ship from this repo — see
[docs/versioning.md](docs/versioning.md) for the full policy:

- bare `v*` tags = the CLI package (bash CLI + bundled proxy) → feeds
  the Homebrew formula. Cut a release only when `bin/`, `etc/`, or
  `proxy/` changes; a tag must carry the proxy binaries + `.sha256`
  sidecars to count as a release.
- `app-v*` tags = the menu-bar app's releases (DMG artifacts only;
  source not in this repo) → feed the Homebrew cask. Do not sync the
  two streams' numbers.
- Bump the `VERSION` constant in `bin/tailroute.sh` in the same commit
  that gets tagged — `tailroute --version` must match its tag.
- The install-time SHA-256 manifest + codesign integrity gate stays
  **ahead of the lib `source` lines** in `bin/tailroute.sh`. Do not
  reorder startup so any lib loads before the gate.

## PR & Commit Conventions

- Conventional commits: `feat(site): …`, `fix(bin): …`, `docs: …`
- PR titles follow the same grammar; scope names the touched area
- Keep PRs, comments, commit messages, and release notes self-contained:
  describe changes on their own merits, without links to other repos or
  their issues
- One logical change per PR; docs-only changes welcome

## Debugging

```bash
tail -f /var/log/tailroute.log
tailroute --dry-run
tailscale debug prefs | grep -i dns
```
