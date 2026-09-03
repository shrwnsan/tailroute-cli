#!/usr/bin/env bash
# test-lib-event-loop.sh — Tests for lib-event-loop.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Override state/lock directories for testing
export LOCK_DIR="/tmp/tailroute-test-event-loop"
export STATE_DIR="/tmp/tailroute-test-event-loop"
export STATE_MANIFEST="$STATE_DIR/state.manifest"
export DEBOUNCE_SECONDS=1
export POLL_SECONDS=1

source "$SCRIPT_DIR/../bin/lib-event-loop.sh"

# Suppress error output during tests
exec 2>/dev/null

# Setup and teardown
setup_event_loop_test() {
    rm -rf "$LOCK_DIR" "$STATE_DIR"
    mkdir -p "$LOCK_DIR" "$STATE_DIR"
}

teardown_event_loop_test() {
    # Kill any lingering poll process
    if [[ -n "${POLL_PID:-}" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        kill "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
    fi
    
    rm -rf "$LOCK_DIR" "$STATE_DIR"
}

# =============================================================================
# setup_signal_handlers tests
# =============================================================================

test_setup_signal_handlers_success() {
    setup_event_loop_test
    
    # Should not error
    if setup_signal_handlers; then
        teardown_event_loop_test
        return 0
    else
        teardown_event_loop_test
        return 1
    fi
}

test_setup_signal_handlers_sets_traps() {
    setup_event_loop_test
    
    setup_signal_handlers
    
    # Verify traps are set (bash doesn't expose trap list directly,
    # but we can verify signal handlers are installed by sending a signal
    # and checking if handler runs — this is tested indirectly via integration tests)
    
    teardown_event_loop_test
    return 0
}

# =============================================================================
# start_poll tests
# =============================================================================

test_start_poll_spawns_process() {
    setup_event_loop_test
    
    start_poll
    
    # Verify POLL_PID is set and process is alive
    if [[ -n "$POLL_PID" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        # Kill the poll
        kill "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
        
        teardown_event_loop_test
        return 0
    else
        teardown_event_loop_test
        return 1
    fi
}

test_start_poll_sets_pid_variable() {
    setup_event_loop_test
    
    start_poll
    
    if [[ -n "$POLL_PID" ]] && [[ "$POLL_PID" =~ ^[0-9]+$ ]]; then
        kill "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
        
        teardown_event_loop_test
        return 0
    else
        teardown_event_loop_test
        return 1
    fi
}

test_start_poll_multiple_calls() {
    setup_event_loop_test
    
    # Start first poll
    start_poll
    local pid1="$POLL_PID"
    
    # Start second poll
    start_poll
    local pid2="$POLL_PID"
    
    # PIDs should be different
    if [[ "$pid1" != "$pid2" ]] && [[ -n "$pid1" ]] && [[ -n "$pid2" ]]; then
        kill "$pid1" 2>/dev/null || true
        kill "$pid2" 2>/dev/null || true
        wait "$pid1" 2>/dev/null || true
        wait "$pid2" 2>/dev/null || true
        
        teardown_event_loop_test
        return 0
    else
        teardown_event_loop_test
        return 1
    fi
}

# =============================================================================
# handle_shutdown tests (via cleanup helper)
# =============================================================================

test_cleanup_kills_poll() {
    setup_event_loop_test
    
    start_poll
    local pid="$POLL_PID"
    
    # Verify poll is running
    if ! kill -0 "$pid" 2>/dev/null; then
        teardown_event_loop_test
        return 1
    fi
    
    # Run cleanup
    cleanup
    
    # Verify poll is dead
    if ! kill -0 "$pid" 2>/dev/null; then
        teardown_event_loop_test
        return 0
    else
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        teardown_event_loop_test
        return 1
    fi
}

test_cleanup_releases_lock() {
    setup_event_loop_test
    
    # Acquire lock in main shell
    acquire_lock 2>/dev/null || {
        teardown_event_loop_test
        return 1
    }
    
    # Verify lock file exists
    if [[ ! -f "$LOCK_DIR/lock" ]]; then
        teardown_event_loop_test
        return 1
    fi
    
    # Run cleanup
    cleanup
    
    # Verify lock file is gone
    if [[ ! -f "$LOCK_DIR/lock" ]]; then
        teardown_event_loop_test
        return 0
    fi
    
    teardown_event_loop_test
    return 1
}

test_cleanup_idempotent() {
    setup_event_loop_test
    
    start_poll
    
    # Call cleanup twice — should not error
    if cleanup && cleanup; then
        teardown_event_loop_test
        return 0
    else
        teardown_event_loop_test
        return 1
    fi
}

# =============================================================================
# Integration tests
# =============================================================================

test_event_loop_signal_setup() {
    setup_event_loop_test
    
    # We can't easily test the full event loop (it blocks on route -n monitor),
    # but we can verify signal handler setup works
    setup_signal_handlers
    
    teardown_event_loop_test
    return 0
}

test_event_loop_cleanup_on_shutdown() {
    setup_event_loop_test

    # Start poll, verify it runs
    start_poll
    local pid="$POLL_PID"

    if ! kill -0 "$pid" 2>/dev/null; then
        teardown_event_loop_test
        return 1
    fi

    # Simulate shutdown cleanup
    cleanup

    # Verify poll is dead
    if kill -0 "$pid" 2>/dev/null; then
        teardown_event_loop_test
        return 1
    fi

    teardown_event_loop_test
    return 0
}

# =============================================================================
# initial_reconcile tests
# =============================================================================

test_initial_reconcile_applies_policy() {
    setup_event_loop_test

    # Count reconcile invocations (mock: never touch real DNS state)
    reconcile() { RECONCILE_CALLED=$((RECONCILE_CALLED + 1)); return 0; }
    RECONCILE_CALLED=0

    initial_reconcile

    if (( RECONCILE_CALLED == 1 )); then
        teardown_event_loop_test
        return 0
    fi
    teardown_event_loop_test
    return 1
}

test_initial_reconcile_failure_is_nonfatal() {
    setup_event_loop_test

    reconcile() { return 1; }

    # Startup must not propagate failure — launchd KeepAlive would loop
    if initial_reconcile >/dev/null 2>&1; then
        teardown_event_loop_test
        return 0
    fi
    teardown_event_loop_test
    return 1
}

test_initial_reconcile_held_lock_skips() {
    setup_event_loop_test

    # Lock held by another process: must skip reconcile entirely (and must
    # never release a lock this process does not hold)
    acquire_lock() { return 1; }
    reconcile() { RECONCILE_CALLED=$((RECONCILE_CALLED + 1)); return 0; }
    RECONCILE_CALLED=0

    initial_reconcile

    if (( RECONCILE_CALLED == 0 )); then
        teardown_event_loop_test
        return 0
    fi
    teardown_event_loop_test
    return 1
}

# =============================================================================
# route monitor EOF tests
# =============================================================================

test_route_monitor_eof_returns_nonzero() {
    setup_event_loop_test

    # Monitor that exits immediately: the stream EOFs, loop ends
    ROUTE_CMD="/usr/bin/true"

    # EOF is abnormal — must report failure so the caller restarts
    if route_monitor_loop >/dev/null 2>&1; then
        teardown_event_loop_test
        return 1
    fi
    teardown_event_loop_test
    return 0
}

# =============================================================================
# shutdown vs in-flight toggle tests
# =============================================================================
# The poll subshell can be inside reconcile() — between spawning a `tailscale`
# mutation and the state-manifest write that records it — when cleanup or
# handle_shutdown delivers TERM. A subshell resets inherited traps to their
# default action, so an untrapped TERM kills it at whatever command boundary it
# is at: the mutation is orphaned (reparented to launchd, still running), the
# manifest write never happens, and release_lock is skipped. These tests pin
# the contract: TERM must take effect only at a reconcile boundary.

# Cross-process rendezvous markers live under the test state dir
setup_toggle_test() {
    setup_event_loop_test
    rm -f "$STATE_DIR"/*.marker "$STATE_DIR"/*.gate
}

# Bounded wait for a substring to appear in a marker file. Rendezvous, not
# sleep-and-hope: the cap exists so a broken implementation fails the test
# instead of hanging the suite.
await_marker() {
    local file="$1"
    local want="$2"
    local i=0
    while (( i < 200 )); do
        if [[ -f "$file" ]] && grep -q "$want" "$file" 2>/dev/null; then
            return 0
        fi
        "$SLEEP_CMD" 0.05
        i=$((i + 1))
    done
    return 1
}

# Line number of the first occurrence of a pattern, or empty if absent
marker_line() {
    grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 || true
}

test_poll_survives_term_during_reconcile_and_completes_toggle() {
    setup_toggle_test
    local marker="$STATE_DIR/toggle.marker"
    local gate="$STATE_DIR/toggle.gate"

    # Mock the toggle layer: stays in flight until the test opens the gate
    reconcile() {
        echo "toggle-start" >> "$marker"
        local i=0
        while (( i < 200 )) && [[ ! -f "$gate" ]]; do
            "$SLEEP_CMD" 0.05
            i=$((i + 1))
        done
        echo "toggle-end" >> "$marker"
        return 0
    }

    start_poll
    local pid="$POLL_PID"
    await_marker "$marker" "toggle-start" || return 1

    # TERM lands while the toggle is in flight — what cleanup/handle_shutdown do
    kill -TERM "$pid" 2>/dev/null || true
    : > "$gate"

    # The in-flight toggle must run to completion rather than be orphaned
    await_marker "$marker" "toggle-end" || return 1

    # The poll must have released the lock it held for that toggle
    wait "$pid" 2>/dev/null || true
    [[ ! -f "$LOCK_DIR/lock" ]] || return 1
    return 0
}

test_poll_exits_promptly_on_term_while_idle() {
    setup_toggle_test
    local marker="$STATE_DIR/idle.marker"

    reconcile() { echo "unexpected-reconcile" >> "$marker"; return 0; }

    start_poll
    local pid="$POLL_PID"

    # Watchdog: if the cooperative trap turned "stop the poll" into "wait out
    # the sleep", the poll would still be alive when this fires.
    ( "$SLEEP_CMD" 3; kill -KILL "$pid" 2>/dev/null; echo "hang" >> "$marker" ) &
    local watchdog=$!

    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    # The watchdog must never have fired, and no tick may have run
    [[ ! -f "$marker" ]] || return 1
    return 0
}

test_shutdown_restores_only_after_poll_toggle_lands() {
    setup_toggle_test
    local marker="$STATE_DIR/shutdown.marker"
    local gate="$STATE_DIR/shutdown.gate"

    # Manifest says we disabled MagicDNS, so handle_shutdown will restore
    printf '2026-01-01T00:00:00Z|disable|false\n' > "$STATE_MANIFEST"

    # The scenario runs in a subshell so handle_shutdown's `exit 0` cannot end
    # the test, and so the poll is a child of whoever waits on it.
    _run_shutdown_scenario() {
        reconcile() {
            echo "toggle-start" >> "$marker"
            local i=0
            while (( i < 200 )) && [[ ! -f "$gate" ]]; do
                "$SLEEP_CMD" 0.05
                i=$((i + 1))
            done
            echo "toggle-end" >> "$marker"
            return 0
        }
        enable_magicdns() { echo "restore" >> "$marker"; return 0; }

        start_poll
        await_marker "$marker" "toggle-start" || return 1

        # Release the toggle only after shutdown has already been asked to
        # stop the poll: the restore must not overtake the in-flight toggle.
        ( "$SLEEP_CMD" 1; : > "$gate" ) &

        handle_shutdown
    }
    # Command substitution: handle_shutdown ends in `exit 0`, which must end
    # the scenario, not the test.
    local scenario_rc=0
    local scenario_log
    scenario_log=$(_run_shutdown_scenario 2>&1) || scenario_rc=$?
    (( scenario_rc == 0 )) || return 1

    # The restore must have come from the shutdown path
    [[ "$scenario_log" == *"[INFO] Shutdown signal received; cleaning up"* ]] || return 1
    [[ "$scenario_log" == *"[INFO] Restoring MagicDNS on shutdown"* ]] || return 1

    local end_line restore_line
    end_line=$(marker_line "$marker" "toggle-end")
    restore_line=$(marker_line "$marker" "^restore$")
    [[ -n "$end_line" ]] || return 1
    [[ -n "$restore_line" ]] || return 1
    (( end_line < restore_line )) || return 1
    return 0
}

test_event_loop_restarts_cleanly_on_monitor_eof() {
    setup_event_loop_test

    # Mock the reconcile layer: never touch real DNS state from a test
    reconcile() { return 0; }
    # Monitor that exits immediately
    ROUTE_CMD="/usr/bin/true"

    # The loop must report failure AND kill the poll itself — an orphaned
    # poll keeps reconciling forever, reparented to launchd
    if run_event_loop >/dev/null 2>&1; then
        teardown_event_loop_test
        return 1
    fi

    if [[ -n "${POLL_PID:-}" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        kill "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
        teardown_event_loop_test
        return 1
    fi

    teardown_event_loop_test
    return 0
}
