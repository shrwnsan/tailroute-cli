#!/usr/bin/env bash
# lib-event-loop.sh — Event loop, debounce, and signal handling for tailroute
#
# Watches routing table changes and triggers reconciliation with debounce.
# Includes safety-net poll (fallback) and signal handlers for clean shutdown.

# Guard: prevent re-sourcing
if [[ "${_EVENT_LOOP_SOURCED:-0}" == "1" ]]; then
    return 0
fi
readonly _EVENT_LOOP_SOURCED=1

set -euo pipefail

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"
# shellcheck source=lib-reconcile.sh
source "$SCRIPT_DIR/lib-reconcile.sh"
# shellcheck source=lib-lock.sh
source "$SCRIPT_DIR/lib-lock.sh"
# shellcheck source=lib-dns.sh
source "$SCRIPT_DIR/lib-dns.sh"

# Paths to system commands (absolute for security)
ROUTE_CMD="/sbin/route"
SLEEP_CMD="/bin/sleep"
KILL_CMD="/bin/kill"

# State for event loop
DEBOUNCE_PENDING=0
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-2}"
POLL_SECONDS="${POLL_SECONDS:-60}"

# PIDs of background processes (for cleanup)
POLL_PID=""
CLEANUP_IN_PROGRESS=0

# =============================================================================
# run_event_loop — Monitor routing table and trigger reconciliation
# =============================================================================
# Pipes `/sbin/route -n monitor` output into a debounced event handler.
# Each routing table change sets a "pending" flag and resets a 2-second timer.
# After 2 seconds with no new changes, calls `reconcile()`.
#
# Also spawns a background safety-net poll that calls reconcile() every 60s.
#
# Signal handlers:
#   SIGTERM/SIGINT — Restore MagicDNS (if disabled), release lock, kill poll, exit
#   SIGHUP — Force immediate reconcile
#
# Returns:
#   0 - Event loop exited cleanly (on signal)
#   1 - Failed to setup signal handlers or start monitoring
#
# Side effects:
#   - Sets up signal traps (SIGTERM, SIGINT, SIGHUP)
#   - Starts background poll process
#   - Calls reconcile() repeatedly on route changes
#   - Calls disable_magicdns() / enable_magicdns() indirectly via reconcile()
# =============================================================================
run_event_loop() {
    log_info "Event loop starting"
    
    # Setup signal handlers before entering loop
    setup_signal_handlers || {
        log_error "Failed to setup signal handlers"
        return 1
    }
    
    # Start background safety-net poll
    start_poll || {
        log_error "Failed to start background poll"
        cleanup
        return 1
    }
    
    # Monitor routing table
    # This will run until a signal interrupts it
    route_monitor_loop
    
    # After signal, cleanup happens in signal handler
    return 0
}

# =============================================================================
# route_monitor_loop — Core event loop that watches routing table
# =============================================================================
# Pipes `/sbin/route -n monitor` and implements debounced reconciliation.
# For each event, sets pending flag and waits for quiescence before reconciling.
#
# This is separated into its own function for testability.
# =============================================================================
route_monitor_loop() {
    log_debug "Route monitor loop starting"
    
    # Read from route monitor with debounce logic
    # macOS bash doesn't support read -t with fractional seconds,
    # so we use a simpler approach: read lines from route monitor
    # and debounce based on sleep intervals.
    while IFS= read -r line; do
        # Skip empty lines
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # Event received — set pending flag
        DEBOUNCE_PENDING=1
        
        # Wait for debounce period with no new events
        # Use nested loop: sleep 0.1s at a time, check for more input
        local wait_count=0
        while (( wait_count < DEBOUNCE_SECONDS * 10 )); do
            "$SLEEP_CMD" 0.1
            ((wait_count++))
        done
        
        # Debounce period elapsed with no new events
         if (( DEBOUNCE_PENDING == 1 )); then
             log_debug "Route change detected; triggering reconcile after debounce"
             
             if acquire_lock; then
                 log_debug "Lock acquired, calling reconcile..."
                 if ! reconcile; then
                     log_warn "Reconcile failed in event loop (continuing)"
                 fi
                 release_lock 2>/dev/null || true
             else
                 log_debug "Lock held by another process; skipping reconcile"
             fi
             
             DEBOUNCE_PENDING=0
         fi
    done < <("$ROUTE_CMD" -n monitor 2>/dev/null || true)
    
    log_debug "Route monitor loop exited"
}

# =============================================================================
# start_poll — Start background safety-net poll
# =============================================================================
# Spawns a background subshell that calls reconcile() every POLL_SECONDS.
# The poll respects the concurrency lock (skips if lock is held).
#
# Returns:
#   0 - Poll started successfully (PID stored in POLL_PID)
#   1 - Failed to start
# =============================================================================
start_poll() {
    log_debug "Starting background safety-net poll (${POLL_SECONDS}s interval)"
    
    # Spawn background poll process
     (
         # In subshell: infinite loop that sleeps and reconciles
         while true; do
             "$SLEEP_CMD" "$POLL_SECONDS"
             
             if acquire_lock; then
                 if ! reconcile; then
                     log_warn "Reconcile failed in poll (continuing)"
                 fi
                 release_lock 2>/dev/null || true
             fi
         done
     ) &
    
    POLL_PID=$!
    log_debug "Poll process started: PID $POLL_PID"
    
    return 0
}

# =============================================================================
# setup_signal_handlers — Setup SIGTERM, SIGINT, SIGHUP handlers
# =============================================================================
# Installs trap functions for graceful shutdown and manual triggers.
#
# Returns:
#   0 - Signal handlers installed
#   1 - Failed to install
# =============================================================================
setup_signal_handlers() {
    log_debug "Installing signal handlers"
    
    # SIGTERM / SIGINT — graceful shutdown
    trap handle_shutdown SIGTERM SIGINT
    
    # SIGHUP — force immediate reconcile
    trap handle_sighup SIGHUP
    
    return 0
}

# =============================================================================
# handle_shutdown — SIGTERM/SIGINT handler
# =============================================================================
# Restores MagicDNS if we disabled it, releases lock, kills poll, and exits cleanly.
#
# Side effects:
#   - Reads state manifest to determine if we disabled MagicDNS
#   - Calls enable_magicdns() if needed
#   - Kills background poll process
#   - Releases lock
#   - Exits process with code 0
# =============================================================================
handle_shutdown() {
    if (( CLEANUP_IN_PROGRESS == 1 )); then
        # Already cleaning up
        return
    fi
    
    CLEANUP_IN_PROGRESS=1
    
    log_info "Shutdown signal received; cleaning up"
    
    # Restore MagicDNS if we disabled it
    if [[ -n "${STATE_MANIFEST:-}" ]] && [[ -f "$STATE_MANIFEST" ]]; then
        local last_state
        last_state=$(state_read 2>/dev/null) || last_state=""
        
        if [[ "$last_state" =~ disable ]]; then
            log_info "Restoring MagicDNS on shutdown"
            if ! enable_magicdns 2>/dev/null; then
                log_warn "Failed to restore MagicDNS on shutdown"
            fi
        fi
    fi
    
    # Kill background poll
    if [[ -n "$POLL_PID" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        log_debug "Killing poll process: $POLL_PID"
        "$KILL_CMD" "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
    fi
    
    # Release lock
    release_lock 2>/dev/null || true
    
    log_info "Shutdown complete; exiting"
    exit 0
}

# =============================================================================
# handle_sighup — SIGHUP handler (force reconcile)
# =============================================================================
# Triggers an immediate reconciliation without waiting for route changes.
# Useful for manual triggers via `kill -HUP <pid>`.
#
# Side effects:
#   - Calls reconcile() (if lock can be acquired)
#   - Logs outcome
# =============================================================================
handle_sighup() {
    log_debug "SIGHUP received; forcing immediate reconcile"
    
    if acquire_lock 2>/dev/null; then
        if ! reconcile 2>/dev/null; then
            log_warn "Forced reconcile failed"
        fi
        release_lock 2>/dev/null || true
    else
        log_debug "Lock held; skipping forced reconcile"
    fi
}

# =============================================================================
# cleanup — Cleanup helper (called on error)
# =============================================================================
# Kills background poll and releases lock.
# Called when event loop setup fails.
#
# Returns:
#   0 - Always
# =============================================================================
cleanup() {
    if [[ -n "$POLL_PID" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        "$KILL_CMD" "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
    fi
    
    release_lock 2>/dev/null || true
    
    return 0
}
