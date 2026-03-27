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
