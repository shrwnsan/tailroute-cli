#!/usr/bin/env bash
# install.sh — Standalone install wrapper for tailroute
#
# Local (inside a checkout):  sudo ./install.sh
# Remote one-liner:           curl -fsSL https://raw.githubusercontent.com/shrwnsan/tailroute-cli/main/install.sh | bash
#
# The remote path delegates to Homebrew, so binary integrity is still
# enforced by the formula's SHA-256 — this script itself never installs
# anything directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

if [[ -f "${BASH_SOURCE[0]}" && -f "$SCRIPT_DIR/bin/tailroute.sh" ]]; then
    "$SCRIPT_DIR/bin/tailroute.sh" install
    exit 0
fi

# Remote mode: script was piped in (BASH_SOURCE is not a regular file)
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: tailroute-cli is macOS-only (this host is $(uname -s))" >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required. Install it from https://brew.sh and re-run." >&2
    exit 1
fi

echo "==> Installing tailroute-cli via Homebrew"
brew install shrwnsan/tap/tailroute-cli

echo "==> Installing the daemon (requires root)"
sudo "$(brew --prefix)/bin/tailroute" install

echo "==> Done. Check status with: tailroute status"
