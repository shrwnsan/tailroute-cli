#!/usr/bin/env bash
# test-tunnel-lifecycle-helpers.sh — the launchd disabled-store helpers
# (tunnel_job_disable/enable, tunnel_disabled_store, tunnel_label_is_disabled),
# the job-state probe, the strict journal gate, and the start/stop stubs.
#
# The state model under test: loaded × disabled-flag → running,
# running-disabled, stopped, not-running. A failed store read counts as
# "flag unknown" and must never produce stopped.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

WEB_LABEL="com.tailroute.tunnel.web"
WEB2_LABEL="com.tailroute.tunnel.web-2"

test_job_disable_enable_write_store_and_clear_err() {
    _tunnel_setup_sandbox
    assert_ok tunnel_job_disable "$WEB_LABEL"
    assert_eq "" "$TUNNEL_LAUNCHCTL_ERR" "stderr empty on successful disable"
    assert_ok tunnel_job_enable "$WEB_LABEL"
    assert_eq "" "$TUNNEL_LAUNCHCTL_ERR" "stderr empty on successful enable"
    # the enable left an explicit enabled line — the entry is never deleted
    local store
    store="$(tunnel_disabled_store)"
    assert_contains " => enabled" "$store"
}

test_job_disable_failure_seam_sets_err() {
    _tunnel_setup_sandbox
    export FAIL_DISABLE=1
    local rc=0
    tunnel_job_disable "$WEB_LABEL" || rc=$?
    export FAIL_DISABLE=0
    assert_eq "1" "$rc" "disable seam rc"
    assert_contains "disable failed" "$TUNNEL_LAUNCHCTL_ERR"
}

test_job_bootstrap_captures_stderr_and_preserves_rc() {
    _tunnel_setup_sandbox
    assert_ok tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist"
    assert_eq "" "$TUNNEL_LAUNCHCTL_ERR" "stderr empty on successful bootstrap"

    export FAIL_BOOTSTRAP=1
    local rc=0
    tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || rc=$?
    export FAIL_BOOTSTRAP=0
    assert_eq "1" "$rc" "FAIL_BOOTSTRAP rc preserved"
    assert_contains "bootstrap failed" "$TUNNEL_LAUNCHCTL_ERR"

    assert_ok tunnel_job_disable "$WEB_LABEL"
    rc=0
    tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist" || rc=$?
    assert_eq "5" "$rc" "bootstrap of a disabled label exits 5"
    assert_contains "Bootstrap failed: 5: Input/output error" "$TUNNEL_LAUNCHCTL_ERR"
}

test_disabled_store_prints_store_and_fails_loudly() {
    _tunnel_setup_sandbox
    local store
    store="$(tunnel_disabled_store)"
    assert_contains "disabled services = {" "$store"
    assert_contains '"com.apple.decoy" => disabled' "$store"
    export FAIL_PRINT_DISABLED=1
    local rc=0
    tunnel_disabled_store >/dev/null 2>&1 || rc=$?
    export FAIL_PRINT_DISABLED=0
    assert_eq "1" "$rc" "print-disabled seam"
}

test_label_is_disabled_exact_and_prefix_safe() {
    _tunnel_setup_sandbox
    local store
    store="$(tunnel_disabled_store)"
    assert_fail tunnel_label_is_disabled "$WEB_LABEL" "$store" "absent label is not disabled"

    assert_ok tunnel_job_disable "$WEB2_LABEL"
    store="$(tunnel_disabled_store)"
    # prefix collision: web-2's disabled line must not disable web
    assert_fail tunnel_label_is_disabled "$WEB_LABEL" "$store" "prefix must not match"
    assert_ok tunnel_label_is_disabled "$WEB2_LABEL" "$store"

    assert_ok tunnel_job_enable "$WEB2_LABEL"
    store="$(tunnel_disabled_store)"
    assert_fail tunnel_label_is_disabled "$WEB2_LABEL" "$store" "explicit enabled line is not disabled"

    # leading whitespace (the real print-disabled indent) is stripped
    assert_ok tunnel_label_is_disabled "$WEB2_LABEL" "$(printf '   \t"%s" => disabled\n' "$WEB2_LABEL")"
}

test_job_state_all_four_states() {
    _tunnel_setup_sandbox
    assert_eq "not-running" "$(tunnel_job_state "$WEB_LABEL")" "absent + absent flag"

    assert_ok tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist"
    assert_eq "running" "$(tunnel_job_state "$WEB_LABEL")" "loaded + no flag"

    assert_ok tunnel_job_disable "$WEB_LABEL"
    assert_eq "running-disabled" "$(tunnel_job_state "$WEB_LABEL")" "loaded + disabled"

    assert_ok tunnel_job_bootout "$WEB_LABEL"
    assert_eq "stopped" "$(tunnel_job_state "$WEB_LABEL")" "unloaded + disabled"

    assert_ok tunnel_job_enable "$WEB_LABEL"
    # the critical case: the explicit => enabled line must read as NOT disabled
    assert_eq "not-running" "$(tunnel_job_state "$WEB_LABEL")" "unloaded + enabled line"
}

test_job_state_prefers_passed_store_text() {
    _tunnel_setup_sandbox
    assert_ok tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist"
    assert_ok tunnel_job_disable "$WEB_LABEL"
    local store
    store="$(tunnel_disabled_store)"
    # With print-disabled failing, the no-text form falls back to running.
    # The store-text form never consults launchctl's store, so the seam
    # cannot fire and the real state (running-disabled) survives.
    export FAIL_PRINT_DISABLED=1
    assert_eq "running" "$(tunnel_job_state "$WEB_LABEL")" "no store text: flag unknown"
    assert_eq "running-disabled" "$(tunnel_job_state "$WEB_LABEL" "$store")" "store text bypasses the store read"
    export FAIL_PRINT_DISABLED=0
}

test_job_state_failed_store_read_never_says_stopped() {
    _tunnel_setup_sandbox
    assert_ok tunnel_job_bootstrap "$TUNNEL_LAUNCHAGENTS_DIR/$WEB_LABEL.plist"
    assert_ok tunnel_job_disable "$WEB_LABEL"
    export FAIL_PRINT_DISABLED=1
    # loaded + unreadable flag → running (not running-disabled, never stopped)
    assert_eq "running" "$(tunnel_job_state "$WEB_LABEL")" "loaded, flag unknown"
    assert_ok tunnel_job_bootout "$WEB_LABEL"
    # unloaded + unreadable flag → not-running (never stopped)
    assert_eq "not-running" "$(tunnel_job_state "$WEB_LABEL")" "unloaded, flag unknown"
    export FAIL_PRINT_DISABLED=0
}

test_journal_gate_strict() {
    _tunnel_setup_sandbox
    assert_ok tunnel_journal_gate_strict "no journal at all"

    # another peer's incomplete entry must gate the verb
    _tun_journal_write add other '["registry","hosts"]' '["registry"]'
    local rc=0
    tunnel_journal_gate_strict >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "incomplete journal gates"
}

test_stop_start_stubs_refuse_with_usage_rc() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_stop >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "stop stub"
    rc=0
    tunnel_do_start >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "start stub"
}
