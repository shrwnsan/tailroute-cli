#!/usr/bin/env bash
# test-tunnel-check-open-stopped.sh — the two read-side verbs on a parked
# tunnel: check names the stopped listener and points at start (keeping the
# output tokens the menu bar parses), open refuses before launching.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

# register <peer> — registry entry + plist + hosts mapping
_register() {
    local peer="$1" entry plist
    entry="$(tunnel_build_entry_json "$peer" "$FX_IP" "$peer.$FX_SUFFIX" "$FX_SUFFIX" "8443:443")"
    tunnel_registry_add "$peer" "$entry"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    tunnel_generate_plist "$peer" "$FX_IP" "$TUNNEL_LOG_DIR/tunnel-$peer.log" "$peer" "8443:443" > "$plist"
    chmod 0644 "$plist"
    printf '127.0.0.1\t%s\n' "$peer.$FX_SUFFIX" >> "$TUNNEL_HOSTS_FILE"
}

# parked: registered + plist + disabled flag, not loaded
_make_parked() {
    local peer="$1"
    _register "$peer"
    tunnel_job_disable "$(tunnel_label_for_peer "$peer")"
}

test_check_on_stopped_names_the_parked_listener() {
    _tunnel_setup_sandbox
    _make_parked web
    local rc=0 out
    out="$(tunnel_do_check web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "check on parked rc"
    assert_contains "listener: 127.0.0.1:8443 closed — stopped by request" "$out"
    assert_contains "repair: tailroute tunnel start web" "$out"
    # tokens the menu bar's diagnostics panel parses must survive
    assert_contains " -> remote " "$out"
    assert_contains ": check FAILED" "$out"
    # the old job-down text must not leak into the parked case
    if printf '%s' "$out" | grep -q "the tunnel job is down"; then
        _assert_fail "parked tunnel must not read as a dead job"
    fi
}

test_check_on_down_job_keeps_the_old_text() {
    _tunnel_setup_sandbox
    # registered but neither loaded nor flagged: not-running, the crash case
    _register web
    local rc=0 out
    out="$(tunnel_do_check web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "check on down job rc"
    assert_contains "closed — the tunnel job is down" "$out"
    assert_contains "repair: tailroute tunnel restart web" "$out"
}

test_open_on_stopped_refuses_without_launching() {
    _tunnel_setup_sandbox
    _make_parked web
    local rc=0 out
    out="$(tunnel_do_open web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "open on parked rc"
    assert_contains "tunnel is stopped — start it first: tailroute tunnel start web" "$out"
    # the browser was never launched
    assert_eq "" "$(cat "$FAKE_OPEN_LOG")" "open log"
}

test_open_on_non_stopped_still_launches() {
    _tunnel_setup_sandbox
    _register web
    local rc=0 out
    out="$(tunnel_do_open web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "open rc"
    assert_contains "Opened https://web.$FX_SUFFIX:8443" "$out"
    assert_contains "https://web.$FX_SUFFIX:8443" "$(cat "$FAKE_OPEN_LOG")"
}
