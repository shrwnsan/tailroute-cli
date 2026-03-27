#!/usr/bin/env bash
# lib-lock.sh — Concurrency lock management for tailroute
#
# Prevents concurrent reconcile() runs that could race on MagicDNS state.
# Uses a lock file in /var/run/tailroute.lock with PID tracking and validation.

set -euo pipefail

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"

# Paths to system commands (absolute for security)
MKDIR_CMD="/bin/mkdir"
RM_CMD="/bin/rm"
KILL_CMD="/bin/kill"
PS_CMD="/bin/ps"

# -----------------------------------------------------------------------------
# _is_tailroute_pid — Verify PID belongs to tailroute process
# -----------------------------------------------------------------------------
# Checks if a given PID is actually a tailroute process to prevent lock hijacking
# via PID reuse.
#
# Args:
#   $1 - PID to check
#
# Returns:
#   0 - PID is a tailroute process (or TEST_MODE is enabled)
#   1 - PID is not tailroute or doesn't exist
#
# Environment:
#   TEST_MODE - If set to "1", skip PID validation (for testing)
# -----------------------------------------------------------------------------
_is_tailroute_pid() {
    local pid="$1"
    
    if [[ -z "$pid" ]] || [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # In test mode, only check if PID exists (backward compatibility)
    if [[ "${TEST_MODE:-0}" == "1" ]]; then
        "$PS_CMD" -p "$pid" >/dev/null 2>&1
        return $?
    fi
    
    # Check if process exists and get its command
    local cmd
    cmd=$("$PS_CMD" -p "$pid" -o command= 2>/dev/null) || return 1
    
    # Check if command contains "tailroute" (works for both direct and sh -c invocations)
    if [[ "$cmd" =~ tailroute ]]; then
        return 0
    else
        return 1
    fi
}

# Lock location
LOCK_DIR="${LOCK_DIR:-/var/run/tailroute}"
LOCK_FILE="$LOCK_DIR/lock"

# Lock acquisition timeout (seconds) - how long to wait before giving up
LOCK_TIMEOUT="${LOCK_TIMEOUT:-2}"

# =============================================================================
# acquire_lock — Acquire exclusive lock for reconcile
# =============================================================================
# Creates the lock directory and file atomically, storing this process's PID.
# Handles stale locks: if the PID inside doesn't exist, removes it and retries.
# Validates lock directory ownership for security.
#
# Returns:
#   0 - Lock acquired successfully
#   1 - Failed to acquire lock (held by another process)
#
# Side effects:
#   - Creates $LOCK_DIR if it doesn't exist (atomic via mkdir)
#   - Validates and corrects directory ownership/permissions
#   - Writes this process's PID to $LOCK_FILE
#   - May log warnings for stale lock cleanup
# =============================================================================
acquire_lock() {
     # Create lock directory if needed (atomic, race-safe)
     if ! "$MKDIR_CMD" -p "$LOCK_DIR" 2>/dev/null; then
         log_error "Failed to create lock directory: $LOCK_DIR"
         return 1
     fi
     
     # Validate and correct lock directory ownership/permissions (security hardening)
     # Only do this if running as root (UID 0) to avoid errors in test mode
     if [[ "$(id -u)" -eq 0 ]] && [[ "${TEST_MODE:-0}" != "1" ]]; then
         local dir_owner
         dir_owner=$(/usr/bin/stat -f%Su "$LOCK_DIR" 2>/dev/null) || dir_owner=""
         
         if [[ "$dir_owner" != "root" ]]; then
             log_debug "Lock directory ownership incorrect ($dir_owner); correcting to root:wheel"
             chown root:wheel "$LOCK_DIR" 2>/dev/null || {
                 log_warn "Failed to correct lock directory ownership"
             }
         fi
         
         # Ensure correct permissions (0755 for directory)
         chmod 0755 "$LOCK_DIR" 2>/dev/null || {
             log_warn "Failed to set lock directory permissions"
         }
     fi
     
     # Atomically create lock file with our PID using noclobber
     # This is the simplest, most robust approach:
     # - (set -C; ...) ensures exclusive creation
     # - If it succeeds, we have the lock
     # - If it fails, another process owns the lock
     if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
         # Successfully created — we have the lock
         log_debug "Lock acquired by PID $$"
         return 0
     fi
     
     # Lock file exists — another process holds it
     # Check if that PID is still alive (handle stale locks gracefully)
     local lock_pid
     lock_pid=$(cat "$LOCK_FILE" 2>/dev/null) || lock_pid=""
     
     # Validate lock_pid is a number
     if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
         # Check if the PID is still alive AND is a tailroute process
         if _is_tailroute_pid "$lock_pid"; then
             # Process is still running and is tailroute — lock is legitimately held
             log_debug "Lock held by tailroute PID $lock_pid; cannot acquire"
             return 1
         else
             # Stale lock or PID reused by another process — clean up and retry once
             if "$PS_CMD" -p "$lock_pid" >/dev/null 2>&1; then
                 log_debug "Lock PID $lock_pid exists but is not tailroute (reused PID); removing stale lock"
             else
                 log_debug "Lock PID $lock_pid no longer exists; removing stale lock"
             fi
             "$RM_CMD" -f "$LOCK_FILE"
             
             # One more attempt after cleanup
             if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
                 log_debug "Lock acquired by PID $$ (after cleanup)"
                 return 0
             else
                 log_debug "Failed to acquire lock after stale cleanup"
                 return 1
             fi
         fi
     else
         # Lock file exists but is unreadable or invalid
         # This is rare. Attempt cleanup (likely permission issue or corruption)
         log_debug "Lock file exists but is unreadable; attempting cleanup"
         "$RM_CMD" -f "$LOCK_FILE"
         
         # One attempt after cleanup
         if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
             log_debug "Lock acquired by PID $$ (after cleanup)"
             return 0
         else
             log_debug "Failed to acquire lock after cleanup"
             return 1
         fi
     fi
}

# =============================================================================
# release_lock — Release the lock
# =============================================================================
# Removes the lock file. Should be called in signal handlers and on clean exit.
# Idempotent: succeeds even if lock doesn't exist.
#
# Returns:
#   0 - Lock released (or didn't exist)
#   1 - Failed to remove lock file (rare — permission error)
#
# Side effects:
#   - Deletes $LOCK_FILE
# =============================================================================
release_lock() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        # Already released or never created
        return 0
    fi
    
    if "$RM_CMD" -f "$LOCK_FILE" 2>/dev/null; then
        return 0
    else
        log_error "Failed to release lock: $LOCK_FILE"
        return 1
    fi
}

# =============================================================================
# is_locked — Check if lock is currently held
# =============================================================================
# Non-blocking check to see if another process holds the lock.
# Useful for diagnostics or deciding to skip a reconcile if one is in progress.
#
# Returns:
#   0 - Lock is held by another process
#   1 - Lock is not held (available)
# =============================================================================
is_locked() {
     if [[ ! -f "$LOCK_FILE" ]]; then
         return 1
     fi
     
     # Check if the PID in the lock is still alive and is tailroute
     local lock_pid
     lock_pid=$(cat "$LOCK_FILE" 2>/dev/null) || lock_pid=""
    
    if [[ -z "$lock_pid" ]]; then
        return 1
    fi
    
    if _is_tailroute_pid "$lock_pid"; then
        return 0  # Lock is held by tailroute
    else
        return 1  # Lock is stale or reused PID
    fi
}
