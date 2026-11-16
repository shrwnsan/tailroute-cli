#!/usr/bin/env bash
# test-lib-proxy-monitor.sh — Tests for lib-proxy-monitor.sh (T-001)
#
# Decision table under test:
#   no pid file, no prior state     → hands off (never auto-start)
#   pid file gone, state was set    → user stopped it; disengage
#   pid live                        → healthy; crash window resets
#   pid dead                        → restart with backoff 5/10/20
#   3 restarts in 60s               → disabled, no further spawns
#   manual reset                    → re-arms a disabled monitor
#
# Mock seams: _pm_spawn_proxy, _pm_port_open, _pm_now, _tr_resolve_target_user.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PM_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pm-test.XXXXXX" 2>/dev/null || mktemp -d)"
export PM_TEST_DIR

# Target-user resolution is stubbed: tests run unprivileged, the lib must
# never depend on the real console user.
TR_HOME="$PM_TEST_DIR/home"
source "$SCRIPT_DIR/../bin/lib-proxy-monitor.sh"

# Populate the target-user globals up front: the harness runs set -u, and
# helpers below touch the pid/state paths before any tick has resolved them.
_TR_TARGET_USER="testuser"
_TR_TARGET_HOME="$TR_HOME"
_TR_TARGET_UID="501"

# Test overrides — after sourcing so the lib's own definitions lose.
_tr_resolve_target_user() {
    _TR_TARGET_USER="testuser"
    _TR_TARGET_HOME="$TR_HOME"
    _TR_TARGET_UID="501"
    return 0
}
_pm_now() {
    printf '%s' "${PM_CLOCK:-1000}"
}

pm_setup() {
    rm -rf "$TR_HOME"
    mkdir -p "$TR_HOME/.tailroute/bin" "$TR_HOME/.tailroute/proxy-state"
    # Fake binary at the lib's fallback path (resolve_proxy_bin is absent in
    # this harness), so _pm_proxy_bin resolves and restart tests can run.
    printf '#!/bin/sh\nexit 0\n' > "$TR_HOME/.tailroute/bin/tailroute-proxy"
    chmod +x "$TR_HOME/.tailroute/bin/tailroute-proxy"
    _PM_STATE=""
    _PM_CRASHES=()
    _PM_NEXT_ATTEMPT=0
    _PM_PID=""
    PM_CLOCK=1000
    PM_SPAWN_CALLS=()
    PM_PORT_OPEN=1
}
pm_teardown() {
    rm -rf "$TR_HOME"
}

# Spawn recorder: never exec anything.
_pm_spawn_proxy() {
    local user="$1" home="$2" bin="$3"
    PM_SPAWN_CALLS+=("$user|$home|$bin|${PM_CLOCK}")
    _PM_PID="9876"
    printf '%s\n' "$_PM_PID" > "$(_pm_pid_file)" 2>/dev/null || true
    return 0
}
# Port probe recorder.
_pm_port_open() {
    return $((1 - PM_PORT_OPEN))
}

pm_write_pid() {
    printf '%s\n' "${1:-4242}" > "$(_pm_pid_file)"
}
pm_remove_pid() {
    rm -f "$(_pm_pid_file)"
}
pm_state() {
    _pm_resolve_target >/dev/null 2>&1 || return 1
    "$PM_CAT_CMD" "$(_pm_state_file)" 2>/dev/null | grep '^state=' | cut -d= -f2
}

# =============================================================================
# no pid file + no state → hands off (never auto-starts)
# =============================================================================

test_tick_hands_off_when_never_started() {
    pm_setup
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ -z "$(pm_state)" ]] || return 1
    pm_teardown
}

# =============================================================================
# live pid → healthy, no spawn
# =============================================================================

test_tick_healthy_when_pid_live() {
    pm_setup
    # kill -0 on our own shell's PID is always alive
    pm_write_pid "$$"
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ "$(pm_state)" == "running" ]] || return 1
    pm_teardown
}

# =============================================================================
# pid file missing after known state → user stopped it; disengage
# =============================================================================

test_tick_disengages_when_user_stopped() {
    pm_setup
    _PM_STATE="running"
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ -z "$_PM_STATE" ]] || return 1
    [[ ! -f "$(_pm_state_file)" ]] || return 1
    pm_teardown
}

# =============================================================================
# dead pid → restart once, state restarting, crash recorded
# =============================================================================

test_tick_restarts_dead_pid() {
    pm_setup
    _PM_STATE="running"
    pm_write_pid 4242  # no such pid (unless the box really has 4242; acceptable)
    if "$PM_KILL_CMD" -0 4242 2>/dev/null; then
        pm_write_pid 999999999
    fi
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 1 ]] || return 1
    [[ "${PM_SPAWN_CALLS[0]}" == "testuser|$TR_HOME|"* ]] || return 1
    [[ "$(pm_state)" == "restarting" ]] || return 1
    [[ ${#_PM_CRASHES[@]} -eq 1 ]] || return 1
    pm_teardown
}

# =============================================================================
# backoff gate: second crash inside the window is deferred, not immediate
# =============================================================================

test_tick_backoff_defers_second_restart() {
    pm_setup
    _PM_STATE="running"
    _PM_CRASHES=(990)          # one crash 10s ago
    _PM_NEXT_ATTEMPT=1100      # 5s backoff → attempt allowed at 1005? no: 1000<1100 → gated
    pm_write_pid 999999999
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ "$(pm_state)" == "restarting" ]] || return 1
    pm_teardown
}

test_tick_backoff_elapses_then_restarts() {
    pm_setup
    _PM_STATE="restarting"
    _PM_CRASHES=(990)
    _PM_NEXT_ATTEMPT=995       # gate elapsed (clock 1000)
    pm_write_pid 999999999
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 1 ]] || return 1
    # delay after 1 crash in window = 5 * 2^1 = 10
    [[ "$_PM_NEXT_ATTEMPT" -eq 1010 ]] || return 1
    pm_teardown
}

# =============================================================================
# restart-loop guard: 3 crashes in the window → disabled, no more spawns
# =============================================================================

test_tick_disables_after_three_restarts() {
    pm_setup
    _PM_STATE="restarting"
    _PM_CRASHES=(990 995 998)  # three crashes, all inside 60s of clock 1000
    pm_write_pid 999999999
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ "$(pm_state)" == "disabled" ]] || return 1
    pm_teardown
}

test_tick_disabled_stays_disabled() {
    pm_setup
    _PM_STATE="disabled"
    _PM_CRASHES=(995 998 999)
    _pm_write_state   # persisted from the transition tick that disabled it
    pm_write_pid 999999999
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ "$(pm_state)" == "disabled" ]] || return 1
    pm_teardown
}

test_tick_window_prunes_old_crashes() {
    pm_setup
    _PM_STATE="restarting"
    _PM_CRASHES=(900 905 910 980)  # three stale (>60s), one fresh
    pm_write_pid 999999999
    proxy_monitor_tick
    # Only the fresh crash counts → restart allowed
    [[ ${#PM_SPAWN_CALLS[@]} -eq 1 ]] || return 1
    [[ ${#_PM_CRASHES[@]} -eq 2 ]] || return 1
    pm_teardown
}

# =============================================================================
# recovery: next tick after a successful restart sees a live pid → running
# =============================================================================

test_tick_recovers_after_restart() {
    pm_setup
    _PM_STATE="restarting"
    _PM_CRASHES=(990)
    pm_write_pid "$$"          # restart landed, process alive
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    [[ "$(pm_state)" == "running" ]] || return 1
    # Sustained health past the window prunes crashes
    PM_CLOCK=1100
    proxy_monitor_tick
    [[ ${#_PM_CRASHES[@]} -eq 0 ]] || return 1
    pm_teardown
}

# =============================================================================
# manual start re-arms: reset clears disabled and the state file
# =============================================================================

test_reset_rearms_disabled_monitor() {
    pm_setup
    _PM_STATE="disabled"
    _PM_CRASHES=(995 998 999)
    _pm_write_state
    [[ -f "$(_pm_state_file)" ]] || return 1
    proxy_monitor_reset
    [[ -z "$_PM_STATE" ]] || return 1
    [[ ${#_PM_CRASHES[@]} -eq 0 ]] || return 1
    [[ ! -f "$(_pm_state_file)" ]] || return 1
    # after reset with no pid file, the monitor stays hands-off
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 0 ]] || return 1
    # a dead pid afterwards is a fresh crash and restarts cleanly
    pm_write_pid 999999999
    proxy_monitor_tick
    [[ ${#PM_SPAWN_CALLS[@]} -eq 1 ]] || return 1
    [[ "${#_PM_CRASHES[@]}" -eq 1 ]] || return 1
    pm_teardown
}

# =============================================================================
# proxy_monitor_state formatting
# =============================================================================

test_state_reader_formats_running() {
    pm_setup
    _PM_STATE="running"
    _PM_NEXT_ATTEMPT=0
    _pm_write_state
    [[ "$(proxy_monitor_state "$(_pm_state_file)")" == "healthy" ]] || return 1
    pm_teardown
}

test_state_reader_formats_restarting() {
    pm_setup
    _PM_STATE="restarting"
    PM_CLOCK=1000
    _PM_NEXT_ATTEMPT=1015
    _pm_write_state
    # No countdown: the backoff clock belongs to the daemon's process, and
    # this reader must not translate it for another process.
    [[ "$(proxy_monitor_state "$(_pm_state_file)")" == "restarting (auto-restart in progress)" ]] || return 1
    pm_teardown
}

test_state_reader_off_when_missing() {
    pm_setup
    [[ "$(proxy_monitor_state "$(_pm_state_file)")" == "off" ]] || return 1
    pm_teardown
}

# =============================================================================
# state file ownership: non-root writes skip chown silently
# =============================================================================

test_write_state_skips_chown_unprivileged() {
    pm_setup
    _PM_STATE="running"
    _pm_write_state
    [[ -f "$(_pm_state_file)" ]] || return 1
    grep -q '^updated=' "$(_pm_state_file)" || return 1
    pm_teardown
}
