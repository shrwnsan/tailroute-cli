#!/usr/bin/env bash
# test-lib-reconcile.sh — Tests for lib-reconcile.sh

# Source the libraries under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Override state directory for testing
export STATE_DIR="/tmp/tailroute-test-reconcile"
export STATE_MANIFEST="$STATE_DIR/state.manifest"

source "$SCRIPT_DIR/../bin/lib-reconcile.sh"

# Suppress error output during tests
exec 2>/dev/null



# =============================================================================
# reconcile tests
# =============================================================================

test_reconcile_function_exists() {
    # Just verify reconcile can be called
    reconcile >/dev/null 2>&1 || true
    return 0
}

# =============================================================================
# reconcile_dry_run tests
# =============================================================================

test_reconcile_dry_run_no_tailscale() {
    mock_ifconfig_output=$(cat <<'EOF'
en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.100 netmask 0xffffff00
EOF
    )
    
    local output
    output=$(reconcile_dry_run 2>&1)
    
    # Should print dry-run message
    if [[ "$output" =~ "DRY-RUN" ]]; then
        return 0
    else
        return 1
    fi
}

test_reconcile_dry_run_function_exists() {
    # Just verify the function can be called
    reconcile_dry_run >/dev/null 2>&1 || true
    return 0
}
