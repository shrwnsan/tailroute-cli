#!/usr/bin/env bash
# lib-log.sh — Structured logging functions for tailroute
#
# All output goes to stdout (launchd captures to log file).
# Format: [YYYY-MM-DDTHH:MM:SSZ] [LEVEL] message

# Guard: prevent re-sourcing to avoid readonly variable conflicts
if [[ "${_LOG_SOURCED:-0}" == "1" ]]; then
    return 0
fi
readonly _LOG_SOURCED=1

set -euo pipefail

# Absolute path to date (security hardening)
readonly _DATE_CMD="/bin/date"

# -----------------------------------------------------------------------------
# _log_timestamp — Get current ISO 8601 timestamp
# -----------------------------------------------------------------------------
_log_timestamp() {
    "$_DATE_CMD" -u +"%Y-%m-%dT%H:%M:%SZ"
}

# -----------------------------------------------------------------------------
# log_info — Log informational message
# -----------------------------------------------------------------------------
# Args:
#   $@ - message
# -----------------------------------------------------------------------------
log_info() {
    echo "[$(_log_timestamp)] [INFO] $*"
}

# -----------------------------------------------------------------------------
# log_warn — Log warning message
# -----------------------------------------------------------------------------
# Args:
#   $@ - message
# -----------------------------------------------------------------------------
log_warn() {
    echo "[$(_log_timestamp)] [WARN] $*"
}

# -----------------------------------------------------------------------------
# log_error — Log error message
# -----------------------------------------------------------------------------
# Args:
#   $@ - message
# -----------------------------------------------------------------------------
log_error() {
    echo "[$(_log_timestamp)] [ERROR] $*"
}

# -----------------------------------------------------------------------------
# log_debug — Log debug message (only if DEBUG is set)
# -----------------------------------------------------------------------------
# Args:
#   $@ - message
# Environment:
#   DEBUG - if set to "1" or "true", debug messages are printed
# -----------------------------------------------------------------------------
log_debug() {
    if [[ "${DEBUG:-}" == "1" || "${DEBUG:-}" == "true" ]]; then
        echo "[$(_log_timestamp)] [DEBUG] $*"
    fi
}

# -----------------------------------------------------------------------------
# log_dns_change — Log DNS state change for audit
# -----------------------------------------------------------------------------
# Args:
#   $1 - action: "enable" or "disable"
#   $2 - reason: "vpn_active", "vpn_inactive", "tailscale_stopped", etc.
# Format:
#   [timestamp] [DNS] action=enable|disable reason=...
# -----------------------------------------------------------------------------
log_dns_change() {
    local action="$1"
    local reason="$2"

    # Validate action
    if [[ "$action" != "enable" && "$action" != "disable" ]]; then
        log_error "Invalid DNS action: $action"
        return 1
    fi

    echo "[$(_log_timestamp)] [DNS] action=$action reason=$reason"
}
