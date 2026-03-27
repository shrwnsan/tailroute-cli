#!/usr/bin/env bash
# install.sh — Standalone install wrapper for tailroute
#
# Usage: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/bin/tailroute.sh" install
