#!/usr/bin/env bash
# test-tunnel-start.sh — `tunnel start [<peer>|--all]`: the normative order
# (plist check → enable → loaded check → bootstrap → listener poll), the
# no-launchctl-call-before-plist rule, running-disabled repair, and failure
# branches.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

WEB_LABEL="com.tailroute.tunnel.web"

# register <peer> [forwards] — registry entry + plist (not bootstrapped)
_register() {
    local peer="$1" forwards="${2:-8443:443}"
    local entry plist
    entry="$(tunnel_build_entry_json "$peer" "$FX_IP" "$peer.$FX_SUFFIX" "$FX_SUFFIX" "$forwards")"
    tunnel_registry_add "$peer" "$entry"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    # shellcheck disable=SC2086  # $forwards intentionally word-splits into l:r pair args
    tunnel_generate_plist "$peer" "$FX_IP" "$TUNNEL_LOG_DIR/tunnel-$peer.log" "$peer" $forwards > "$plist"
    chmod 0644 "$plist"
}

# parked tunnel: registered + plist, label disabled in the store
_make_parked() {
    local peer="$1" forwards="${2:-8443:443}"
    _register "$peer" "$forwards"
    tunnel_job_disable "$(tunnel_label_for_peer "$peer")"
}

test_start_usage_errors() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_start --frobnicate >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "unknown flag"
    rc=0
    tunnel_do_start web extra >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "extra argument"
    rc=0
    tunnel_do_start web --all >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "--all and a peer are mutually exclusive"
}

test_start_not_found_exit_3_with_hint() {
    _tunnel_setup_sandbox
    _register prime "8443:443"
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "3" "$rc" "not-found rc"
    assert_contains "tunnel for 'web' not found" "$out"
    assert_contains "registered tunnels:" "$out"
}

test_start_empty_registry_is_a_clean_noop() {
    _tunnel_setup_sandbox
    local rc=0 out
    out="$(tunnel_do_start 2>&1)" || rc=$?
    assert_eq "0" "$rc" "no-peer form on empty registry"
    assert_contains "No tunnels configured." "$out"
    rc=0
    out="$(tunnel_do_start --all 2>&1)" || rc=$?
    assert_eq "0" "$rc" "--all on empty registry"
    assert_contains "No tunnels configured." "$out"
}

test_start_resumes_a_parked_tunnel() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    _make_parked web
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "resume rc"
    assert_contains "Started: web" "$out"
    assert_contains "URL: https://web.$FX_SUFFIX:8443" "$out"
    assert_contains "\"$WEB_LABEL\" => enabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
    assert_ok "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_stop_start_round_trip_preserves_port_and_plist() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    _register web "8443:443"
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_bootstrap "$plist"
    local bytes_before lport_before
    bytes_before="$(md5 -q "$plist")"
    lport_before="$(tunnel_registry_field "$(tunnel_registry_get web)" forwards)"
    assert_ok tunnel_do_stop web
    assert_ok tunnel_do_start web
    assert_eq "$bytes_before" "$(md5 -q "$plist")" "plist bytes unchanged"
    assert_eq "$lport_before" "$(tunnel_registry_field "$(tunnel_registry_get web)" forwards)" "local port unchanged"
}

test_start_already_running_is_a_noop() {
    _tunnel_setup_sandbox
    _register web
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_bootstrap "$plist"
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "already running rc"
    assert_contains "Already running: web" "$out"
}

test_start_repairs_running_disabled() {
    _tunnel_setup_sandbox
    _register web
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_bootstrap "$plist"
    tunnel_job_disable "$WEB_LABEL"
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "running-disabled repair rc"
    assert_contains "Already running: web" "$out"
    # the flag is gone afterwards: the tunnel survives the next login
    assert_contains "\"$WEB_LABEL\" => enabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
}

test_start_missing_plist_fails_before_any_launchctl_call() {
    _tunnel_setup_sandbox
    _make_parked web
    rm -f "$(tunnel_plist_path_for_peer web)"
    local store_before
    store_before="$(cat "$LAUNCHCTL_DISABLED_STATE")"
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "missing plist rc"
    assert_contains "repair: tailroute tunnel remove web && tailroute tunnel add web" "$out"
    # the store is byte-identical: enable never ran
    assert_eq "$store_before" "$(cat "$LAUNCHCTL_DISABLED_STATE")" "store untouched"
}

test_start_enable_failure_fails_the_peer() {
    _tunnel_setup_sandbox
    _register web
    export FAIL_ENABLE=1
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    export FAIL_ENABLE=0
    assert_eq "1" "$rc" "enable seam rc"
    assert_contains "enable failed" "$out"
}

test_start_bootstrap_failure_shows_stderr_and_log_path() {
    _tunnel_setup_sandbox
    _register web
    export FAIL_BOOTSTRAP=1
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    export FAIL_BOOTSTRAP=0
    assert_eq "1" "$rc" "bootstrap seam rc"
    assert_contains "bootstrap failed" "$out"
    assert_contains "$TUNNEL_LOG_DIR/tunnel-web.log" "$out"
}

test_start_slow_listener_warns_and_exits_zero() {
    _tunnel_setup_sandbox
    # FAKE_NC_OPEN stays empty: no local port answers the poll
    _register web
    local rc=0 out
    out="$(tunnel_do_start web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "slow listener is a warning, not a failure"
    assert_contains "not listening yet" "$out"
    assert_contains "tailroute tunnel check web" "$out"
}

test_start_all_form_reports_per_peer_and_exits_1_on_any_failure() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    _make_parked web
    _make_parked web2
    rm -f "$(tunnel_plist_path_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_start --all 2>&1)" || rc=$?
    assert_eq "1" "$rc" "one failing peer fails the all-form"
    assert_contains "Started: web2" "$out"
    assert_contains "repair: tailroute tunnel remove web && tailroute tunnel add web" "$out"
    assert_contains "\"com.tailroute.tunnel.web2\" => enabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
}
