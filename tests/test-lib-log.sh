#!/usr/bin/env bash
# test-lib-log.sh — Tests for lib-log.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-log.sh"

# =============================================================================
# Timestamp format tests
# =============================================================================

test_timestamp_format() {
    local output
    output=$(log_info "test" 2>&1)
    # Should match [YYYY-MM-DDTHH:MM:SSZ] format
    assert_match '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' "$output"
}

# =============================================================================
# log_info tests
# =============================================================================

test_log_info_format() {
    local output
    output=$(log_info "test message" 2>&1)
    assert_contains "[INFO]" "$output"
    assert_contains "test message" "$output"
}

test_log_info_multi_word() {
    local output
    output=$(log_info "multi" "word" "message" 2>&1)
    assert_contains "multi word message" "$output"
}

# =============================================================================
# log_warn tests
# =============================================================================

test_log_warn_format() {
    local output
    output=$(log_warn "warning test" 2>&1)
    assert_contains "[WARN]" "$output"
    assert_contains "warning test" "$output"
}

# =============================================================================
# log_error tests
# =============================================================================

test_log_error_format() {
    local output
    output=$(log_error "error test" 2>&1)
    assert_contains "[ERROR]" "$output"
    assert_contains "error test" "$output"
}

# =============================================================================
# log_debug tests
# =============================================================================

test_log_debug_disabled_by_default() {
    local output
    output=$(log_debug "debug test" 2>&1)
    # Should be empty when DEBUG is not set
    assert_eq "" "$output"
}

test_log_debug_enabled() {
    local output
    output=$(DEBUG=1 log_debug "debug test" 2>&1)
    assert_contains "[DEBUG]" "$output"
    assert_contains "debug test" "$output"
}

test_log_debug_enabled_true() {
    local output
    output=$(DEBUG=true log_debug "debug test" 2>&1)
    assert_contains "[DEBUG]" "$output"
}

# =============================================================================
# log_dns_change tests
# =============================================================================

test_log_dns_change_enable() {
    local output
    output=$(log_dns_change "enable" "vpn_inactive" 2>&1)
    assert_contains "[DNS]" "$output"
    assert_contains "action=enable" "$output"
    assert_contains "reason=vpn_inactive" "$output"
}

test_log_dns_change_disable() {
    local output
    output=$(log_dns_change "disable" "vpn_active" 2>&1)
    assert_contains "[DNS]" "$output"
    assert_contains "action=disable" "$output"
    assert_contains "reason=vpn_active" "$output"
}

test_log_dns_change_invalid_action() {
    # Should fail with invalid action
    assert_fail log_dns_change "invalid" "reason"
}

test_log_dns_change_grep_parseable() {
    local output
    output=$(log_dns_change "disable" "vpn_active" 2>&1)
    # Should be greppable by [DNS]
    assert_match '\[DNS\] action=disable reason=vpn_active' "$output"
}
