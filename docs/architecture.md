# Architecture

Technical overview of tailroute CLI.

## Components

### Daemon (`bin/tailroute.sh`)

Main entry point that monitors network state and toggles MagicDNS.

```
bin/
├── tailroute.sh       # Main CLI/daemon
├── lib-detect.sh      # Interface detection
├── lib-dns.sh         # MagicDNS toggle
├── lib-event-loop.sh  # Route monitoring
├── lib-lock.sh        # Concurrency lock
├── lib-log.sh         # Logging
├── lib-reconcile.sh   # State machine
├── lib-state.sh       # State persistence
└── lib-validate.sh    # Input validation
```

### Proxy (`proxy/main.go`)

SOCKS5 proxy using Tailscale's tsnet for independent mesh access.

- Binds to `127.0.0.1:1055` (localhost only)
- Creates separate Tailscale identity (doesn't conflict with primary)
- Bypasses VPN Network Extension interception

## How It Works

### DNS Plane

```
VPN active → MagicDNS (100.64.0.2) unreachable → DNS fails
tailroute detects → disables MagicDNS → VPN DNS works → internet restored
```

### Data Plane (Proxy)

```
VPN active → CGNAT (100.64/10) packets intercepted → Tailscale blocked
tailroute proxy → routes through tsnet → DERP/direct peer → bypasses VPN
```

## State Machine

```
┌─────────────┐     network change      ┌──────────────┐
│   Idle      │ ────────────────────────▶│   Evaluate   │
└─────────────┘                          └──────┬───────┘
       ▲                                         │
       │                    ┌───────────────────┴───────────────────┐
       │                    │                                       │
       │              TS + VPN                                  TS only
       │              detected                                  or no VPN
       │                    │                                       │
       │           ┌────────▼────────┐                    ┌─────────▼────────┐
       │           │ Disable MagicDNS│                    │ Enable MagicDNS  │
       │           └────────┬────────┘                    └─────────┬────────┘
       │                    │                                       │
       └────────────────────┴───────────────────────────────────────┘
```

## Security

- Runs as root launchd daemon
- Absolute paths for all system commands
- Strict input validation on interface names and IPs
- No network traffic interception
- No external calls
- No telemetry

## Files

| Location | Purpose |
|----------|---------|
| `/usr/local/bin/tailroute` | CLI binary |
| `/usr/local/bin/lib-*.sh` | Library files |
| `/usr/local/bin/tailroute-proxy` | SOCKS5 proxy |
| `/var/log/tailroute.log` | Daemon logs |
| `/var/db/tailroute/state.manifest` | State tracking |
| `/Library/LaunchDaemons/com.tailroute.daemon.plist` | launchd config |
