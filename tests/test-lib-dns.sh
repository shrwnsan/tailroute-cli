#!/usr/bin/env bash
# test-lib-dns.sh — Tests for lib-dns.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-dns.sh"

# Suppress error output during tests
exec 2>/dev/null

# Mock state functions to avoid actual file I/O
state_write() {
    return 0
}

state_read() {
    echo ""
    return 1
}

# =============================================================================
# get_magicdns_state tests
# =============================================================================

test_get_magicdns_state_enabled() {
    local ts_output='{"AcceptsDNS": true, "BackendState": "Running"}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    local result
    result=$(get_magicdns_state)
    
    assert_eq "$result" "true"
}

test_get_magicdns_state_disabled() {
    local ts_output='{"AcceptsDNS": false, "BackendState": "Running"}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    local result
    result=$(get_magicdns_state)
    
    assert_eq "$result" "false"
}

test_get_magicdns_state_missing_field() {
    local ts_output='{"BackendState": "Running"}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    local result
    result=$(get_magicdns_state)
    
    assert_eq "$result" "false"
}

test_get_magicdns_state_tailscale_not_running() {
    export TAILSCALE_JSON_OUTPUT=""
    
    local result
    result=$(get_magicdns_state 2>&1)
    
    # When Tailscale fails, we get "false" output but exit code 1
    assert_eq "$result" "false"
}

test_get_magicdns_state_return_code_enabled() {
    local ts_output='{"AcceptsDNS": true}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    if get_magicdns_state >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

test_get_magicdns_state_return_code_disabled() {
    local ts_output='{"AcceptsDNS": false}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    if get_magicdns_state >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

test_get_magicdns_state_whitespace_handling() {
    local ts_output='{"AcceptsDNS": true}'
    export TAILSCALE_JSON_OUTPUT="$ts_output"
    
    local result
    result=$(get_magicdns_state)
    
    # Should parse correctly
    assert_eq "$result" "true"
}

# =============================================================================
# disable_magicdns tests
# =============================================================================

test_disable_magicdns_when_disabled() {
    export TAILSCALE_JSON_OUTPUT='{"AcceptsDNS": false}'
    
    # Should be idempotent — return 0 without calling tailscale
    assert_ok disable_magicdns
}

# =============================================================================
# enable_magicdns tests
# =============================================================================

test_enable_magicdns_when_enabled() {
    export TAILSCALE_JSON_OUTPUT='{"AcceptsDNS": true}'
    
    # Should be idempotent — return 0 without calling tailscale
    assert_ok enable_magicdns
}
