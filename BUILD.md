# Building from Source

## Prerequisites

- Bash 3.2+ (macOS default)
- Go 1.22+ (for proxy binary)
- macOS 12+ (Monterey or later)

## Build the Proxy Binary

```bash
cd proxy
./build.sh
```

This creates `proxy/build/tailroute-proxy` for your architecture.

### Cross-compile

```bash
# ARM64 (Apple Silicon)
GOOS=darwin GOARCH=arm64 go build -o build/tailroute-proxy-darwin-arm64

# AMD64 (Intel Mac)
GOOS=darwin GOARCH=amd64 go build -o build/tailroute-proxy-darwin-amd64
```

## Install

```bash
sudo ./install.sh
```

This:
- Copies `bin/tailroute.sh` to `/usr/local/bin/tailroute`
- Copies library files to `/usr/local/bin/lib-*.sh`
- Copies proxy binary to `/usr/local/bin/tailroute-proxy` (if built)
- Installs launchd plist to `/Library/LaunchDaemons/`
- Starts the daemon

## Run Tests

```bash
cd tests
./run-tests.sh
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for technical overview.

## Uninstall

```bash
sudo ./uninstall.sh
```
