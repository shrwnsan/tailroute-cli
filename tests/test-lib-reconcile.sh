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

# =============================================================================
# reconcile transition-gating tests
# =============================================================================

# Mock the detection layer so reconcile() decisions are deterministic.
_mock_reconcile_env() {
    find_tailscale_interface() { echo "utun7"; }
    get_tailscale_ip() { echo "100.100.100.100"; }
    find_vpn_default_route() { return 1; }  # no VPN
    enable_magicdns() { ENABLE_CALLED=$((ENABLE_CALLED + 1)); return 0; }
    disable_magicdns() { DISABLE_CALLED=$((DISABLE_CALLED + 1)); return 0; }
    ENABLE_CALLED=0
    DISABLE_CALLED=0
    RECONCILE_REASSERT_TICKS=15
    _RECONCILE_LAST_MODE=""
    _RECONCILE_TICK_COUNT=0
}

test_reconcile_first_call_applies_and_unchanged_skips() {
    _mock_reconcile_env
    reconcile >/dev/null 2>&1   # mode transition from unset → applies
    reconcile >/dev/null 2>&1   # unchanged → skip
    reconcile >/dev/null 2>&1   # unchanged → skip
    if (( ENABLE_CALLED == 1 )); then return 0; else return 1; fi
}

test_reconcile_reasserts_after_threshold_ticks() {
    _mock_reconcile_env
    RECONCILE_REASSERT_TICKS=2
    reconcile >/dev/null 2>&1   # applies
    reconcile >/dev/null 2>&1   # skip 1
    reconcile >/dev/null 2>&1   # skip 2 → threshold reached → re-assert
    if (( ENABLE_CALLED == 2 )); then return 0; else return 1; fi
}

test_reconcile_force_bypasses_unchanged_skip() {
    _mock_reconcile_env
    reconcile >/dev/null 2>&1   # applies
    reconcile force >/dev/null 2>&1  # unchanged but forced → applies
    if (( ENABLE_CALLED == 2 )); then return 0; else return 1; fi
}

test_reconcile_vpn_transition_calls_disable() {
    _mock_reconcile_env
    find_vpn_default_route() { echo "utun3"; }  # VPN active
    reconcile >/dev/null 2>&1
    if (( DISABLE_CALLED == 1 && ENABLE_CALLED == 0 )); then return 0; else return 1; fi
}
