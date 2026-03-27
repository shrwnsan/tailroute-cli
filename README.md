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
