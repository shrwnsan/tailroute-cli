#!/usr/bin/env bash
# test-tunnel-stop.sh — `tunnel stop [<peer>|--all]`: argument handling, lock
# and journal gate, per-peer parking on the launchd disabled store, failure
# branches (disable seam, stuck bootout, missing plist), and exit codes.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

WEB_LABEL="com.tailroute.tunnel.web"
WEB2_LABEL="com.tailroute.tunnel.web-2"

# register <peer> <forwards> — registry entry + plist (not bootstrapped)
_register() {
    local peer="$1" forwards="$2"
    local entry plist
    entry="$(tunnel_build_entry_json "$peer" "$FX_IP" "$peer.$FX_SUFFIX" "$FX_SUFFIX" "$forwards")"
    tunnel_registry_add "$peer" "$entry"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    # shellcheck disable=SC2086  # $forwards intentionally word-splits into l:r pair args
    tunnel_generate_plist "$peer" "$FX_IP" "$TUNNEL_LOG_DIR/tunnel-$peer.log" "$peer" $forwards > "$plist"
    chmod 0644 "$plist"
}

# park-ready tunnel: registered + plist + bootstrapped launchd job
_make_tunnel() {
    local peer="$1" forwards="${2:-8443:443}"
    _register "$peer" "$forwards"
    tunnel_job_bootstrap "$(tunnel_plist_path_for_peer "$peer")"
}

_label_running() { # <label> — assert the launchd job is loaded
    assert_ok "$LAUNCHCTL_CMD" print "gui/$UID/$1"
}

test_stop_usage_errors() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_stop --frobnicate >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "unknown flag"
    rc=0
    tunnel_do_stop web extra >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "extra argument"
    rc=0
    tunnel_do_stop web --all >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "--all and a peer are mutually exclusive"
}

test_stop_not_found_exit_3_with_hint() {
    _tunnel_setup_sandbox
    _register prime "8443:443"
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "3" "$rc" "not-found rc"
    assert_contains "tunnel for 'web' not found" "$out"
    assert_contains "registered tunnels:" "$out"
    assert_contains "prime" "$out"
}

test_stop_empty_registry_is_a_clean_noop() {
    _tunnel_setup_sandbox
    local rc=0 out
    out="$(tunnel_do_stop 2>&1)" || rc=$?
    assert_eq "0" "$rc" "no-peer form on empty registry"
    assert_contains "No tunnels configured." "$out"
    rc=0
    out="$(tunnel_do_stop --all 2>&1)" || rc=$?
    assert_eq "0" "$rc" "--all on empty registry"
    assert_contains "No tunnels configured." "$out"
}

test_stop_single_parks_the_tunnel() {
    _tunnel_setup_sandbox
    _make_tunnel web
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "happy path rc"
    assert_contains "Stopped: web" "$out"
    assert_contains "URL: https://web.$FX_SUFFIX:8443" "$out"
    # the store records the intent and the job is gone
    assert_contains "\"$WEB_LABEL\" => disabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
    assert_fail "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_stop_prints_one_url_per_forward() {
    _tunnel_setup_sandbox
    _make_tunnel web "8443:443 8444:8443"
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "multi-forward rc"
    assert_contains "URL: https://web.$FX_SUFFIX:8443" "$out"
    assert_contains "URL: https://web.$FX_SUFFIX:8444" "$out"
}

test_stop_is_idempotent() {
    _tunnel_setup_sandbox
    _make_tunnel web
    assert_ok tunnel_do_stop web
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "second stop is a no-op"
    assert_contains "Already stopped: web" "$out"
}

test_stop_disable_failure_fails_the_peer() {
    _tunnel_setup_sandbox
    _make_tunnel web
    export FAIL_DISABLE=1
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    export FAIL_DISABLE=0
    assert_eq "1" "$rc" "disable seam rc"
    assert_contains "disable failed" "$out"
    # nothing else ran: the job is still loaded and the store untouched
    _label_running "$WEB_LABEL"
    assert_fail grep -q "$WEB_LABEL" "$LAUNCHCTL_DISABLED_STATE"
}

test_stop_bootout_failure_prints_retry_and_undo() {
    _tunnel_setup_sandbox
    _make_tunnel web
    export STUCK_BOOTOUT=1
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    export STUCK_BOOTOUT=0
    assert_eq "1" "$rc" "stuck bootout rc"
    assert_contains \
        "ERROR: web: disabled but still loaded — retry: tailroute tunnel stop web · undo: tailroute tunnel start web" \
        "$out"
    _label_running "$WEB_LABEL"
    # the retried stop sees running-disabled (not stopped) and boots out again
    export STUCK_BOOTOUT=0
    rc=0
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "retried stop succeeds"
    assert_contains "Stopped: web" "$out"
}

test_stop_missing_plist_still_parks_but_fails() {
    _tunnel_setup_sandbox
    _make_tunnel web
    rm -f "$(tunnel_plist_path_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "missing plist fails the peer"
    assert_contains "repair: tailroute tunnel remove web && tailroute tunnel add web" "$out"
    # the park itself still landed: fail-safe against a restored plist
    assert_contains "\"$WEB_LABEL\" => disabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
    assert_fail "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_stop_all_form_reports_per_peer_and_exits_1_on_any_failure() {
    _tunnel_setup_sandbox
    _make_tunnel web
    _make_tunnel web2
    rm -f "$(tunnel_plist_path_for_peer web2)"
    local rc=0 out
    out="$(tunnel_do_stop --all 2>&1)" || rc=$?
    assert_eq "1" "$rc" "one failing peer fails the all-form"
    assert_contains "Stopped: web" "$out"
    assert_contains "repair: tailroute tunnel remove web2 && tailroute tunnel add web2" "$out"
    assert_contains "\"$WEB_LABEL\" => disabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
    assert_contains "\"com.tailroute.tunnel.web2\" => disabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
}

test_stop_journal_gate_refuses_before_touching_anything() {
    _tunnel_setup_sandbox
    _make_tunnel web
    _tun_journal_write add other '["registry"]' '[]'
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "journal gate rc"
    assert_contains "incomplete journal for 'other'" "$out"
    assert_fail grep -q "$WEB_LABEL" "$LAUNCHCTL_DISABLED_STATE"
    _label_running "$WEB_LABEL"
}

test_stop_respects_the_operation_lock() {
    _tunnel_setup_sandbox
    _make_tunnel web
    mkdir "$TUNNEL_LOCK_DIR"
    echo $$ > "$TUNNEL_LOCK_DIR/pid"
    local rc=0 out
    out="$(tunnel_do_stop web 2>&1)" || rc=$?
    rm -rf "$TUNNEL_LOCK_DIR"
    assert_eq "1" "$rc" "lock held elsewhere"
    assert_contains "another tailroute tunnel operation is in progress" "$out"
    assert_fail grep -q "$WEB_LABEL" "$LAUNCHCTL_DISABLED_STATE"
}
