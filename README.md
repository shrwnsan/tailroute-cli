# tailroute

**tailroute-cli** — Automatic Tailscale + VPN coexistence for macOS.

## Install

```bash
brew install shrwnsan/tap/tailroute-cli
sudo tailroute install
```

That's it. The daemon runs automatically in the background.

Menu bar app (same engine, native UI, free during early access):

```bash
brew install --cask shrwnsan/tap/tailroute
```

The app is not notarized yet, so macOS blocks its first launch and may ask again after an upgrade. Open System Settings → Privacy & Security and choose Open Anyway next to the message about Tailroute. If the dialog offers Move to Trash, choose Done instead, because Move to Trash deletes the app. If the app disappears from Applications, run `brew reinstall --cask shrwnsan/tap/tailroute`.

Or let the installer do both steps for you:

```bash
curl -fsSL https://raw.githubusercontent.com/shrwnsan/tailroute-cli/main/install.sh | bash
```

The script still installs through Homebrew's formula, so checksums stay enforced — it just drives `brew` and the daemon install in one go.

## What it does

When you have both Tailscale and a VPN (NordVPN, ProtonVPN, etc.) connected:

- **DNS fix**: MagicDNS breaks your internet → tailroute toggles it automatically
- **Mesh access**: VPN blocks Tailscale IPs → use the built-in SOCKS5 proxy to reach peers

## VPN compatibility

Tested against Mullvad and NordVPN; the daemon classifies routing changes from any VPN that takes the default route (corporate clients included). Current matrix and notes live on the [homepage](https://tailroute.app/). If your VPN behaves differently, [report it](https://github.com/shrwnsan/tailroute-cli/issues/new?template=vpn-compat.yml) — reports feed the compatibility notes.

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

## Browser tunnels

Register a peer's Tailscale Serve dashboard once, then open it in any browser at a stable URL with a valid `.ts.net` certificate. Tunnels are launchd-managed SSH forwards and adapt to the network: through the SOCKS5 proxy while a VPN is up, direct otherwise.

```bash
tailroute tunnel add mypeer     # → https://mypeer.<tailnet>.ts.net:8443
tailroute tunnel open mypeer    # open it in your default browser
tailroute tunnel peers          # every tunnel and its URL, at a glance
```

`add` needs `sudo` only for the `/etc/hosts` mapping, which applies to every user of the Mac. It checks that the certificate presented at the URL matches the peer's name and unwinds everything if it does not. `--allow-unverified-tls` skips that check; the choice is recorded, and `open`, `list`, and `status` keep warning about the tunnel until you re-add it without the flag. Tunnel jobs never prompt, so the peer's SSH host key must already be trusted. If it is not, `add` tells you the one `ssh` command to run.

Pause and resume without losing the URL:

```bash
tailroute tunnel stop mypeer    # parked across logins and reboots; registry and hosts mapping stay
tailroute tunnel start mypeer   # same port, same URL, no sudo
```

When something looks wrong:

| Command | Answers |
|---|---|
| `tunnel status [peer]` | Inventory and health: job, hosts, plist, and per-forward listener, backend, and TLS state |
| `tunnel check <peer>` | What a browser would see, naming the first layer that breaks and its fix |
| `tunnel drift [peer]` | Whether the peer's Serve config still matches what you registered |
| `tunnel restart [peer]` | Restart an unhealthy job (refuses a stopped one; use `start`) |
| `tunnel repair <peer>` | Rebuild a missing launchd plist from the registry, keeping ports and URLs |
| `tunnel journal clear` | Recover after an add, update, or remove was interrupted |

`tailroute tunnel --help` lists every option, and `tunnel remove <peer>` cleans up the hosts entry, job, and registry row.

## Requirements

- macOS 15+ (Sequoia or later)
- Tailscale (`brew install tailscale`)
- A VPN that uses `utun` interface

## Docs

- [Homepage](https://tailroute.app/) — install, security, limitations
- [tailroute manual](https://tailroute.app/docs/) — the full man page
- [BUILD.md](BUILD.md) — Build from source
- [CONTRIBUTING.md](CONTRIBUTING.md) — Development guidelines

## A note on the name

"tailroute" is a more popular name than expected — a few unrelated projects answer to it, and none of them is this one. This is the macOS daemon that keeps your VPN and your Tailscale mesh out of each other's way. If `brew install shrwnsan/tap/tailroute-cli` brought you here, you're in the right place — and this project is not affiliated with any of the others.

## License

[Apache 2.0](LICENSE)
