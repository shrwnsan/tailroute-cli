# tailroute

Automatic Tailscale + VPN coexistence on macOS.

tailroute is a lightweight daemon that detects when both Tailscale and a commercial VPN (NordVPN, etc.) are active, and automatically toggles MagicDNS so both work simultaneously — no manual steps required.

## The problem

Most macOS VPN apps (NordVPN, Surfshark, ProtonVPN, ExpressVPN) don't support split tunneling. When connected, Tailscale's MagicDNS (`100.64.0.2`) becomes unreachable through the VPN tunnel, causing DNS timeouts. Internet access fails.

## Known Limitation: VPN Network Extensions Block Tailscale Mesh

⚠️ **Important:** Modern macOS VPN apps use Network Extensions that intercept ALL outbound traffic, including traffic destined for Tailscale's CGNAT range (`100.64/10`). This means:

- **MagicDNS resolution**: ✅ Fixed by tailroute (DNS goes through VPN)
- **Tailscale IP connectivity**: ❌ May be blocked by VPN at Network Extension level

**Tested VPNs that block CGNAT:**
| VPN | Protocols Tested | CGNAT Blocked |
|-----|------------------|---------------|
| Mullvad | WireGuard | ✅ Yes |
| NordVPN | NordLynx, OpenVPN, NordWhisper | ✅ Yes |

**Workarounds:**
1. **Disconnect VPN when using Tailscale mesh** - Manual toggle
2. **Use Tailscale + Mullvad exit nodes** - Single tunnel, buy Mullvad via Tailscale
3. **Try your VPN** - Some older VPN implementations may work

tailroute solves DNS conflicts but cannot bypass VPN Network Extension packet interception.

## How it works

tailroute runs as a background daemon and:

1. **Watches** for routing table changes in real time (`route monitor`)
2. **Detects** when both Tailscale and a VPN are active
3. **Toggles** MagicDNS off when VPN is active (restores internet through VPN)
4. **Restores** MagicDNS when VPN disconnects

**Trade-off:** While VPN is active, MagicDNS hostnames (`hostname.tailnet.ts.net`) won't resolve. Use IP addresses or connect to Tailscale without VPN for hostname access.

**Note on IP connectivity:** Due to macOS Network Extension architecture, some VPNs may also block traffic to Tailscale's CGNAT range (`100.64/10`). If `ping 100.x.x.x` fails with VPN connected, your VPN is blocking mesh traffic at the network layer. See "Known Limitation" above.

## Install

### Option 1: Homebrew (recommended)

```bash
brew install shrwnsan/tap/tailroute
sudo tailroute install
```

### Option 2: From source

```bash
git clone https://github.com/shrwnsan/tailroute.git
cd tailroute
sudo ./install.sh
```

Both methods:
- Install daemon to `/usr/local/bin/tailroute`
- Load launchd plist
- Start daemon automatically
- Run `tailroute status` to verify

## Usage

**There is no daily usage.** Once installed, tailroute works automatically in the background.

Your workflow stays the same:

1. VPN is connected
2. You turn on Tailscale
3. Everything works — internet through VPN, Tailscale via IP
4. You turn off Tailscale when done

### Check status

```bash
tailroute status
```

```
daemon:     running (pid 4821)
tailscale:  utun4 (100.x.y.z)
vpn:        utun3 (default route)
magicdns:   disabled (vpn_active)
last check: 12s ago
```

## SOCKS5 Proxy (v0.2.0+)

When VPN + Tailscale are both active, tailroute automatically starts a SOCKS5 proxy that routes traffic through your Tailscale mesh. This lets you reach Tailscale peers even when the VPN blocks direct CGNAT access.

### How it works

- **Auto-starts** when VPN + Tailscale both active
- **Auto-stops** when either disconnects
- Binds to `127.0.0.1:1055` (localhost only)
- Uses Tailscale's `tsnet` for native mesh routing

### Generate SSH config

```bash
# Single peer with user and identity
tailroute proxy-config ssh ubuntu@nanoclaw --identity ~/.ssh/mykey >> ~/.ssh/config

# All peers
tailroute proxy-config ssh >> ~/.ssh/config
```

Then connect:
```bash
ssh proxy-nanoclaw  # Routes through SOCKS5 proxy
```

More options: [PROXY-SETUP.md](docs/ref/PROXY-SETUP.md)

### Shell helpers

```bash
tailroute proxy-config shell >> ~/.zshrc
source ~/.zshrc

# Now use:
sshproxy mypeer        # SSH through proxy
curlproxy http://internal.local/api  # curl through proxy
```

Safe append mode: `tailroute proxy-config shell --append` (checks for existing helpers).

### Manual usage

```bash
# curl through proxy (socks5h = proxy resolves DNS)
curl -x socks5h://127.0.0.1:1055 http://100.x.x.x:8080

# SSH through proxy
ssh -o ProxyCommand="nc -X 5 -x 127.0.0.1:1055 %h %p" user@100.x.x.x
```

### Preview without changes

```bash
tailroute --dry-run
```

## Uninstall

**If installed via Homebrew:**
```bash
sudo tailroute uninstall
brew uninstall shrwnsan/tap/tailroute
```

**If installed from source:**
```bash
cd /path/to/tailroute
sudo ./uninstall.sh
```

Uninstall automatically restores MagicDNS if it was disabled and preserves logs for review.

## Requirements

- macOS 12+ (Monterey or later)
- Tailscale (CLI daemon recommended, GUI app has limitations)
- A VPN that uses a `utun` default route (NordVPN, ProtonVPN, ExpressVPN, Surfshark, etc.)

### Tailscale Installation Types

tailroute supports both Tailscale installations, but with different levels of functionality:

| Installation | MagicDNS Toggle | Status |
|--------------|-----------------|--------|
| `brew install tailscale` (CLI daemon) | Full support | ✅ Recommended |
| `brew install --cask tailscale-app` (GUI) | Limited | ⚠️ See limitations |
| Tailscale.app from tailscale.com | Limited | ⚠️ See limitations |
| Mac App Store version | Not supported | ❌ |

**CLI Daemon (Recommended):** tailroute can reliably query and toggle the local `--accept-dns` setting via the unix socket at `/var/run/tailscaled.socket`.

**GUI App Limitations:** The GUI app uses macOS System Extensions which don't expose a unix socket. tailroute falls back to reading the tailnet-wide `MagicDNSEnabled` field from `status --json`, which may not reflect the local accept-dns preference. Additionally, `tailscale set --accept-dns` commands may not reliably change the GUI app's settings.

**If you experience issues with MagicDNS not toggling correctly, switch to the CLI daemon:**

```bash
# Uninstall the GUI app
brew uninstall --cask tailscale-app

# Install and start the CLI daemon
brew install tailscale
sudo brew services start tailscale
sudo tailscale up  # Authenticate

# Reinstall tailroute to detect the new setup
sudo ./install.sh
```

## Troubleshooting

### Internet still doesn't work after installing

1. Check daemon status: `tailroute status`
2. Check logs: `tail -f /var/log/tailroute.log`
3. Try dry-run to see what would happen: `tailroute --dry-run`

### MagicDNS not restored after VPN disconnect

The daemon should auto-restore. If not, verify your setup:

```bash
# Check which Tailscale mode is active
ls -la /var/run/tailscaled.socket  # CLI daemon (recommended)
ls -la /Library/Tailscale/ipnport   # GUI app (limited support)

# For CLI daemon, manually restore:
sudo /opt/homebrew/bin/tailscale set --accept-dns=true

# Verify the state
sudo /opt/homebrew/bin/tailscale debug prefs | grep -i dns
```

If you're using the GUI app and MagicDNS isn't toggling correctly, consider switching to the CLI daemon (see Requirements section).

### Multiple VPNs active

tailroute logs a warning and does nothing when multiple VPN interfaces are detected (ambiguous state). Disconnect to a single VPN.

### Verifying MagicDNS State

For CLI daemon users:
```bash
sudo /opt/homebrew/bin/tailscale debug prefs 2>&1 | grep -i dns
# Look for "CorpDNS": true/false
```

For GUI app users, check the Tailscale macOS app UI under **Settings > Use Tailnet DNS settings**.

## Security

tailroute runs as a root launchd daemon. It is hardened with:

- Absolute paths for all system commands
- Strict input validation on all interface names and IPs
- `root:wheel` ownership on all installed files
- State manifest — tracks MagicDNS state to avoid unnecessary toggles
- Fail-safe — does nothing when state is ambiguous
- No network traffic interception or logging
- No external network calls
- No telemetry

See [Security.md](docs/ref/SECURITY.md) for full threat model, audit findings, and hardening details.

## What it doesn't do

- Does not intercept, inspect, or log any network traffic
- Does not make any external network calls
- Does not collect telemetry
- Does not require an account or signup
- Does not modify VPN routes or settings

## Documentation

### For Users
- **[FAQ.md](docs/ref/FAQ.md)** — Common questions, troubleshooting, compatibility
- **[CHANGELOG.md](CHANGELOG.md)** — Version history, features, known limitations
- **[SECURITY.md](docs/ref/SECURITY.md)** — Threat model, security hardening, audit results

### For Developers
- **[ARCHITECTURE.md](docs/ref/ARCHITECTURE.md)** — System design, component overview, data flow
- **[API.md](docs/ref/API.md)** — Function reference for all 8 libraries
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — How to contribute, development guidelines, testing

### Product & Design
- **[Product Spec](docs/plans/prd-001-tailroute.md)** — Full PRD, requirements, technical approach
- **[Implementation Tasks](docs/plans/tasks-001-tailroute.md)** — Phase breakdown by task

## What's Next?

### v0.2.0 ✅ COMPLETE
- ✅ **Native Swift app with menu bar UI** — Native macOS integration instead of daemon
- ✅ **Menu bar integration** — Real-time status icon in system menu bar
- ✅ **DMG installer** — Easy drag-to-install workflow
- ✅ **Preferences window** — SwiftUI settings for debounce/polling intervals
- ✅ **Logging system** — Structured logging to `~/Library/Logs/Tailroute/`
- ✅ **Interface detection** — Tailscale/VPN state detection with subprocess timeouts
- ✅ **SOCKS5 proxy** — Auto-starting proxy routes traffic through Tailscale mesh when VPN active
- ✅ **Proxy config helpers** — `proxy-config ssh` and `proxy-config shell` commands
- ✅ **Homebrew formula** — Tap-based installation ready

### v0.3.0 (Next)
- [ ] **Notarization** — Remove Gatekeeper warnings on fresh macOS installs (2–3 days effort, high impact)

### v0.4.0+ (Future)
- ⏸️ **Auto-updates (Sparkle)** — Deferred (Homebrew handles updates; revisit if >30% non-Homebrew distribution)
- ❌ **MagicDNS split DNS** — Won't fix ([research complete](docs/plans/tasks-001-tailroute.md#t-200--magicdns-split-dns--cancelled--wont-fix): VPN captures CGNAT packets unreliably)
- ❌ **Multi-VPN support** — Won't fix (edge case; current fail-safe is safer)

See [CHANGELOG.md](CHANGELOG.md) for full version history.

## Contributing

Found a bug? Want to contribute? See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- How to report issues
- Development setup & testing
- Pull request guidelines
- Security disclosure

## License

[Apache License 2.0](LICENSE) — See [LICENSE](LICENSE) file for details.
