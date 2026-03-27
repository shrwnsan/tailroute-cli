# Building Tailroute from Source

## Prerequisites

- Xcode 14+ (or Swift 5.9 via Command Line Tools)
- macOS 12+ (Monterey or later)
- Tailscale installed (for testing)

## Quick Start

```bash
cd macos
./build.sh
```

This creates `build/Tailroute-0.2.0.dmg` ready for distribution.

## Development Build

```bash
cd macos
swift build
# Binary at: .build/debug/tailroute
```

## Release Build

```bash
cd macos
swift build -c release
# Binary at: .build/release/tailroute
```

## Running Tests

Requires Xcode (XCTest framework is not included in Command Line Tools).

```bash
cd macos
swift test   # Requires Xcode toolchain
```

Test suites:
- `StatusMenuControllerTests` — Menu structure and icon updates
- `InterfaceDetectionTests` — IPv4 validation, CIDR matching, edge cases
- `ConfigTests` — Default values, persistence round-trip
- `NotificationManagerTests` — State change message content

### Manual Testing

```bash
cd macos
./build.sh
open build/Tailroute-0.2.0.dmg
```

See [INTEGRATION-TESTS.md](docs/ref/INTEGRATION-TESTS.md) for full manual verification steps.

## Troubleshooting

### "Swift not found"
Install Xcode Command Line Tools:
```bash
xcode-select --install
```

### "Cannot import AppKit"
Ensure building from `macos/` directory where Package.swift is located.

### "tailroute binary not found"
Run `swift build` first. Binary is in `.build/debug/` or `.build/release/`.

## Architecture

See [SWIFT-ARCHITECTURE.md](docs/ref/SWIFT-ARCHITECTURE.md) for module organization.
