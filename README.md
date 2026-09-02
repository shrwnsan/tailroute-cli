# tailroute

Automatic Tailscale + VPN coexistence for macOS.

## Install

```bash
brew install shrwnsan/tap/tailroute-cli
sudo tailroute install
```

That's it. The daemon runs automatically in the background.

## What it does

When you have both Tailscale and a VPN (NordVPN, ProtonVPN, etc.) connected:

- **DNS fix**: MagicDNS breaks your internet → tailroute toggles it automatically
- **Mesh access**: VPN blocks Tailscale IPs → use the built-in SOCKS5 proxy to reach peers

## Tuning

The daemon re-asserts its MagicDNS decision every `RECONCILE_REASSERT_TICKS` reconcile ticks (default 15) so out-of-band DNS changes self-heal: within ~1 minute while route events are flowing, up to ~15 minutes on a quiet routing table. Invalid values fall back to the default. Override via the daemon's launchd `EnvironmentVariables` — the plist is rewritten on reinstall/upgrade, so re-apply after those.

## Usage

```bash
tailroute status    # Check daemon and network state
tailroute --help    # See all commands
```

## SOCKS5 Proxy

Reach Tailscale peers through VPN:

```bash
tailroute proxy auth           # First-time: authorize with Tailscale
tailroute proxy start          # Start proxy on 127.0.0.1:1055
tailroute proxy-config ssh     # Generate SSH config helpers
```

## Requirements

- macOS 12+
- Tailscale (`brew install tailscale`)
- A VPN that uses `utun` interface

## Docs

- [BUILD.md](BUILD.md) — Build from source
- [CONTRIBUTING.md](CONTRIBUTING.md) — Development guidelines

## License

[Apache 2.0](LICENSE)
