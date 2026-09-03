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

The daemon re-asserts its MagicDNS decision once `RECONCILE_REASSERT_SECONDS` (default 60) have passed since the last apply, so out-of-band DNS changes self-heal within about a minute on both the event and safety-net paths. Values below `POLL_SECONDS` (60) cannot make the safety-net poll faster; invalid values fall back to the default. Override via the daemon's launchd `EnvironmentVariables` — the plist is rewritten on reinstall/upgrade, so re-apply after those. Steady-state re-asserts log at debug; set `DEBUG=1` via the daemon's launchd `EnvironmentVariables` to see them.

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
