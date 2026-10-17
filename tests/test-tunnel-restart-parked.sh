#!/usr/bin/env bash
# test-tunnel-restart-parked.sh — restart under the per-user lock and its
# parked-aware refusals: stopped tunnels are never implicitly started,
# running-disabled is reconciled instead of bootout/bootstrap'd to death.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

WEB_LABEL="com.tailroute.tunnel.web"

# running tunnel: registered + plist + bootstrapped
_make_running() {
    local peer="$1" entry plist
    entry="$(tunnel_build_entry_json "$peer" "$FX_IP" "$peer.$FX_SUFFIX" "$FX_SUFFIX" "8443:443")"
    tunnel_registry_add "$peer" "$entry"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    tunnel_generate_plist "$peer" "$FX_IP" "$TUNNEL_LOG_DIR/tunnel-$peer.log" "$peer" "8443:443" > "$plist"
    chmod 0644 "$plist"
    tunnel_job_bootstrap "$plist"
}

# parked tunnel: registered + plist + disabled flag, not loaded
_make_parked() {
    local peer="$1"
    _make_running "$peer"
    tunnel_job_bootout "$(tunnel_label_for_peer "$peer")"
    tunnel_job_disable "$(tunnel_label_for_peer "$peer")"
}

test_restart_refuses_single_stopped_with_start_hint() {
    _tunnel_setup_sandbox
    _make_parked web
    local rc=0 out
    out="$(tunnel_do_restart web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "stopped restart rc"
    assert_contains "tunnel is stopped — start it: tailroute tunnel start web" "$out"
    # no implicit transition: still parked, still unloaded
    assert_contains "\"$WEB_LABEL\" => disabled" "$($LAUNCHCTL_CMD print-disabled gui/$UID)"
    assert_fail "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_restart_all_form_skips_stopped_without_failure() {
    _tunnel_setup_sandbox
    _make_parked web
    _make_running prime
    local rc=0 out
    out="$(tunnel_do_restart 2>&1)" || rc=$?
    assert_eq "0" "$rc" "a parked tunnel is not an all-form failure"
    assert_contains "Skipped: web (stopped)" "$out"
    assert_contains "Restarted: prime" "$out"
    # the parked tunnel was not touched
    assert_fail "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_restart_refuses_single_running_disabled_with_reconcile_hint() {
    _tunnel_setup_sandbox
    _make_running web
    tunnel_job_disable "$WEB_LABEL"
    local rc=0 out
    out="$(tunnel_do_restart web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "running-disabled restart rc"
    assert_contains "reconcile: tailroute tunnel start web (keep) or tailroute tunnel stop web (park)" "$out"
    # the bootout/bootstrap dance never ran: the job is still loaded
    assert_ok "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_restart_all_form_flags_running_disabled_as_failure() {
    _tunnel_setup_sandbox
    _make_running web
    tunnel_job_disable "$WEB_LABEL"
    _make_running prime
    local rc=0 out
    out="$(tunnel_do_restart 2>&1)" || rc=$?
    assert_eq "1" "$rc" "running-disabled counts as an all-form failure"
    assert_contains "Skipped: web (running-disabled" "$out"
    assert_contains "Restarted: prime" "$out"
    assert_ok "$LAUNCHCTL_CMD" print "gui/$UID/$WEB_LABEL"
}

test_restart_respects_the_operation_lock() {
    _tunnel_setup_sandbox
    _make_running web
    mkdir "$TUNNEL_LOCK_DIR"
    echo $$ > "$TUNNEL_LOCK_DIR/pid"
    local rc=0 out
    out="$(tunnel_do_restart web 2>&1)" || rc=$?
    rm -rf "$TUNNEL_LOCK_DIR"
    assert_eq "1" "$rc" "lock held elsewhere"
    assert_contains "another tailroute tunnel operation is in progress" "$out"
}
