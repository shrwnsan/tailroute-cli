#!/bin/bash
# Phase 0 validation capture script
# Usage: ./scripts/capture-validation.sh <scenario-name>
# Example: ./scripts/capture-validation.sh baseline-ts-only
#
# Appends a scenario section to docs/validation-report.md (or docs/ref/ for archival)
# Run once for each scenario, then edit the Analysis section.
#
# WARNING: This script captures raw network data including IP addresses,
# MAC addresses, device names, and tailnet identifiers. Before committing
# to a public repository, review and redact sensitive information:
#   - Replace specific IPs with placeholders (e.g., 100.x.x.x)
#   - Replace MAC addresses with xx:xx:xx:xx:xx:xx
#   - Replace device/hostnames with generic names
#   - Remove tailnet owner identifiers
#
# See docs/ref/phase0-validation-reference.md for an example of properly redacted output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REPORT_FILE="$PROJECT_ROOT/docs/validation-report.md"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <scenario-name>"
    echo ""
    echo "Scenarios:"
    echo "  baseline-ts-only     - Tailscale only (no VPN)"
    echo "  baseline-vpn-only    - NordVPN only (no Tailscale)"
    echo "  conflict-vpn-then-ts - NordVPN connected first, then Tailscale"
    echo "  conflict-ts-then-vpn - Tailscale first, then NordVPN"
    exit 1
fi

SCENARIO="$1"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Initialize report file if it doesn't exist
if [ ! -f "$REPORT_FILE" ]; then
    cat > "$REPORT_FILE" << 'EOF'
# Validation Report: NordVPN + Tailscale Routing Conflict

> Empirical validation of routing behavior when NordVPN and Tailscale are both active on macOS.
>
> **Purpose:** Determine which routes need injecting to restore Tailscale connectivity.

---

EOF
fi

# Append scenario section
{
    echo "## Scenario: ${SCENARIO}"
    echo ""
    echo "_Captured: ${TIMESTAMP}_"
    echo ""
    echo "### System Info"
    echo '```'
    echo "macOS: $(sw_vers -productVersion)"
    echo "Kernel: $(uname -r)"
    echo '```'
    echo ""

    echo "### utun Interfaces"
    echo '```'
    /sbin/ifconfig | grep -A5 "^utun" || echo "(no utun interfaces)"
    echo '```'
    echo ""

    echo "### Routing Table"
    echo '```'
    /usr/sbin/netstat -rn
    echo '```'
    echo ""

    echo "### Network Interface Info"
    echo '```'
    /usr/sbin/scutil --nwi 2>&1 || echo "(scutil unavailable)"
    echo '```'
    echo ""

    echo "### Tailscale Status"
    echo '```'
    /usr/local/bin/tailscale status 2>&1 || echo "(tailscale not available)"
    echo '```'
    echo ""

    echo "### Tailscale Debug (DERP map)"
    echo '```'
    /usr/local/bin/tailscale debug derpmap 2>&1 || echo "(tailscale not available)"
    echo '```'
    echo ""

    echo "### Ping Test"
    echo '```'
    echo "Run manually: tailscale ping <peer>"
    echo "Result: (record success/failure/timeout here)"
    echo '```'
    echo ""

    echo "---"
    echo ""
} >> "$REPORT_FILE"

echo "Appended scenario '$SCENARIO' to $REPORT_FILE"
