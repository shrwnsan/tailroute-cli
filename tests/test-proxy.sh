#!/usr/bin/env bash
# test-proxy.sh — Proxy registry validation, binary location, and auth tests
#
# Covers issue #42:
#   - the proxy pidfile registry must be validated against reality (the pid
#     must be alive, must be a tailroute-proxy process, and must own the SOCKS
#     listener when one exists) and must self-heal on mismatch — a replaced
#     spawn left a stale pid that `proxy status` reported for days;
#   - a listener on the SOCKS port that is NOT tailroute-proxy must be
#     reported as such instead of a bare "Stopped";
#   - exactly one canonical proxy binary should exist per install (the legacy
#     /usr/local/bin placement is retired on install);
#   - `proxy auth` must surface the login URL or the NeedsLogin state instead
#     of printing "Open the URL below" with nothing under it.
#
# Everything here runs in a scratch HOME with a fixture process table — no
# live process, port, or binary is touched. mktemp always gets an explicit
# template path: bare `mktemp -d` ignores TMPDIR on macOS.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tailroute.sh bakes proxy paths from $HOME at source time, so the sandbox
# HOME must be in place before sourcing (inside each test's subshell).
_load_tailroute() {
    # shellcheck source=../bin/tailroute.sh
    source "$TEST_DIR/../bin/tailroute.sh"
}

# -----------------------------------------------------------------------------
# Fixture process table
# -----------------------------------------------------------------------------
# "Alive" fixture pids must be pids this shell may signal ($$ / $PPID);
# "dead" ones must not exist (e.g. 99999) — kill -0 stays real. Note pid 1
# is useless here: kill -0 from a non-root shell is EPERM, not success.
# ps/pgrep/lsof resolve from fixture files.

_setup_proxy_sandbox() {
    PROXY_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tailroute-proxy-test.XXXXXX")"
    export HOME="$PROXY_TEST_HOME"
    mkdir -p "$PROXY_TEST_HOME/.tailroute/bin" "$PROXY_TEST_HOME/.tailroute/proxy-state"
    PROXY_TEST_PROC="$PROXY_TEST_HOME/proc"
    mkdir -p "$PROXY_TEST_PROC"
    _load_tailroute
    _install_proxy_mocks
}

_install_proxy_mocks() {
    # Matches the exact call shape in tailroute.sh: ps -p PID -o comm=
    ps() {
        local pid="${2:-}"
        if [[ -n "$pid" && -f "$PROXY_TEST_PROC/$pid" ]]; then
            cat "$PROXY_TEST_PROC/$pid"
            return 0
        fi
        return 1
    }
    # pgrep -f NAME — prints the fixture pid list, empty means no match
    pgrep() {
        if [[ -s "$PROXY_TEST_HOME/pgrep.out" ]]; then
            cat "$PROXY_TEST_HOME/pgrep.out"
            return 0
        fi
        return 1
    }
    # lsof -nP -iTCP:PORT -sTCP:LISTEN -t — prints fixture listener pids,
    # empty means nothing is listening
    lsof() {
        if [[ -s "$PROXY_TEST_HOME/lsof.out" ]]; then
            cat "$PROXY_TEST_HOME/lsof.out"
        fi
        return 0
    }
    # nc -z host port — port probes stay closed unless a test opens them
    nc() { return 1; }
}

fake_comm() { printf '%s' "$2" > "$PROXY_TEST_PROC/$1"; }
fake_pgrep() {
    if [[ $# -eq 0 ]]; then : > "$PROXY_TEST_HOME/pgrep.out"
    else printf '%s\n' "$@" > "$PROXY_TEST_HOME/pgrep.out"; fi
}
fake_lsof() {
    if [[ $# -eq 0 ]]; then : > "$PROXY_TEST_HOME/lsof.out"
    else printf '%s\n' "$@" > "$PROXY_TEST_HOME/lsof.out"; fi
}

_cleanup_proxy_sandbox() {
    [[ -n "${PROXY_TEST_HOME:-}" && -d "$PROXY_TEST_HOME" ]] && rm -rf "$PROXY_TEST_HOME"
    return 0
}

# =============================================================================
# Registry validation and self-heal (#42 defect 2)
# =============================================================================

test_registered_live_proxy_pid_is_trusted() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"
    fake_comm $$ tailroute-proxy

    assert_eq "$$" "$(get_proxy_pid)"
}

test_stale_pidfile_falls_back_to_live_proxy_and_self_heals() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"     # dead pid in the registry
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")" "registry must self-heal to the live proxy"
}

test_pidfile_pid_reused_by_foreign_process_is_rejected() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"        # alive — but it is this test shell
    fake_comm $$ bash
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)" "a reused pid must not read as the proxy"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")"
}

test_registered_proxy_displaced_from_the_socks_port_is_rejected() {
    # 2026-09-21 incident: the registry pointed at the old spawn while a
    # replaced spawn owned 1055. The listener is ground truth.
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"
    fake_comm $$ tailroute-proxy       # alive and looks right…
    fake_lsof $PPID                    # …but $PPID owns the SOCKS listener
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")"
}

test_startup_window_without_listener_still_reports_running() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"        # spawned (alive), not yet listening
    fake_comm $$ tailroute-proxy

    assert_ok is_proxy_running
    assert_eq "$$" "$(get_proxy_pid)"
}

test_dead_registry_entry_is_removed_when_nothing_is_running() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"
    fake_pgrep

    assert_fail is_proxy_running
    if [[ -f "$PROXY_PID_FILE" ]]; then
        _assert_fail "dead registry entry must be removed, not reported"
    fi
}

test_status_reports_foreign_listener_on_the_socks_port() {
    _setup_proxy_sandbox
    fake_pgrep
    fake_lsof 777
    fake_comm 777 nc                   # someone else holds 1055

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "held by pid 777" "$out"
    assert_contains "not tailroute-proxy" "$out"
}

test_status_reports_the_resolved_pid_not_the_stale_one() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "Running (pid $PPID)" "$out"
}
