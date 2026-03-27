#!/usr/bin/env bash
# lib-state.sh — State manifest functions for tailroute
#
# Manages persistent state tracking for MagicDNS toggles.
# State is stored in `/var/db/tailroute/state.manifest`.

set -euo pipefail

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"

# Paths to system commands (absolute for security)
MKDIR_CMD="/bin/mkdir"

# State manifest location (can be overridden via STATE_DIR env var for testing)
STATE_DIR="${STATE_DIR:-/var/db/tailroute}"
STATE_MANIFEST="${STATE_MANIFEST:-$STATE_DIR/state.manifest}"

# -----------------------------------------------------------------------------
# state_read — Read current state from manifest
# -----------------------------------------------------------------------------
# Reads the state manifest file and returns the last recorded state.
# Handles missing or corrupted manifest gracefully.
#
# Returns:
#   0 - State read successfully (contents printed to stdout)
#   1 - Manifest missing or unreadable (empty string printed)
#
# Output format:
#   timestamp|action|magicdns_enabled
#   Example: 2026-02-16T10:30:00Z|disable|false
#
# Note: Returns empty if manifest doesn't exist (first run).
# -----------------------------------------------------------------------------
state_read() {
    if [[ ! -f "$STATE_MANIFEST" ]]; then
        echo ""
        return 1
    fi
    
    if [[ ! -r "$STATE_MANIFEST" ]]; then
        log_warn "Cannot read state manifest: $STATE_MANIFEST"
        echo ""
        return 1
    fi
    
    # Read the last line (most recent state)
    local state
    state=$(tail -n 1 "$STATE_MANIFEST" 2>/dev/null) || {
        echo ""
        return 1
    }
    
    echo "$state"
    return 0
}

# -----------------------------------------------------------------------------
# state_write — Write current state to manifest
# -----------------------------------------------------------------------------
# Records a state change to the manifest file.
# Creates the state directory if it doesn't exist (requires root).
# Each write appends a new line with timestamp|action|magicdns_enabled.
#
# Args:
#   $1 - action: "enable" or "disable"
#   $2 - magicdns_enabled: "true" or "false"
#
# Returns:
#   0 - State written successfully
#   1 - Failed to write state
#
# Side effects:
#   - Creates $STATE_DIR if it doesn't exist (0700 permissions)
#   - Appends to $STATE_MANIFEST (world-readable 0644)
# -----------------------------------------------------------------------------
state_write() {
    local action="$1"
    local magicdns_enabled="$2"
    
    # Validate action
    if [[ ! "$action" =~ ^(enable|disable)$ ]]; then
        log_error "Invalid action for state_write: $action"
        return 1
    fi
    
    # Validate magicdns_enabled
    if [[ ! "$magicdns_enabled" =~ ^(true|false)$ ]]; then
        log_error "Invalid magicdns_enabled for state_write: $magicdns_enabled"
        return 1
    fi
    
    # Create state directory if needed (requires root)
    if [[ ! -d "$STATE_DIR" ]]; then
        if ! "$MKDIR_CMD" -p "$STATE_DIR" 2>/dev/null; then
            log_error "Failed to create state directory: $STATE_DIR"
            return 1
        fi
        # Set permissions: accessible only by root (0700)
        chmod 0700 "$STATE_DIR" || {
            log_error "Failed to set permissions on $STATE_DIR"
            return 1
        }
    fi
    
    # Generate timestamp (use _DATE_CMD from lib-log.sh)
    local timestamp
    timestamp=$("$_DATE_CMD" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Append to manifest
    echo "$timestamp|$action|$magicdns_enabled" >> "$STATE_MANIFEST" || {
        log_error "Failed to write state to manifest: $STATE_MANIFEST"
        return 1
    }
    
    # Ensure manifest is world-readable for `tailroute status` command
    chmod 0644 "$STATE_MANIFEST" || {
        log_error "Failed to set permissions on $STATE_MANIFEST"
        return 1
    }
    
    return 0
}

# -----------------------------------------------------------------------------
# state_clear — Clear state manifest
# -----------------------------------------------------------------------------
# Removes the state manifest file completely.
# Used during uninstall to reset the daemon's tracking state.
#
# Returns:
#   0 - Manifest cleared successfully (or already missing)
#   1 - Failed to clear manifest
# 
# Side effects:
#   - Deletes $STATE_MANIFEST file
# -----------------------------------------------------------------------------
state_clear() {
    if [[ ! -f "$STATE_MANIFEST" ]]; then
        # Already cleared
        return 0
    fi
    
    if ! rm -f "$STATE_MANIFEST" 2>/dev/null; then
        log_error "Failed to clear state manifest: $STATE_MANIFEST"
        return 1
    fi
    
    return 0
}
