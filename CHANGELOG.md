# Changelog

All notable changes to tailroute CLI are documented in this file.

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
