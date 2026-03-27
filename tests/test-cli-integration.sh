#!/usr/bin/env bash
# test-cli-integration.sh — Integration tests for tailroute CLI and installation
#
# Tests the user-facing CLI commands and installation workflow.
# These are automatable integration checks (not full end-to-end simulation).

set -euo pipefail

# Get project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the main tailroute script for testing
# (but not run it — we'll mock and test individual functions)
BIN_DIR="$PROJECT_ROOT/bin"

# Source all libraries (they're already sourced by tailroute.sh, but we need them directly)
# shellcheck source=../bin/lib-log.sh
source "$BIN_DIR/lib-log.sh"
# shellcheck source=../bin/lib-detect.sh
source "$BIN_DIR/lib-detect.sh"
# shellcheck source=../bin/lib-dns.sh
source "$BIN_DIR/lib-dns.sh"
# shellcheck source=../bin/lib-reconcile.sh
source "$BIN_DIR/lib-reconcile.sh"
# shellcheck source=../bin/lib-state.sh
source "$BIN_DIR/lib-state.sh"

# Temp directory for test artifacts
TEST_TMPDIR="$(mktemp -d)"
trap "rm -rf '$TEST_TMPDIR'" EXIT

# =============================================================================
# T-072: Security Audit Tests
# =============================================================================

# T-072.1: Verify key commands use absolute paths
test_security_audit_absolute_paths() {
    # Verify that critical system commands are defined with absolute paths
    # Check for path definitions like: NETSTAT="/usr/sbin/netstat"
    
    # These libraries should define absolute paths  
    assert_ok grep -q 'IFCONFIG="/' "$BIN_DIR/lib-detect.sh" "lib-detect missing IFCONFIG absolute path"
    assert_ok grep -q 'NETSTAT="/' "$BIN_DIR/lib-detect.sh" "lib-detect missing NETSTAT absolute path"
    assert_ok grep -q 'STAT_CMD="/' "$BIN_DIR/lib-dns.sh" "lib-dns missing STAT_CMD absolute path"
}

# T-072.2: Verify no eval anywhere in codebase
test_security_audit_no_eval() {
    # Should find zero instances of `eval` in production code
    local eval_count
    eval_count=$(grep -r '\beval\b' "$BIN_DIR" 2>/dev/null | grep -v '^Binary' | grep -v '^#' | wc -l)
    
    # Account for whitespace variations in output
    assert_eq "0" "$((eval_count))" "Found eval statements in production code"
}

# T-072.3: Verify plist structure (contains ProgramArguments, not sh -c)
test_security_audit_plist_format() {
    local plist="$PROJECT_ROOT/etc/com.tailroute.daemon.plist"
    
    # Should contain ProgramArguments and be valid XML
    [[ -f "$plist" ]] || return 1
    grep -q 'ProgramArguments' "$plist" || return 1
    grep -q '<array>' "$plist" || return 1
    ! grep -q 'sh -c' "$plist" || return 1
}

# T-072.4: Verify install.sh and uninstall.sh use set -euo pipefail
test_security_audit_install_scripts_safety() {
    for script in install.sh uninstall.sh; do
        local path="$PROJECT_ROOT/$script"
        assert_ok grep -q "^set -euo pipefail" "$path" "$script missing set -euo pipefail"
        assert_fail grep -q "eval" "$path" "$script should not contain eval"
    done
}

# T-072.5: Verify manifest directory would be created with correct permissions
test_security_audit_manifest_permissions() {
    # Simulate what install does: create /var/db/tailroute with 0755
    # We can't actually create /var/db in test, so we test the logic
    
    # Extract the mkdir command from install
    local install_script="$PROJECT_ROOT/bin/tailroute.sh"
    
    # Should find: mkdir -p /var/db/tailroute and chmod 0755
    assert_ok grep -q "mkdir -p /var/db/tailroute" "$install_script" "Install missing mkdir for state dir"
    assert_ok grep -q "chmod 0755 /var/db/tailroute" "$install_script" "Install missing chmod for state dir"
}

# =============================================================================
# T-070: Functional CLI Tests
# =============================================================================

# T-070.1: Test install/uninstall logic paths (verify required files)
test_cli_install_uninstall_paths() {
    # Verify that all required files exist in the source tree
    # (These would be installed by do_install())
    
    [[ -f "$BIN_DIR/tailroute.sh" ]] || { echo "tailroute.sh not found"; return 1; }
    [[ -f "$BIN_DIR/lib-log.sh" ]] || { echo "lib-log.sh not found"; return 1; }
    [[ -f "$PROJECT_ROOT/etc/com.tailroute.daemon.plist" ]] || { echo "plist not found"; return 1; }
    [[ -d "$PROJECT_ROOT/etc/newsyslog.d" ]] || { echo "newsyslog.d dir not found"; return 1; }
    [[ -f "$PROJECT_ROOT/install.sh" ]] || { echo "install.sh not found"; return 1; }
    [[ -f "$PROJECT_ROOT/uninstall.sh" ]] || { echo "uninstall.sh not found"; return 1; }
}

# T-070.8: Test --dry-run output format
test_cli_dry_run_output() {
    # Test dry-run with mocked detection
    # Set up mock responses
    export IFCONFIG_OUTPUT="utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST>
	inet 100.100.45.12 netmask 0xffffffff
	(Tailscale interface mock)"
    
    export NETSTAT_OUTPUT="default  10.8.0.1  utun3
(VPN interface mock)"
    
    # Run reconcile_dry_run from lib-reconcile.sh
    local output
    output=$(reconcile_dry_run 2>&1)
    
    # Should contain expected dry-run markers
    assert_contains "[DRY-RUN]" "$output" "Missing [DRY-RUN] marker"
    assert_contains "Tailscale" "$output" "Missing Tailscale detection"
    assert_contains "VPN" "$output" "Missing VPN detection"
    assert_contains "Would" "$output" "Missing action statement"
}

# T-070.9: Test status command output structure
test_cli_status_output() {
    # Test status command output contains expected fields
    # We'll mock the detection functions
    
    export IFCONFIG_OUTPUT="utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST>
	inet 100.100.45.12 netmask 0xffffffff"
    
    export NETSTAT_OUTPUT="default  10.8.0.1  utun3"
    
    # Create a mock state manifest
    local state_dir="$TEST_TMPDIR/var_db_tailroute"
    mkdir -p "$state_dir"
    export STATE_MANIFEST="$state_dir/state.manifest"
    echo "2026-02-18T10:30:00Z|disable|false" > "$STATE_MANIFEST"
    
    # The status command can't be directly sourced; test the detection components it uses
    local ts_iface
    ts_iface=$(find_tailscale_interface 2>/dev/null) || ts_iface=""
    
    assert_eq "utun4" "$ts_iface" "Tailscale detection failed in status test"
}

# =============================================================================
# T-071: Edge Case Tests (Partial Automation)
# =============================================================================

# T-071.5: Test signal handling in event loop (basic structure)
test_signal_handlers_exist() {
    # Verify signal handler functions are defined in lib-event-loop.sh
    local event_loop_lib="$BIN_DIR/lib-event-loop.sh"
    
    assert_ok grep -q "trap.*SIGTERM" "$event_loop_lib" "Missing SIGTERM handler"
    assert_ok grep -q "trap.*SIGHUP" "$event_loop_lib" "Missing SIGHUP handler"
    assert_ok grep -q "handle_shutdown" "$event_loop_lib" "Missing shutdown handler function"
    assert_ok grep -q "handle_sighup" "$event_loop_lib" "Missing SIGHUP handler function"
}

# T-071.6: Test dry-run idempotency (running twice produces same output)
test_cli_dry_run_idempotency() {
    export IFCONFIG_OUTPUT="utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST>
	inet 100.100.45.12 netmask 0xffffffff"
    
    export NETSTAT_OUTPUT="default  10.8.0.1  utun3"
    
    local output1 output2
    output1=$(reconcile_dry_run 2>&1 | grep -v "^$")
    output2=$(reconcile_dry_run 2>&1 | grep -v "^$")
    
    assert_eq "$output1" "$output2" "Dry-run output changed between runs (not idempotent)"
}

# =============================================================================
# T-070: Dry-run accuracy tests
# =============================================================================

# T-070.2a: Dry-run with Tailscale + VPN should indicate disable
test_cli_dry_run_tailscale_and_vpn() {
    export IFCONFIG_OUTPUT="utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST>
	inet 100.100.45.12 netmask 0xffffffff"
    
    export NETSTAT_OUTPUT="default  10.8.0.1  utun3"
    
    local output
    output=$(reconcile_dry_run 2>&1)
    
    assert_contains "disable" "$output" "Should recommend disable when both TS and VPN active"
    assert_contains "VPN active" "$output" "Should mention VPN active reason"
}

# T-070.2b: Dry-run with Tailscale only should indicate enable
test_cli_dry_run_tailscale_only() {
    export IFCONFIG_OUTPUT="utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST>
	inet 100.100.45.12 netmask 0xffffffff"
    
    export NETSTAT_OUTPUT="(no VPN routes)"
    
    local output
    output=$(reconcile_dry_run 2>&1)
    
    assert_contains "enable" "$output" "Should recommend enable when only TS active"
    assert_contains "No VPN" "$output" "Should mention no VPN detected"
}

# T-070.2c: Dry-run with no Tailscale should indicate no action
test_cli_dry_run_no_tailscale() {
    export IFCONFIG_OUTPUT="en0: flags=8049<UP,POINTOPOINT,RUNNING,SIMPLEX>
	inet 192.168.1.100 netmask 0xffffff00"
    
    export NETSTAT_OUTPUT="default  192.168.1.1  en0"
    
    local output
    output=$(reconcile_dry_run 2>&1)
    
    assert_contains "No Tailscale" "$output" "Should mention no Tailscale when not present"
    assert_contains "no action" "$output" "Should indicate no action needed"
}

# T-072.6: Verify key libraries define absolute paths for system utilities
test_all_system_commands_have_absolute_paths() {
    # Each library that calls system commands should define the path at the top
    
    local dns_lib="$BIN_DIR/lib-dns.sh"
    local state_lib="$BIN_DIR/lib-state.sh"
    
    # lib-dns should define STAT_CMD, SUDO_CMD, PLUTIL_CMD, TAILSCALE_CMD
    assert_ok grep -q 'STAT_CMD=' "$dns_lib" "lib-dns missing STAT_CMD definition"
    assert_ok grep -q 'SUDO_CMD=' "$dns_lib" "lib-dns missing SUDO_CMD definition"
    assert_ok grep -q 'PLUTIL_CMD=' "$dns_lib" "lib-dns missing PLUTIL_CMD definition"
    
    # Verify these are absolute paths (start with /)
    assert_ok grep -q 'STAT_CMD="/' "$dns_lib" "STAT_CMD not absolute path"
    assert_ok grep -q 'SUDO_CMD="/' "$dns_lib" "SUDO_CMD not absolute path"
}
