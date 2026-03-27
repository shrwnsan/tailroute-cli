#!/usr/bin/env bash
# uninstall.sh — Standalone uninstall wrapper for tailroute
#
# Usage: sudo ./uninstall.sh

set -euo pipefail

sudo /usr/local/bin/tailroute uninstall
