#!/usr/bin/env bash
# lib-dns.sh — MagicDNS management functions for tailroute
#
# Functions to query and toggle Tailscale MagicDNS state.
# All external commands use absolute paths for security.

set -euo pipefail

# Source logging and state libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate SCRIPT_DIR is in expected location (security hardening)
if [[ ! "$SCRIPT_DIR" =~ ^(/usr/local/bin|/opt/.*/bin|.*tailroute/bin)$ ]]; then
    echo "WARNING: Script loaded from unexpected location: $SCRIPT_DIR" >&2
fi

# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"
# shellcheck source=lib-state.sh
source "$SCRIPT_DIR/lib-state.sh"

# Paths to system commands (absolute for security)
STAT_CMD="/usr/bin/stat"
SUDO_CMD="/usr/bin/sudo"
PLUTIL_CMD="/usr/bin/plutil"

# Debug log location (secure, root-only directory)
DEBUG_LOG="${DEBUG_LOG:-/var/db/tailroute/debug.log}"
DEBUG_ENABLED="${DEBUG_ENABLED:-false}"

# -----------------------------------------------------------------------------
# _detect_tailscale_cmd — Find the correct tailscale binary
# -----------------------------------------------------------------------------
# Tailscale has two deployment modes on macOS:
# 1. CLI daemon (Homebrew formula): uses unix socket at /var/run/tailscaled.socket
# 2. GUI app (Homebrew cask/PKG): uses XPC via io.tailscale.ipn.macsys
#
# We detect which is active and use the corresponding CLI.
# -----------------------------------------------------------------------------
_detect_tailscale_cmd() {
    # Priority 1: CLI daemon mode (socket exists)
    if [[ -S /var/run/tailscaled.socket ]]; then
        if [[ -x /opt/homebrew/bin/tailscale ]]; then
            echo "/opt/homebrew/bin/tailscale"
            return
        elif [[ -x /usr/local/bin/tailscale ]]; then
            # Fallback to /usr/local if homebrew not there
            echo "/usr/local/bin/tailscale"
            return
        fi
    fi

    # Priority 2: GUI app mode (check for GUI's IPC mechanism)
    if [[ -f /Library/Tailscale/ipnport ]]; then
        if [[ -x /usr/local/bin/tailscale ]]; then
            echo "/usr/local/bin/tailscale"
            return
        fi
    fi

    # Priority 3: Try to find in PATH
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
        return
    fi

    # Default fallback
    echo "/usr/local/bin/tailscale"
}

TAILSCALE_CMD="$(_detect_tailscale_cmd)"

# Get the logged-in user (for calling tailscale as user, not root)
get_console_user() {
    "$STAT_CMD" -f%Su /dev/console 2>/dev/null || echo ""
}

# Validate console username (prevent injection attacks)
validate_console_user() {
    local user="$1"
    
    if [[ -z "$user" ]]; then
        return 1
    fi
    
    # Must be alphanumeric, underscore, or hyphen only
    if [[ ! "$user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid console username: $user"
        return 1
    fi
    
    return 0
}

# Sanitize command output for logging (prevent log injection)
sanitize_output() {
    local output="$1"
    local max_length=500
    
    # Replace newlines with literal \n
    output="${output//$'\n'/\\n}"
    
    # Truncate if too long
    if (( ${#output} > max_length )); then
        output="${output:0:$max_length}... (truncated)"
    fi
    
    echo "$output"
}

# Write to debug log (only if DEBUG_ENABLED or file already exists)
write_debug_log() {
    local message="$1"
    
    # Only log if debugging is enabled or log file already exists
    if [[ "$DEBUG_ENABLED" == "true" ]] || [[ -f "$DEBUG_LOG" ]]; then
        # Ensure parent directory exists and has correct permissions
        local debug_dir
        debug_dir="$(dirname "$DEBUG_LOG")"
        
        if [[ ! -d "$debug_dir" ]]; then
            mkdir -p "$debug_dir" 2>/dev/null || return 1
            chmod 0700 "$debug_dir" 2>/dev/null || true
        fi
        
        # Append to log with timestamp
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $message" >> "$DEBUG_LOG" 2>/dev/null || true
        
        # Ensure log is root-only readable
        chmod 0600 "$DEBUG_LOG" 2>/dev/null || true
    fi
}

# Extract JSON field value (robust parsing with plutil, fallback to grep)
# Args:
#   $1 - JSON string
#   $2 - Field name (e.g., "CorpDNS", "MagicDNSEnabled")
# Returns:
#   0 - Field found and printed to stdout
#   1 - Field not found or invalid JSON
extract_json_field() {
    local json="$1"
    local field="$2"
    local result=""
    
    # Try plutil first (most robust, built-in to macOS)
    if [[ -x "$PLUTIL_CMD" ]]; then
        # Write JSON to temp file (plutil requires a file)
        local temp_json
        temp_json=$(mktemp -t tailroute-json.XXXXXX) || return 1
        echo "$json" > "$temp_json"
        
        # Extract field value
        result=$("$PLUTIL_CMD" -extract "$field" raw -o - "$temp_json" 2>/dev/null) || {
            rm -f "$temp_json"
            # Fall through to grep method
            result=""
        }
        rm -f "$temp_json"
    fi
    
    # Fallback to grep/cut if plutil failed
    if [[ -z "$result" ]]; then
        result=$(echo "$json" | grep -o "\"$field\":[^,}]*" | head -1 | cut -d: -f2 | xargs)
    fi
    
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# _is_cli_daemon_mode — Check if we're using tailscaled (CLI daemon) vs GUI app
# -----------------------------------------------------------------------------
# Returns 0 (true) if using CLI daemon, 1 (false) if using GUI app
# -----------------------------------------------------------------------------
_is_cli_daemon_mode() {
    # CLI daemon mode uses unix socket
    [[ -S /var/run/tailscaled.socket ]]
}

# -----------------------------------------------------------------------------
# get_magicdns_state — Get current MagicDNS accept-dns state
# -----------------------------------------------------------------------------
# Queries Tailscale to determine if MagicDNS (accept-dns) is currently enabled.
#
# Detection method varies by Tailscale deployment:
# - CLI daemon (tailscaled): uses `debug prefs` → CorpDNS field
# - GUI app (System Extension): uses `status --json` → MagicDNSEnabled field
#
# Environment:
#   TAILSCALE_JSON_OUTPUT - If set, use this as mock status output (for testing)
#   TAILSCALE_PREFS_OUTPUT - If set, use this as mock prefs output (for testing)
#
# Returns:
#   0 - MagicDNS is enabled (true printed to stdout)
#   1 - MagicDNS is disabled (false printed to stdout)
#
# Note: Returns 1 if Tailscale is not running (treated as "disabled" state).
# -----------------------------------------------------------------------------
get_magicdns_state() {
    local accepts_dns

    # Use mock output if provided (for testing)
    # Use ${var+x} pattern for POSIX compatibility (works in older bash)
    if [[ -n "${TAILSCALE_PREFS_OUTPUT+x}" ]]; then
        if [[ -z "$TAILSCALE_PREFS_OUTPUT" ]]; then
            echo "false"
            return 1
        fi
        accepts_dns=$(extract_json_field "$TAILSCALE_PREFS_OUTPUT" "CorpDNS" 2>/dev/null) || accepts_dns=""
    elif [[ -n "${TAILSCALE_JSON_OUTPUT+x}" ]]; then
        if [[ -z "$TAILSCALE_JSON_OUTPUT" ]]; then
            echo "false"
            return 1
        fi
        # Try MagicDNSEnabled first, then fall back to AcceptsDNS
        accepts_dns=$(extract_json_field "$TAILSCALE_JSON_OUTPUT" "MagicDNSEnabled" 2>/dev/null) || \
                     accepts_dns=$(extract_json_field "$TAILSCALE_JSON_OUTPUT" "AcceptsDNS" 2>/dev/null) || accepts_dns=""
    elif _is_cli_daemon_mode; then
        # CLI daemon mode: use debug prefs for local CorpDNS setting
        local prefs_output
        prefs_output="$("$TAILSCALE_CMD" debug prefs 2>/dev/null)" || {
            echo "false"
            return 1
        }
        accepts_dns=$(extract_json_field "$prefs_output" "CorpDNS" 2>/dev/null) || accepts_dns=""
    else
        # GUI app mode: use status --json for tailnet MagicDNSEnabled
        local ts_output
        ts_output="$("$TAILSCALE_CMD" status --json 2>/dev/null)" || {
            echo "false"
            return 1
        }
        # Try MagicDNSEnabled first, then fall back to AcceptsDNS
        accepts_dns=$(extract_json_field "$ts_output" "MagicDNSEnabled" 2>/dev/null) || \
                     accepts_dns=$(extract_json_field "$ts_output" "AcceptsDNS" 2>/dev/null) || accepts_dns=""
    fi

    # Default to false if not found
    if [[ -z "$accepts_dns" ]]; then
        accepts_dns="false"
    fi

    echo "$accepts_dns"

    # Return exit code based on state
    if [[ "$accepts_dns" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# disable_magicdns — Turn off MagicDNS (accept-dns=false)
# -----------------------------------------------------------------------------
# Disables Tailscale's MagicDNS by running `tailscale set --accept-dns=false`.
# Only executes if MagicDNS is currently enabled (idempotent).
#
# Returns:
#   0 - Successfully disabled (or already disabled)
#   1 - Failed to disable
# 
# Side effects:
#   - Calls `log_dns_change()` on success
#   - Updates state manifest
# -----------------------------------------------------------------------------
disable_magicdns() {
    # Check current state
    if ! get_magicdns_state >/dev/null 2>&1; then
        # Already disabled
        return 0
    fi
    
    # Disable MagicDNS (run as console user, not root)
    local console_user
    console_user=$(get_console_user)
    
    if [[ -n "$console_user" ]] && validate_console_user "$console_user"; then
        # Running as root via launchd — call tailscale as the console user
        log_debug "Calling: sudo -u $console_user tailscale set --accept-dns=false"
        local output
        output=$("$SUDO_CMD" -u "$console_user" "$TAILSCALE_CMD" set --accept-dns=false 2>&1)
        local exit_code=$?
        
        # Log to secure debug log (sanitized)
        local sanitized_output
        sanitized_output=$(sanitize_output "$output")
        write_debug_log "Command: sudo -u $console_user $TAILSCALE_CMD set --accept-dns=false | Exit: $exit_code | Output: $sanitized_output"
        
        if (( exit_code == 0 )); then
            log_dns_change "disable" "vpn_active"
            state_write "disable" "false"
            return 0
        else
            log_error "Failed to disable MagicDNS (exit: $exit_code, user: $console_user)"
            return 1
        fi
    else
        # Fallback: try direct call
        if "$TAILSCALE_CMD" set --accept-dns=false >/dev/null 2>&1; then
            log_dns_change "disable" "vpn_active"
            state_write "disable" "false"
            return 0
        else
            log_error "Failed to disable MagicDNS (no valid console user found)"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# enable_magicdns — Turn on MagicDNS (accept-dns=true)
# -----------------------------------------------------------------------------
# Enables Tailscale's MagicDNS by running `tailscale set --accept-dns=true`.
# Only executes if MagicDNS is currently disabled (idempotent).
#
# Returns:
#   0 - Successfully enabled (or already enabled)
#   1 - Failed to enable
#
# Side effects:
#   - Calls `log_dns_change()` on success
#   - Updates state manifest
# -----------------------------------------------------------------------------
enable_magicdns() {
    # Check current state
    if get_magicdns_state >/dev/null 2>&1; then
        # Already enabled
        return 0
    fi
    
    # Enable MagicDNS (run as console user, not root)
    local console_user
    console_user=$(get_console_user)
    
    if [[ -n "$console_user" ]] && validate_console_user "$console_user"; then
        # Running as root via launchd — call tailscale as the console user
        log_debug "Calling: sudo -u $console_user tailscale set --accept-dns=true"
        local output
        output=$("$SUDO_CMD" -u "$console_user" "$TAILSCALE_CMD" set --accept-dns=true 2>&1)
        local exit_code=$?
        
        # Log to secure debug log (sanitized)
        local sanitized_output
        sanitized_output=$(sanitize_output "$output")
        write_debug_log "Command: sudo -u $console_user $TAILSCALE_CMD set --accept-dns=true | Exit: $exit_code | Output: $sanitized_output"
        
        if (( exit_code == 0 )); then
            log_dns_change "enable" "vpn_inactive"
            state_write "enable" "true"
            return 0
        else
            log_error "Failed to enable MagicDNS (exit: $exit_code, user: $console_user)"
            return 1
        fi
    else
        # Fallback: try direct call
        if "$TAILSCALE_CMD" set --accept-dns=true >/dev/null 2>&1; then
            log_dns_change "enable" "vpn_inactive"
            state_write "enable" "true"
            return 0
        else
            log_error "Failed to enable MagicDNS (no valid console user found)"
            return 1
        fi
    fi
}
