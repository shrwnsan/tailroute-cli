#!/usr/bin/env bash
# test-tunnel-repair.sh — `tunnel repair <peer>`: rebuild a missing launchd
# plist from the registry entry.
#
# The behaviour that matters is that repair is NOT remove+add: the forward
# map, hosts mapping, and registry row are used exactly as stored, so the
# URLs a user has bookmarked keep working. These tests pin that, plus the
# refusal when a plist already exists (repair is not restart).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$TEST_DIR/tunnel-fixtures.sh"

# _register <peer> [forwards] — registry entry + plist (not bootstrapped)
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

test_repair_usage_errors() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_repair >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "missing peer"
    rc=0
    tunnel_do_repair --frobnicate web >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "unknown flag"
    rc=0
    tunnel_do_repair web extra >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "extra argument"
}

test_repair_not_found_exit_3_with_hint() {
    _tunnel_setup_sandbox
    _register prime "8443:443"
    local rc=0 out
    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    assert_eq "3" "$rc" "not-found rc"
    assert_contains "tunnel for 'web' not found" "$out"
    assert_contains "registered tunnels:" "$out"
}

# The whole point: a missing plist is rebuilt, not re-registered.
test_repair_rebuilds_the_plist_from_the_registry() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    rm -f "$plist"
    [ ! -f "$plist" ] || { _assert_fail "precondition: plist should be gone"; return 1; }

    local rc=0 out
    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "repair rc"
    [ -f "$plist" ] || { _assert_fail "plist was not rebuilt"; return 1; }
    assert_contains "Tunnel repaired: web" "$out"
}

# A multi-forward peer must come back with the same ports in the same order.
# remove+add would reallocate locals from the lowest free port and lose this.
test_repair_preserves_every_forward_and_its_local_port() {
    _tunnel_setup_sandbox
    _register web "8443:10254 8444:10255 8449:8445"
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    rm -f "$plist"

    local rc=0 out
    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    assert_eq "0" "$rc" "repair rc"
    assert_contains "3 forward(s) unchanged" "$out"

    local body
    body="$(cat "$plist")"
    assert_contains "127.0.0.1:8443:100.100.100.100:10254" "$body"
    assert_contains "127.0.0.1:8444:100.100.100.100:10255" "$body"
    assert_contains "127.0.0.1:8449:100.100.100.100:8445" "$body"
}

# The registry row is the source of truth and must survive untouched.
test_repair_leaves_the_registry_and_hosts_alone() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    local before after plist
    before="$(tunnel_registry_get web)"
    plist="$(tunnel_plist_path_for_peer web)"
    rm -f "$plist"

    tunnel_do_repair web >/dev/null 2>&1 || { _assert_fail "repair failed"; return 1; }
    after="$(tunnel_registry_get web)"
    assert_eq "$before" "$after" "registry entry is byte-identical"

    # hosts mapping is not repaired here (it is a separate condition), so the
    # sandbox hosts file must not have gained tunnel lines either.
    if grep -q "$FX_HOSTNAME\|web\." "$TUNNEL_HOSTS_FILE" 2>/dev/null; then
        _assert_fail "repair must not write the hosts file"
        return 1
    fi
}

# repair is for a MISSING plist; an existing one means the caller wants
# restart, and silently overwriting a live job would be the wrong verb.
test_repair_refuses_when_the_plist_exists() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    local plist rc=0 out
    plist="$(tunnel_plist_path_for_peer web)"
    [ -f "$plist" ] || { _assert_fail "precondition: plist should exist"; return 1; }
    local before
    before="$(cat "$plist")"

    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "existing-plist rc"
    assert_contains "already exists" "$out"
    assert_contains "tunnel restart web" "$out"
    assert_eq "$before" "$(cat "$plist")" "plist not rewritten"
}

test_repair_dry_run_writes_nothing() {
    _tunnel_setup_sandbox
    _register web "8443:443 8444:8000"
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    rm -f "$plist"

    local rc=0 out
    out="$(tunnel_do_repair web --dry-run 2>&1)" || rc=$?
    assert_eq "0" "$rc" "dry-run rc"
    assert_contains "Would rebuild" "$out"
    assert_contains "8443:443 8444:8000" "$out"
    assert_contains "Nothing written" "$out"
    [ ! -f "$plist" ] || { _assert_fail "dry-run must not create the plist"; return 1; }
}

# A registry row with no forwards cannot be rebuilt; saying so beats writing
# a plist with no -L args (which would bootstrap a job that forwards nothing).
#
# Unreachable through the CLI — `tunnel_registry_add` rejects an empty
# forward list — so this is a defensive guard against a hand-edited or
# truncated registry. The entry is written straight to the file to reach it.
test_repair_refuses_when_the_registry_has_no_forwards() {
    _tunnel_setup_sandbox
    cat > "$TUNNEL_REGISTRY" <<'JSON'
{"tunnels":[{"peer":"web","peerID":"web.aaaaaaaa","jobID":"com.tailroute.tunnel.web","tailscaleIP":"100.100.100.100","hostname":"web.tailnet.ts.net","magicDNSSuffix":"tailnet.ts.net","sshAlias":"web","forwards":[],"plistPath":"/nonexistent/web.plist","allowUnverifiedTLS":false,"transactions":[],"createdAt":"2026-01-01T00:00:00Z"}],"version":2}
JSON

    local rc=0 out
    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    assert_eq "1" "$rc" "no-forwards rc"
    assert_contains "no forwards" "$out"
}

# The rebuilt job must be enabled: a repaired tunnel that comes up disabled
# dies at the next login, which is worse than staying broken.
test_repair_clears_a_stale_disable_flag() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    local label plist
    label="$(tunnel_label_for_peer web)"
    plist="$(tunnel_plist_path_for_peer web)"
    tunnel_job_disable "$label"
    rm -f "$plist"

    local rc=0
    tunnel_do_repair web >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "repair rc"
    assert_contains "\"$label\" => enabled" "$("$LAUNCHCTL_CMD" print-disabled "gui/$UID")"
}

test_repair_bootstrap_failure_is_reported_and_keeps_the_plist() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    local plist
    plist="$(tunnel_plist_path_for_peer web)"
    rm -f "$plist"
    export FAIL_BOOTSTRAP=1

    local rc=0 out
    out="$(tunnel_do_repair web 2>&1)" || rc=$?
    export FAIL_BOOTSTRAP=0
    assert_eq "1" "$rc" "bootstrap failure rc"
    assert_contains "refused to bootstrap" "$out"
    # The plist is intentionally kept: it is mine to keep, and `restart`
    # can use it, whereas deleting it would lose the rebuild.
    [ -f "$plist" ] || { _assert_fail "rebuilt plist should be kept on bootstrap failure"; return 1; }
}

# Advice surfaces must not send users to the destructive sequence.
test_plist_missing_advice_points_at_repair() {
    _tunnel_setup_sandbox
    _register web "8443:443"
    rm -f "$(tunnel_plist_path_for_peer web)"

    local out
    out="$(tunnel_do_start web 2>&1 || true)"
    assert_contains "tailroute tunnel repair web" "$out"
    if printf '%s' "$out" | grep -q 'tunnel remove web'; then
        _assert_fail "status advice must not recommend remove && add"
        return 1
    fi
}
