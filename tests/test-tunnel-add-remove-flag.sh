#!/usr/bin/env bash
# test-tunnel-add-remove-flag.sh — disable-flag hygiene across the mutating
# verbs: remove clears the flag unconditionally, add enables before its
# single bootstrap (fresh and adopted), and the incremental update refuses
# to rebuild a parked or flagged job in place.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

PRIME_LABEL="com.tailroute.tunnel.prime"

_store_state() { # <label> — disabled|enabled|absent
    awk -v l="$1" -F'\t' '$1 == l { print $2; exit }' "$LAUNCHCTL_DISABLED_STATE" 2>/dev/null
}

# park prime: disable the label and unload the job (what `tunnel stop` lands)
_park_prime() {
    tunnel_job_disable "$PRIME_LABEL"
    tunnel_job_bootout "$PRIME_LABEL"
}

test_remove_clears_the_disable_flag() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    _park_prime
    assert_eq "disabled" "$(_store_state "$PRIME_LABEL")" "parked before remove"
    local rc=0
    tunnel_do_remove prime >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "remove rc"
    # the registry entry is gone but the flag must not linger
    assert_eq "enabled" "$(_store_state "$PRIME_LABEL")" "flag cleared by remove"
}

test_remove_then_readd_bootstraps() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    _park_prime
    tunnel_do_remove prime >/dev/null 2>&1
    local rc=0 out
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    assert_eq "0" "$rc" "re-add after remove"
    assert_contains "Tunnel added: prime" "$out"
    grep -qx "$PRIME_LABEL" "$LAUNCHCTL_STATE" || { echo "re-added job not bootstrapped"; return 1; }
}

test_manually_disabled_prototype_is_adopted_and_bootstraps() {
    _tunnel_setup_sandbox
    # a hand-rolled prototype job whose label someone disabled out-of-band
    cat > "$TUNNEL_LAUNCHAGENTS_DIR/$PRIME_LABEL.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tailroute.tunnel.prime</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-N</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-L</string>
        <string>127.0.0.1:8443:100.100.100.100:443</string>
        <string>proxy-prime</string>
    </array>
</dict>
</plist>
PLIST
    tunnel_job_disable "$PRIME_LABEL"
    local rc=0 out
    out="$(tunnel_do_add prime --yes --adopt 2>&1)" || rc=$?
    assert_eq "0" "$rc" "adoption of a disabled prototype"
    assert_contains "Tunnel added: prime" "$out"
    grep -qx "$PRIME_LABEL" "$LAUNCHCTL_STATE" || { echo "adopted job not bootstrapped"; return 1; }
    assert_eq "enabled" "$(_store_state "$PRIME_LABEL")" "adoption cleared the flag"
}

test_update_refused_while_stopped_touches_nothing() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    _park_prime
    local plist
    plist="$(tunnel_plist_path_for_peer prime)"
    local bytes_before fwd_before
    bytes_before="$(md5 -q "$plist")"
    fwd_before="$(tunnel_registry_field "$(tunnel_registry_get prime)" forwards)"
    local rc=0 out
    out="$(tunnel_do_add prime --remote-port 8444 --yes 2>&1)" || rc=$?
    assert_eq "1" "$rc" "update while parked rc"
    assert_contains "tunnel is stopped — start it first: tailroute tunnel start prime" "$out"
    assert_eq "$bytes_before" "$(md5 -q "$plist")" "plist untouched"
    assert_eq "$fwd_before" "$(tunnel_registry_field "$(tunnel_registry_get prime)" forwards)" "registry untouched"
}

test_update_refused_while_running_disabled() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    tunnel_job_disable "$PRIME_LABEL"
    local rc=0 out
    out="$(tunnel_do_add prime --remote-port 8444 --yes 2>&1)" || rc=$?
    assert_eq "1" "$rc" "update while running-disabled rc"
    assert_contains "reconcile: tailroute tunnel start prime (keep) or tailroute tunnel stop prime (park)" "$out"
}
