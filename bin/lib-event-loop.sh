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
# initial_reconcile — Apply policy once at daemon startup
# =============================================================================
# Closes the window where a freshly started daemon manages nothing (state is
# per-Tailscale-session and resets on reconnect). Failure is non-fatal: the
# event loop retries on the next route event, and startup must not
# crash-loop via launchd KeepAlive. Guarded lock shape — a held lock must
# never cause this process to release someone else's lock.
#
# Returns:
#   0 - Always
# =============================================================================
initial_reconcile() {
    if acquire_lock; then
        if ! reconcile; then
            log_warn "Initial reconcile failed (will retry)"
        fi
        release_lock 2>/dev/null || true
    else
        log_debug "Lock held at startup; skipping initial reconcile"
    fi
    return 0
}

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
#   1 - Setup failed, or the route monitor stream died (poll killed; the
#       caller should exit non-zero so launchd restarts the daemon).
#       Signal termination exits from inside the handler and does not
#       return through here.
#
# Side effects:
#   - Sets up signal traps (SIGTERM, SIGINT, SIGHUP)
#   - Applies reconcile() once at startup
#   - Starts background poll process (killed on every exit path via EXIT trap)
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

    # Apply policy once: daemon start should not wait for the first route
    # event or poll tick (MagicDNS state is per-Tailscale-session). Must run
    # BEFORE start_poll so the forked poll inherits applied state and its
    # first tick is a time-gated re-assert, not a duplicate apply.
    initial_reconcile

    # Start background safety-net poll
    start_poll || {
        log_error "Failed to start background poll"
        cleanup
        return 1
    }

    # Kill the poll on ANY exit path: a non-signal exit (route monitor
    # death, a set -e failure) would otherwise orphan the poll subshell,
    # which keeps reconciling forever, reparented to launchd. No-op on the
    # signal path — handle_shutdown already cleaned up (idempotent).
    trap cleanup EXIT

    # Monitor routing table. Normal termination is a signal trap exiting
    # the process, so reaching the end of route_monitor_loop means the
    # monitor stream died — kill the poll and let launchd restart us.
    route_monitor_loop || {
        log_warn "Route monitor exited; daemon will restart"
        cleanup
        return 1
    }

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

    # The while loop only exits on EOF from the monitor stream — normal
    # termination is a signal trap exiting the process. Return non-zero so
    # the caller kills the poll and launchd restarts the daemon.
    return 1
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

    # Spawn background poll process.
    #
    # TERM/INT are trapped INSIDE the subshell on purpose: a subshell resets
    # inherited traps to their default action, so an untrapped TERM kills the
    # poll at whatever command boundary it happens to be at — including between
    # the `tailscale` mutation reconcile() spawns and the state-manifest write
    # that records it. That orphans the still-running mutation to race
    # shutdown's own restore, and skips release_lock. The handler only raises a
    # flag: bash delivers a trapped signal at the next command boundary, so an
    # in-flight reconcile always runs to completion before the poll exits.
    #
    # `sleep` runs in the background under `wait` so the flag is acted on
    # immediately instead of up to POLL_SECONDS later.
     (
         _POLL_STOP=0
         _POLL_SLEEP_PID=""
         _poll_halt() {
             _POLL_STOP=1
             if [[ -n "$_POLL_SLEEP_PID" ]]; then
                 "$KILL_CMD" "$_POLL_SLEEP_PID" 2>/dev/null || true
             fi
         }
         trap _poll_halt TERM INT

         while (( _POLL_STOP == 0 )); do
             "$SLEEP_CMD" "$POLL_SECONDS" &
             _POLL_SLEEP_PID=$!
             wait "$_POLL_SLEEP_PID" 2>/dev/null || true
             _POLL_SLEEP_PID=""
             (( _POLL_STOP == 1 )) && break

             if acquire_lock; then
                 if ! reconcile; then
                     log_warn "Reconcile failed in poll (continuing)"
                 fi
                 release_lock 2>/dev/null || true
             fi
         done

         exit 0
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
# stop_poll — Stop the background poll and wait for it to finish
# =============================================================================
# Sends TERM to the poll subshell and reaps it. Because the poll traps TERM
# (see start_poll), this returns only once any reconcile it was running has
# completed and released its lock — never while a `tailscale` mutation is
# still in flight. Shared by the signal path and the EXIT path so both
# quiesce the poll identically.
#
# Returns:
#   0 - Always
# =============================================================================
stop_poll() {
    if [[ -n "$POLL_PID" ]] && kill -0 "$POLL_PID" 2>/dev/null; then
        log_debug "Killing poll process: $POLL_PID"
        "$KILL_CMD" "$POLL_PID" 2>/dev/null || true
        wait "$POLL_PID" 2>/dev/null || true
    fi

    return 0
}

# =============================================================================
# handle_shutdown — SIGTERM/SIGINT handler
# =============================================================================
# Stops the poll, restores MagicDNS if we disabled it, releases lock, exits cleanly.
#
# Side effects:
#   - Stops the background poll process, waiting out any in-flight reconcile
#   - Reads state manifest to determine if we disabled MagicDNS
#   - Calls enable_magicdns() if needed
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

    # Stop the poll BEFORE reading the manifest: the poll may be mid-reconcile,
    # and stopping it first means the manifest we read is final and no toggle
    # can land after our restore and undo it.
    stop_poll

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
        if ! reconcile force 2>/dev/null; then
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
    stop_poll

    release_lock 2>/dev/null || true

    return 0
}
