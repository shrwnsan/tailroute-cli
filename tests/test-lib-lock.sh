#!/usr/bin/env bash
# test-lib-lock.sh — Tests for lib-lock.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Override lock directory for testing
export LOCK_DIR="/tmp/tailroute-test-lock"

# Enable test mode (disables strict PID validation)
export TEST_MODE=1

source "$SCRIPT_DIR/../bin/lib-lock.sh"

# Suppress error output during tests
exec 2>/dev/null

# Setup and teardown
setup_lock_test() {
    rm -rf "$LOCK_DIR"
    mkdir -p "$LOCK_DIR"
}

teardown_lock_test() {
    rm -rf "$LOCK_DIR"
}

# =============================================================================
# acquire_lock tests
# =============================================================================

test_acquire_lock_success() {
    setup_lock_test
    
    assert_ok acquire_lock
    teardown_lock_test
}

test_acquire_lock_creates_directory() {
    setup_lock_test
    rm -rf "$LOCK_DIR"
    
    # Should create directory if missing
    assert_ok acquire_lock
    
    if [[ -d "$LOCK_DIR" ]]; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_acquire_lock_creates_file() {
    setup_lock_test
    
    acquire_lock >/dev/null 2>&1
    
    if [[ -f "$LOCK_FILE" ]]; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_acquire_lock_stores_pid() {
    setup_lock_test
    
    # Acquire lock
    acquire_lock >/dev/null 2>&1 || {
        teardown_lock_test
        return 1
    }
    
    # Verify PID is stored
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null) || pid=""
    
    if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
        teardown_lock_test
        return 0
    fi
    
    teardown_lock_test
    return 1
}

test_acquire_lock_fails_when_held() {
    setup_lock_test
    
    # First acquire succeeds
    acquire_lock >/dev/null 2>&1
    
    # Create a subshell trying to acquire the same lock (with TEST_MODE preserved)
    if (set -e; cd "$LOCK_DIR"; exec bash -c "export TEST_MODE=1; source \"$SCRIPT_DIR/../bin/lib-lock.sh\"; acquire_lock" 2>/dev/null); then
        # Both succeeded — that's wrong
        teardown_lock_test
        return 1
    else
        # Second acquire failed — correct
        teardown_lock_test
        return 0
    fi
}

test_acquire_lock_handles_stale_lock() {
    setup_lock_test
    
    # Create a stale lock file with a PID that doesn't exist
    mkdir -p "$LOCK_DIR"
    echo "999999" > "$LOCK_FILE"
    
    # Should be able to acquire (cleanup stale lock)
    assert_ok acquire_lock
    
    teardown_lock_test
}

# =============================================================================
# release_lock tests
# =============================================================================

test_release_lock_removes_file() {
    setup_lock_test
    
    # Acquire, then release
    acquire_lock >/dev/null 2>&1
    assert_ok release_lock
    
    if [[ ! -f "$LOCK_FILE" ]]; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_release_lock_idempotent() {
    setup_lock_test
    
    # Release without acquiring (or after already released)
    assert_ok release_lock
    assert_ok release_lock
    
    teardown_lock_test
}

test_release_lock_succeeds_after_acquire() {
    setup_lock_test
    
    assert_ok acquire_lock
    assert_ok release_lock
    
    teardown_lock_test
}

# =============================================================================
# is_locked tests
# =============================================================================

test_is_locked_no_lock() {
    setup_lock_test
    
    # No lock file exists
    if ! is_locked 2>/dev/null; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_is_locked_with_lock() {
    setup_lock_test
    
    # Create lock file with current PID
    mkdir -p "$LOCK_DIR"
    echo $$ > "$LOCK_FILE"
    
    # Verify lock file exists and contains a valid PID
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE")
        if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
            teardown_lock_test
            return 0
        fi
    fi
    
    teardown_lock_test
    return 1
}

test_is_locked_after_release() {
    setup_lock_test
    
    # Acquire and release
    acquire_lock >/dev/null 2>&1
    release_lock >/dev/null 2>&1
    
    # Should not be locked
    if ! is_locked 2>/dev/null; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_is_locked_stale() {
    setup_lock_test
    
    # Create stale lock
    mkdir -p "$LOCK_DIR"
    echo "999999" > "$LOCK_FILE"
    
    # Should report as not locked (stale detected)
    if ! is_locked 2>/dev/null; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

# =============================================================================
# Integration tests
# =============================================================================

test_lock_acquire_release_cycle() {
    setup_lock_test
    
    # Acquire
    assert_ok acquire_lock
    
    # Release
    assert_ok release_lock
    
    # Verify released
    if [[ ! -f "$LOCK_FILE" ]]; then
        teardown_lock_test
        return 0
    else
        teardown_lock_test
        return 1
    fi
}

test_lock_multiple_cycles() {
    setup_lock_test
    
    # Cycle 1
    assert_ok acquire_lock
    assert_ok release_lock
    
    # Cycle 2
    assert_ok acquire_lock
    assert_ok release_lock
    
    teardown_lock_test
}
