#!/usr/bin/env bash
# test-tunnel-status-stopped.sh — the status state table (running, stopped,
# not-running, running-disabled) in human and JSON form, the plist-missing
# override, the exit-code contract, and the failed-store-read fallback.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

# register <peer> [forwards] — registry entry + plist
_register() {
    local peer="$1" forwards="${2:-8443:443}" entry plist
    entry="$(tunnel_build_entry_json "$peer" "$FX_IP" "$peer.$FX_SUFFIX" "$FX_SUFFIX" "$forwards")"
    tunnel_registry_add "$peer" "$entry"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    # shellcheck disable=SC2086  # $forwards intentionally word-splits into l:r pair args
    tunnel_generate_plist "$peer" "$FX_IP" "$TUNNEL_LOG_DIR/tunnel-$peer.log" "$peer" $forwards > "$plist"
    chmod 0644 "$plist"
    # status health requires the managed hosts mapping
    printf '127.0.0.1\t%s\n' "$peer.$FX_SUFFIX" >> "$TUNNEL_HOSTS_FILE"
}

_field() { # <json-out> <peer> <field>
    STATUS_JSON="$1" STATUS_PEER="$2" STATUS_FIELD="$3" "$PYTHON3_CMD" -c '
import json, os
d = json.loads(os.environ["STATUS_JSON"])
t = [t for t in d["tunnels"] if t["peer"] == os.environ["STATUS_PEER"]][0]
print(t[os.environ["STATUS_FIELD"]])
'
}

test_status_running_row() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    _register web
    tunnel_job_bootstrap "$(tunnel_plist_path_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "0" "$rc" "running row exit"
    assert_eq "running" "$(_field "$out" web job)"
    assert_eq "False" "$(_field "$out" web stopped)"
    assert_eq "False" "$(_field "$out" web disabled)"
    assert_eq "True" "$(_field "$out" web healthy)"
    rc=0
    out="$(tunnel_do_status --skip-remote-check 2>&1)" || rc=$?
    assert_eq "0" "$rc" "human running exit"
    assert_contains "Job:      running" "$out"
}

test_status_stopped_row_is_healthy_by_intent() {
    _tunnel_setup_sandbox
    _register web
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "0" "$rc" "parked is not degraded"
    assert_eq "stopped" "$(_field "$out" web job)"
    assert_eq "True" "$(_field "$out" web stopped)"
    assert_eq "True" "$(_field "$out" web disabled)"
    assert_eq "True" "$(_field "$out" web healthy)"
    rc=0
    out="$(tunnel_do_status --skip-remote-check 2>&1)" || rc=$?
    assert_eq "0" "$rc" "human parked exit"
    assert_contains "Job:      stopped (by request)" "$out"
    # the stale-hosts degradation must not fire for a deliberate stop
    if printf '%s' "$out" | grep -q "stale hosts entry"; then
        _assert_fail "stale hosts note must not fire for a parked tunnel"
    fi
}

test_status_not_running_row_is_degraded_with_stale_note() {
    _tunnel_setup_sandbox
    _register web
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_bootstrap "$plist"
    tunnel_job_bootout "$(tunnel_label_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "1" "$rc" "crashed job exit"
    assert_eq "not-running" "$(_field "$out" web job)"
    assert_eq "False" "$(_field "$out" web healthy)"
    rc=0
    out="$(tunnel_do_status --skip-remote-check 2>&1)" || rc=$?
    assert_eq "1" "$rc" "human crashed exit"
    assert_contains "stale hosts entry" "$out"
    assert_contains "repair: tailroute tunnel restart web" "$out"
}

test_status_running_disabled_row_is_flagged() {
    _tunnel_setup_sandbox
    _register web
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_bootstrap "$plist"
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "1" "$rc" "running-disabled exit"
    assert_eq "running" "$(_field "$out" web job)"
    assert_eq "True" "$(_field "$out" web disabled)"
    assert_eq "False" "$(_field "$out" web stopped)"
    assert_eq "False" "$(_field "$out" web healthy)"
    rc=0
    out="$(tunnel_do_status --skip-remote-check 2>&1)" || rc=$?
    assert_eq "1" "$rc" "human running-disabled exit"
    assert_contains "Job:      running (disabled)" "$out"
    assert_contains "will not survive next login" "$out"
    assert_contains "tailroute tunnel start web (keep) or tailroute tunnel stop web (park)" "$out"
}

test_status_plist_missing_never_reports_stopped() {
    _tunnel_setup_sandbox
    _register web
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    rm -f "$(tunnel_plist_path_for_peer web)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "1" "$rc" "plist-missing exit"
    assert_eq "not-running" "$(_field "$out" web job)"
    assert_eq "False" "$(_field "$out" web stopped)"
    assert_eq "True" "$(_field "$out" web disabled)"
    assert_contains "plist missing" "$out"
}

test_status_mixed_fleet_parked_plus_healthy_exits_zero() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    _register web 8444:443
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    _register prime
    tunnel_job_bootstrap "$(tunnel_plist_path_for_peer prime)"
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "0" "$rc" "one parked + one healthy is not degraded"
    assert_eq "stopped" "$(_field "$out" web job)"
    assert_eq "True" "$(_field "$out" web healthy)"
    assert_eq "running" "$(_field "$out" prime job)"
    assert_eq "True" "$(_field "$out" prime healthy)"
}

test_status_store_read_failure_never_yields_stopped() {
    _tunnel_setup_sandbox
    _register web
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    # unloaded + parked, but the store cannot be read: flag unknown
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    export FAIL_PRINT_DISABLED=1
    local rc=0 out
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "not-running" "$(_field "$out" web job)" "unloaded, flag unknown"
    assert_eq "False" "$(_field "$out" web stopped)"

    # loaded + flag unknown: running, never running-disabled
    export FAIL_PRINT_DISABLED=0
    tunnel_job_enable "$(tunnel_label_for_peer web)"
    tunnel_job_bootstrap "$plist"
    tunnel_job_disable "$(tunnel_label_for_peer web)"
    export FAIL_PRINT_DISABLED=1
    rc=0
    out="$(tunnel_do_status --json --skip-remote-check 2>&1)" || rc=$?
    assert_eq "running" "$(_field "$out" web job)" "loaded, flag unknown"
    assert_eq "False" "$(_field "$out" web disabled)"
    export FAIL_PRINT_DISABLED=0
}
