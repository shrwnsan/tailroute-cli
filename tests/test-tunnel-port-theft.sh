#!/usr/bin/env bash
# test-tunnel-port-theft.sh — a local port that is taken, reserved, or
# grabbed mid-add must never leave a half-built tunnel behind. Covers the
# refusal paths (explicit port, extra forward, exhausted range), allocation
# skipping live and registered ports, and a foreign listener appearing on
# the allocated port after the plist is written.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

PRIME_LABEL="com.tailroute.tunnel.prime"

# Nothing of the add may survive a refusal: registry, hosts, plist, job,
# journal and both locks all back to their pre-add state.
_assert_nothing_left_behind() {
    local registered=0
    tunnel_registry_get prime >/dev/null 2>&1 && registered=1
    assert_eq "0" "$registered" "registry entry"
    if grep -q "$FX_HOSTNAME" "$TUNNEL_HOSTS_FILE"; then
        echo "hosts file still maps $FX_HOSTNAME"; return 1
    fi
    [ ! -e "$TUNNEL_LAUNCHAGENTS_DIR/$PRIME_LABEL.plist" ] || { echo "plist left behind"; return 1; }
    if grep -qx "$PRIME_LABEL" "$LAUNCHCTL_STATE"; then
        echo "job still loaded"; return 1
    fi
    [ ! -e "$TUNNEL_JOURNAL_PATH" ] || { echo "journal left behind"; return 1; }
    [ ! -e "$TUNNEL_LOCK_DIR" ] || { echo "per-user lock still held"; return 1; }
    [ ! -e "$TUNNEL_HOSTS_LOCK_DIR" ] || { echo "hosts lock still held"; return 1; }
}

test_explicit_port_in_use_is_refused_before_any_mutation() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    local rc=0 out
    out="$(tunnel_do_add prime --yes --port 8443 2>&1)" || rc=$?
    assert_eq "1" "$rc" "add rc"
    assert_contains "port 8443 is in use" "$out"
    _assert_nothing_left_behind
}

test_extra_forward_port_in_use_is_refused_before_any_mutation() {
    _tunnel_setup_sandbox
    # 8443 is free, but the second forward would land on the taken 8444
    export FAKE_NC_OPEN="8444"
    local rc=0 out
    out="$(tunnel_do_add prime --yes --port 8443 --remote-port 443,8080 2>&1)" || rc=$?
    assert_eq "1" "$rc" "add rc"
    assert_contains "local port 8444 for remote 8080 is in use" "$out"
    _assert_nothing_left_behind
}

test_exhausted_port_range_is_refused_before_any_mutation() {
    _tunnel_setup_sandbox
    local saved_start="$TUNNEL_PORT_START" saved_end="$TUNNEL_PORT_END"
    TUNNEL_PORT_START=8443; TUNNEL_PORT_END=8443
    export FAKE_NC_OPEN="8443"
    local rc=0 out
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    TUNNEL_PORT_START="$saved_start"; TUNNEL_PORT_END="$saved_end"
    assert_eq "1" "$rc" "add rc"
    assert_contains "no free port in 8443-8443" "$out"
    _assert_nothing_left_behind
}

test_allocation_skips_a_live_listener() {
    _tunnel_setup_sandbox
    export FAKE_NC_OPEN="8443"
    local rc=0 out
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    assert_eq "0" "$rc" "add rc"
    assert_contains "https://$FX_HOSTNAME:8444" "$out"
    assert_contains "127.0.0.1:8444:" "$(cat "$TUNNEL_LAUNCHAGENTS_DIR/$PRIME_LABEL.plist")"
}

# A parked or crashed tunnel has no listener, but its port is still spoken
# for: handing it to a new tunnel would break the first one on start.
test_allocation_skips_a_registered_port_with_no_listener() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json taken 100.64.0.9 taken.tailnet.ts.net tailnet.ts.net 8443:443)"
    tunnel_registry_add taken "$entry" >/dev/null
    export FAKE_NC_OPEN=""
    local rc=0 out
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    assert_eq "0" "$rc" "add rc"
    assert_contains "https://$FX_HOSTNAME:8444" "$out"
}

test_explicit_port_registered_to_another_tunnel_is_not_silently_shared() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json taken 100.64.0.9 taken.tailnet.ts.net tailnet.ts.net 8443:443)"
    tunnel_registry_add taken "$entry" >/dev/null
    export FAKE_NC_OPEN="8443"   # the other tunnel is up and listening
    local rc=0 out
    out="$(tunnel_do_add prime --yes --port 8443 2>&1)" || rc=$?
    assert_eq "1" "$rc" "add rc"
    assert_contains "port 8443 is in use" "$out"
    _assert_nothing_left_behind
}

# The port is free when chosen, then another process binds it before the
# job comes up. The identity check must reject whatever answers there and
# the add must unwind completely, leaving the port free to retry.
test_foreign_listener_appearing_after_allocation_rolls_the_add_back() {
    _tunnel_setup_sandbox
    cat > "$TUNNEL_SANDBOX/bin/nc" <<'MOCK'
#!/bin/sh
[ "$1" = "-z" ] || exit 0
# the squatter shows up once the plist is written, i.e. after allocation
if [ "$3" = "8443" ] && [ -e "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" ]; then
    exit 0
fi
exit 1
MOCK
    chmod +x "$TUNNEL_SANDBOX/bin/nc"
    export FAKE_TLS_HOSTNAME="wrong-host"
    local rc=0 out
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    assert_eq "1" "$rc" "add rc"
    assert_contains "TLS certificate does not match" "$out"
    assert_contains "rolled back · job unloaded" "$out"
    _assert_nothing_left_behind

    # the squatter leaves; the same add now succeeds on the same port
    export FAKE_TLS_HOSTNAME="prime.tailnet.ts.net"
    cat > "$TUNNEL_SANDBOX/bin/nc" <<'MOCK'
#!/bin/sh
exit 1
MOCK
    rc=0
    out="$(tunnel_do_add prime --yes 2>&1)" || rc=$?
    assert_eq "0" "$rc" "retry rc"
    assert_contains "https://$FX_HOSTNAME:8443" "$out"
}
