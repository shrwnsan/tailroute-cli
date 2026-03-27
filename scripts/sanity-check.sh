#!/usr/bin/env bash
# sanity-check.sh — Integration health check for tailroute libraries
#
# Runs all libraries together on real system output to catch breakage early.
# Safe to run as non-root; uses temp directory for state testing.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temp state directory for testing
TEST_STATE_DIR="/tmp/tailroute-sanity-check"
TEST_STATE_MANIFEST="$TEST_STATE_DIR/state.manifest"

# Test counters
PASSED=0
FAILED=0
WARNINGS=0

# =============================================================================
# Test utilities
# =============================================================================

test_pass() {
    echo -e "${GREEN}✓ $1${NC}"
    ((PASSED++)) || true
}

test_fail() {
    echo -e "${RED}✗ $1${NC}"
    ((FAILED++)) || true
}

test_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
    ((WARNINGS++)) || true
}

test_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    # Clean temp state dir
    rm -rf "$TEST_STATE_DIR"
    mkdir -p "$TEST_STATE_DIR"
}

teardown() {
    rm -rf "$TEST_STATE_DIR"
}

# =============================================================================
# Library sourcing tests
# =============================================================================

test_source_libraries() {
    echo ""
    echo "Testing library sourcing..."
    
    # Override STATE_DIR for testing (must be before sourcing lib-state.sh)
    export STATE_DIR="$TEST_STATE_DIR"
    export STATE_MANIFEST="$TEST_STATE_MANIFEST"
    
    # Source all libraries
    if ! source "$PROJECT_ROOT/bin/lib-log.sh" 2>&1; then
        test_fail "Failed to source lib-log.sh"
        return 1
    fi
    test_pass "lib-log.sh sourced"
    
    if ! source "$PROJECT_ROOT/bin/lib-validate.sh" 2>&1; then
        test_fail "Failed to source lib-validate.sh"
        return 1
    fi
    test_pass "lib-validate.sh sourced"
    
    if ! source "$PROJECT_ROOT/bin/lib-detect.sh" 2>&1; then
        test_fail "Failed to source lib-detect.sh"
        return 1
    fi
    test_pass "lib-detect.sh sourced"
    
    if ! source "$PROJECT_ROOT/bin/lib-state.sh" 2>&1; then
        test_fail "Failed to source lib-state.sh"
        return 1
    fi
    test_pass "lib-state.sh sourced"
    
    if ! source "$PROJECT_ROOT/bin/lib-dns.sh" 2>&1; then
        test_fail "Failed to source lib-dns.sh"
        return 1
    fi
    test_pass "lib-dns.sh sourced"
}

# =============================================================================
# Detection tests (real system)
# =============================================================================

test_detection() {
    echo ""
    echo "Testing interface detection on real system..."
    
    # Find Tailscale interface
    local ts_interface=""
    ts_interface=$(find_tailscale_interface 2>/dev/null) || ts_interface=""
    
    if [[ -n "$ts_interface" ]]; then
        test_pass "Found Tailscale interface: $ts_interface"
        
        # Get Tailscale IP
        local ts_ip=""
        ts_ip=$(get_tailscale_ip "$ts_interface" 2>/dev/null) || ts_ip=""
        if [[ -n "$ts_ip" ]]; then
            test_pass "Extracted Tailscale IP: $ts_ip"
        else
            test_warn "Could not extract IP from Tailscale interface"
        fi
    else
        test_warn "No Tailscale interface found (Tailscale may not be running)"
    fi
    
    # Find VPN interface
    local vpn_interface=""
    vpn_interface=$(find_vpn_default_route "$ts_interface" 2>/dev/null) || vpn_interface=""
    
    if [[ -n "$vpn_interface" ]]; then
        test_pass "Found VPN interface: $vpn_interface"
    else
        test_info "No VPN interface found (VPN may not be connected)"
    fi
    
    # Find physical gateway
    local phys_gateway=""
    phys_gateway=$(find_physical_gateway 2>/dev/null) || phys_gateway=""
    
    if [[ -n "$phys_gateway" ]]; then
        test_pass "Found physical gateway: $phys_gateway"
    else
        test_warn "No physical gateway found"
    fi
}

# =============================================================================
# State I/O tests
# =============================================================================

test_state_io() {
    echo ""
    echo "Testing state manifest I/O..."
    
    # Write state
    if state_write "disable" "false" 2>/dev/null; then
        test_pass "State write: disable MagicDNS"
    else
        test_fail "Failed to write state"
        return 1
    fi
    
    # Verify file exists
    if [[ -f "$TEST_STATE_MANIFEST" ]]; then
        test_pass "State manifest file created"
    else
        test_fail "State manifest file not created"
        return 1
    fi
    
    # Read state back
    local state
    state=$(state_read 2>/dev/null || echo "")
    
    if [[ -n "$state" ]]; then
        test_pass "State read: $state"
    else
        test_fail "Failed to read state"
        return 1
    fi
    
    # Write another state
    if state_write "enable" "true" 2>/dev/null; then
        test_pass "State write: enable MagicDNS"
    else
        test_fail "Failed to write second state"
        return 1
    fi
    
    # Clear state
    if state_clear 2>/dev/null; then
        test_pass "State manifest cleared"
    else
        test_fail "Failed to clear state"
        return 1
    fi
    
    # Verify cleared
    if [[ ! -f "$TEST_STATE_MANIFEST" ]]; then
        test_pass "State manifest verified deleted"
    else
        test_fail "State manifest still exists after clear"
        return 1
    fi
}

# =============================================================================
# Validation tests
# =============================================================================

test_validation() {
    echo ""
    echo "Testing input validation..."
    
    # Interface name validation
    if validate_interface_name "utun4" 2>/dev/null; then
        test_pass "Interface validation: valid utun4"
    else
        test_fail "Interface validation failed for utun4"
    fi
    
    if ! validate_interface_name "eth0" 2>/dev/null; then
        test_pass "Interface validation: rejected eth0"
    else
        test_fail "Interface validation accepted eth0"
    fi
    
    # IPv4 validation
    if validate_ipv4 "100.100.45.12" 2>/dev/null; then
        test_pass "IPv4 validation: valid 100.100.45.12"
    else
        test_fail "IPv4 validation failed for 100.100.45.12"
    fi
    
    # CIDR validation
    if validate_cidr "100.64.0.0/10" 2>/dev/null; then
        test_pass "CIDR validation: valid 100.64.0.0/10"
    else
        test_fail "CIDR validation failed for 100.64.0.0/10"
    fi
    
    # IP in CIDR
    if ip_in_cidr "100.100.45.12" "100.64.0.0/10" 2>/dev/null; then
        test_pass "CIDR matching: 100.100.45.12 in 100.64.0.0/10"
    else
        test_fail "CIDR matching failed"
    fi
}

# =============================================================================
# Logging tests
# =============================================================================

test_logging() {
    echo ""
    echo "Testing logging functions..."
    
    # Test log functions (suppress output)
    if log_info "Test message" >/dev/null 2>&1; then
        test_pass "log_info() works"
    else
        test_fail "log_info() failed"
    fi
    
    if log_warn "Test warning" >/dev/null 2>&1; then
        test_pass "log_warn() works"
    else
        test_fail "log_warn() failed"
    fi
    
    if log_dns_change "disable" "vpn_active" >/dev/null 2>&1; then
        test_pass "log_dns_change() works"
    else
        test_fail "log_dns_change() failed"
    fi
}

# =============================================================================
# Summary report
# =============================================================================

print_summary() {
    echo ""
    echo "======================================="
    echo " Sanity Check Results"
    echo "======================================="
    echo -e "${GREEN}Passed:${NC}  $PASSED"
    if [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
    fi
    if [[ $FAILED -gt 0 ]]; then
        echo -e "${RED}Failed:${NC}  $FAILED"
    fi
    echo "======================================="
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All checks passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some checks failed. See above.${NC}"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    setup
    
    echo "🔍 tailroute Sanity Check"
    echo "========================="
    
    test_source_libraries || {
        print_summary
        teardown
        return 1
    }
    
    test_detection
    test_state_io
    test_validation
    test_logging
    
    print_summary
    local result=$?
    
    teardown
    return $result
}

main "$@"
