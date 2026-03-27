#!/usr/bin/env bash
# test-lib-state.sh — Tests for lib-state.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-state.sh"

# Suppress error output during tests
exec 2>/dev/null

# Create a temporary state directory for testing
TEST_STATE_DIR="/tmp/tailroute-test-state"
TEST_STATE_MANIFEST="$TEST_STATE_DIR/state.manifest"

# Override state paths for testing
STATE_DIR="$TEST_STATE_DIR"
STATE_MANIFEST="$TEST_STATE_MANIFEST"

# Setup: create test directory
setup_test_state() {
    rm -rf "$TEST_STATE_DIR"
    mkdir -p "$TEST_STATE_DIR"
}

# Teardown: clean up test directory
teardown_test_state() {
    rm -rf "$TEST_STATE_DIR"
}

# =============================================================================
# state_read tests
# =============================================================================

test_state_read_manifest_missing() {
    setup_test_state
    
    local result
    result=$(state_read 2>/dev/null)
    
    assert_eq "$result" ""
    teardown_test_state
}

test_state_read_manifest_exists() {
    setup_test_state
    
    # Create state manifest
    mkdir -p "$STATE_DIR"
    echo "2026-02-16T10:00:00Z|disable|false" > "$STATE_MANIFEST"
    
    local result
    result=$(state_read 2>/dev/null)
    
    assert_eq "$result" "2026-02-16T10:00:00Z|disable|false"
    teardown_test_state
}

test_state_read_manifest_multiple_lines() {
    setup_test_state
    
    # Create state manifest with multiple entries
    mkdir -p "$STATE_DIR"
    echo "2026-02-16T10:00:00Z|disable|false" > "$STATE_MANIFEST"
    echo "2026-02-16T10:05:00Z|enable|true" >> "$STATE_MANIFEST"
    echo "2026-02-16T10:10:00Z|disable|false" >> "$STATE_MANIFEST"
    
    # Should return the last line
    local result
    result=$(state_read 2>/dev/null)
    
    assert_eq "$result" "2026-02-16T10:10:00Z|disable|false"
    teardown_test_state
}

test_state_read_manifest_not_readable() {
    setup_test_state
    
    # Create manifest but make it unreadable
    mkdir -p "$STATE_DIR"
    echo "2026-02-16T10:00:00Z|disable|false" > "$STATE_MANIFEST"
    chmod 000 "$STATE_MANIFEST"
    
    # Should return empty when unreadable
    if ! state_read 2>/dev/null; then
        # Cleanup: restore permissions before teardown
        chmod 644 "$STATE_MANIFEST"
        teardown_test_state
        return 0
    else
        chmod 644 "$STATE_MANIFEST"
        teardown_test_state
        return 1
    fi
}

# =============================================================================
# state_write tests
# =============================================================================

test_state_write_create_manifest() {
    setup_test_state
    
    # Create state directory first
    mkdir -p "$STATE_DIR"
    
    # Write state
    assert_ok state_write "disable" "false"
    
    # Verify manifest was created
    if [[ -f "$STATE_MANIFEST" ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}

test_state_write_format() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Write state
    state_write "enable" "true" >/dev/null 2>&1
    
    # Read back and verify format
    local line
    line=$(tail -n 1 "$STATE_MANIFEST")
    
    # Format should be: timestamp|action|magicdns_enabled
    # Timestamp is ISO 8601 UTC
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\|enable\|true$ ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}

test_state_write_appends() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Write multiple states
    state_write "disable" "false" >/dev/null 2>&1
    state_write "enable" "true" >/dev/null 2>&1
    state_write "disable" "false" >/dev/null 2>&1
    
    # Count lines (without extra whitespace)
    local line_count
    line_count=$(grep -c . "$STATE_MANIFEST" || echo 0)
    
    assert_eq "$line_count" "3"
    teardown_test_state
}

test_state_write_creates_directory() {
    # Remove test directory to force creation
    rm -rf "$TEST_STATE_DIR"
    
    # state_write should create STATE_DIR
    state_write "disable" "false" >/dev/null 2>&1
    
    if [[ -d "$STATE_DIR" ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}

test_state_write_manifest_readable() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Write state
    state_write "enable" "true" >/dev/null 2>&1
    
    # Check manifest is readable (0644)
    if [[ -r "$STATE_MANIFEST" ]]; then
        teardown_test_state
        return 0
    else
        teardown_test_state
        return 1
    fi
}

test_state_write_invalid_action() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    assert_fail state_write "invalid" "true"
    teardown_test_state
}

test_state_write_invalid_magicdns_enabled() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    assert_fail state_write "disable" "maybe"
    teardown_test_state
}

# =============================================================================
# state_clear tests
# =============================================================================

test_state_clear_manifest_exists() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Create manifest
    echo "2026-02-16T10:00:00Z|disable|false" > "$STATE_MANIFEST"
    
    # Clear it
    assert_ok state_clear
    
    # Verify it's gone
    if [[ ! -f "$STATE_MANIFEST" ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}

test_state_clear_manifest_missing() {
    setup_test_state
    
    # Manifest doesn't exist
    # state_clear should still return 0 (idempotent)
    assert_ok state_clear
    teardown_test_state
}

test_state_clear_and_rewrite() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Write state, clear it, write again
    state_write "disable" "false" >/dev/null 2>&1
    state_clear >/dev/null 2>&1
    state_write "enable" "true" >/dev/null 2>&1
    
    # Should only have one line now
    local line_count
    line_count=$(grep -c . "$STATE_MANIFEST" || echo 0)
    
    assert_eq "$line_count" "1"
    
    # And it should be the enable action
    local last_line
    last_line=$(tail -n 1 "$STATE_MANIFEST")
    
    if [[ "$last_line" =~ enable ]]; then
        teardown_test_state
        return 0
    else
        teardown_test_state
        return 1
    fi
}

# =============================================================================
# Integration tests
# =============================================================================

test_state_write_and_read_cycle() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Write state
    state_write "disable" "false" >/dev/null 2>&1
    
    # Read it back
    local result
    result=$(state_read 2>/dev/null)
    
    # Should match format
    if [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\|disable\|false$ ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}

test_state_multiple_cycles() {
    setup_test_state
    mkdir -p "$STATE_DIR"
    
    # Simulate daemon lifecycle: disable, enable, disable
    state_write "disable" "false" >/dev/null 2>&1
    state_write "enable" "true" >/dev/null 2>&1
    state_write "disable" "false" >/dev/null 2>&1
    
    # Last state should be disable
    local result
    result=$(state_read 2>/dev/null)
    
    if [[ "$result" =~ disable.*false$ ]]; then
        return 0
    else
        return 1
    fi
    
    teardown_test_state
}
