# Versioning

tailroute ships two independently versioned products from this repository.
They share a repo, not a version line.

## The two streams

| Stream | What it is | Tag grammar | Homebrew surface |
|---|---|---|---|
| CLI package | `bin/tailroute.sh` + `bin/lib-*.sh` + the `tailroute-proxy` Go binary | bare `v*` (e.g. `v0.8.17`) | formula `tailroute-cli` |
| Tailroute app | the closed-source Swift menu-bar app (source not in this repo) | `app-v*` (e.g. `app-v0.8.19`) | cask `tailroute` |

- The CLI package version covers **both** the bash CLI/daemon and the
  bundled proxy binary. They are one shippable unit — the formula always
  installs them together — so they move in lockstep by design.
- The app is a separate product with its own cadence. Its numbers do **not**
  need to match, and should not be re-synced with, the CLI package's.
  Diverging numbers are the healthy state, not drift.

## Release rules

1. **Cut a CLI-package release only when `bin/`, `etc/`, or `proxy/`
   changes.** Site, docs, and CI-only changes release nothing. (Example:
   27 site-only commits landed between `v0.8.17` and the `app-v0.8.19`
   release without a CLI release — that is correct.)
2. A CLI-package release means: tag `vX.Y.Z` **and** a GitHub release
   carrying the `tailroute-proxy-darwin-{arm64,amd64}` binaries and their
   `.sha256` sidecars. The tag alone is not a release.
3. An app release means: tag `app-vX.Y.Z` and a GitHub release carrying
   `Tailroute-X.Y.Z.dmg` + `.sha256` sidecar.
4. Tap bumps follow the matching stream only: formula ← bare `v*`,
   cask ← `app-v*`. An app release never moves the formula, and vice versa.
5. Bump the `VERSION` constant in `bin/tailroute.sh` **in the same commit
   that is tagged**. `tailroute --version` must match its release tag.
   (Missed once at v0.8.17 — the tag reported 0.8.16.)

## SemVer

Versions are `0.x` until the app's notarized v1.0. From v1.0 both streams
follow SemVer 2.0.0: the CLI's public surface (commands, flags, config
files, daemon behavior) is its API — breaking changes bump the major.
