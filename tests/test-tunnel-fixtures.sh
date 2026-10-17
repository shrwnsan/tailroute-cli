#!/usr/bin/env bash
# test-tunnel-fixtures.sh — self-tests for the shared sandbox and mocks in
# tunnel-fixtures.sh. The launchctl mock's disabled-services store and its
# failure seams back the tunnel start/stop tests; these tests pin that model
# (upsert semantics, the explicit `enabled` line, the decoy line, and every
# failure seam) so a mock regression cannot pass a downstream suite silently.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

WEB_LABEL="com.tailroute.tunnel.web"
WEB2_LABEL="com.tailroute.tunnel.web-2"

_assert_unexpected_fail() {
    _assert_fail "setup step failed unexpectedly"
}

_launchctl_rc() {
    # runs the mock with the given args, captures combined output into
    # MOCK_OUT, and echoes the exit code (set -e safe)
    local out rc=0
    out="$("$LAUNCHCTL_CMD" "$@" 2>&1)" || rc=$?
    MOCK_OUT="$out"
    return "$rc"
}

test_print_disabled_renders_store_and_decoy() {
    _tunnel_setup_sandbox
    _launchctl_rc disable "gui/501/$WEB_LABEL" || _assert_unexpected_fail
    _launchctl_rc print-disabled gui/501 || _assert_unexpected_fail
    assert_contains "$(printf '\t\t"%s" => disabled\n' "$WEB_LABEL")" "$MOCK_OUT"
    assert_contains "$(printf '\t\t"com.apple.decoy" => disabled\n')" "$MOCK_OUT"
}

test_enable_writes_explicit_line_and_never_deletes() {
    _tunnel_setup_sandbox
    _launchctl_rc disable "gui/501/$WEB_LABEL" || _assert_unexpected_fail
    _launchctl_rc enable "gui/501/$WEB_LABEL" || _assert_unexpected_fail
    # the entry survives as an explicit enabled line — a presence-grep on the
    # store must not misread an enabled label as stopped
    _launchctl_rc print-disabled gui/501 || _assert_unexpected_fail
    assert_contains "$(printf '\t\t"%s" => enabled\n' "$WEB_LABEL")" "$MOCK_OUT"
    assert_contains "$(printf '\t\t"com.apple.decoy" => disabled\n')" "$MOCK_OUT"
}

test_interleaved_states_across_prefix_collision_pair() {
    _tunnel_setup_sandbox
    _launchctl_rc disable "gui/501/$WEB_LABEL"   || _assert_unexpected_fail
    _launchctl_rc disable "gui/501/$WEB2_LABEL"  || _assert_unexpected_fail
    _launchctl_rc enable  "gui/501/$WEB_LABEL"   || _assert_unexpected_fail
    _launchctl_rc print-disabled gui/501 || _assert_unexpected_fail
    # both labels render, each with its own state — an unanchored grep for the
    # shorter label's disabled state must not be satisfied by the longer one
    assert_contains "$(printf '\t\t"%s" => enabled\n' "$WEB_LABEL")" "$MOCK_OUT"
    assert_contains "$(printf '\t\t"%s" => disabled\n' "$WEB2_LABEL")" "$MOCK_OUT"
    local disabled_lines
    disabled_lines="$(printf '%s\n' "$MOCK_OUT" | grep -c '=> disabled')"
    assert_eq "2" "$disabled_lines" "decoy + web-2 must be the only disabled lines"
}

test_bootstrap_of_disabled_label_fails_rc5_with_stderr() {
    _tunnel_setup_sandbox
    _launchctl_rc disable "gui/501/$WEB_LABEL" || _assert_unexpected_fail
    local rc=0
    _launchctl_rc bootstrap "gui/501" "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || rc=$?
    assert_eq "5" "$rc" "bootstrap of a disabled label must exit 5"
    assert_contains "Bootstrap failed: 5: Input/output error" "$MOCK_OUT"
    # and the label must not have been loaded
    assert_fail "$LAUNCHCTL_CMD" print "gui/501/$WEB_LABEL"
}

test_bootstrap_succeeds_when_label_absent_or_enabled() {
    _tunnel_setup_sandbox
    local rc=0
    _launchctl_rc bootstrap "gui/501" "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || rc=$?
    assert_eq "0" "$rc" "bootstrap of an absent label must succeed"
    _launchctl_rc disable "gui/501/$WEB2_LABEL" || _assert_unexpected_fail
    _launchctl_rc enable "gui/501/$WEB2_LABEL" || _assert_unexpected_fail
    rc=0
    _launchctl_rc bootstrap "gui/501" "$TUNNEL_LAUNCHAGENTS_DIR/$WEB2_LABEL.plist" || rc=$?
    assert_eq "0" "$rc" "bootstrap of an explicitly-enabled label must succeed"
}

test_failure_seams_exit_1_with_stderr() {
    _tunnel_setup_sandbox
    export FAIL_DISABLE=1
    local rc=0
    _launchctl_rc disable "gui/501/$WEB_LABEL" || rc=$?
    assert_eq "1" "$rc" "FAIL_DISABLE seam"
    assert_contains "disable failed" "$MOCK_OUT"
    export FAIL_DISABLE=0

    export FAIL_ENABLE=1
    rc=0
    _launchctl_rc enable "gui/501/$WEB_LABEL" || rc=$?
    assert_eq "1" "$rc" "FAIL_ENABLE seam"
    assert_contains "enable failed" "$MOCK_OUT"
    export FAIL_ENABLE=0

    export FAIL_PRINT_DISABLED=1
    rc=0
    _launchctl_rc print-disabled gui/501 || rc=$?
    assert_eq "1" "$rc" "FAIL_PRINT_DISABLED seam"
    assert_contains "print-disabled failed" "$MOCK_OUT"
    export FAIL_PRINT_DISABLED=0

    export FAIL_BOOTSTRAP=1
    rc=0
    _launchctl_rc bootstrap "gui/501" "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || rc=$?
    assert_eq "1" "$rc" "FAIL_BOOTSTRAP seam"
    assert_contains "bootstrap failed" "$MOCK_OUT"
    export FAIL_BOOTSTRAP=0
}

test_stuck_bootout_leaves_label_loaded() {
    _tunnel_setup_sandbox
    _launchctl_rc bootstrap "gui/501" "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || _assert_unexpected_fail
    export STUCK_BOOTOUT=1
    local rc=0
    _launchctl_rc bootout "gui/501/$WEB_LABEL" || rc=$?
    export STUCK_BOOTOUT=0
    assert_eq "5" "$rc" "STUCK_BOOTOUT seam"
    assert_ok "$LAUNCHCTL_CMD" print "gui/501/$WEB_LABEL"
}

test_unhandled_subcommand_fails_loudly() {
    _tunnel_setup_sandbox
    local rc=0
    _launchctl_rc tether "gui/501/x" || rc=$?
    assert_eq "64" "$rc" "unmodelled subcommands must not silently succeed"
    assert_contains "unhandled" "$MOCK_OUT"
}

test_list_is_modelled_as_empty_success() {
    _tunnel_setup_sandbox
    local rc=0
    _launchctl_rc list || rc=$?
    assert_eq "0" "$rc" "list"
    assert_eq "" "$MOCK_OUT" "list output"
}
