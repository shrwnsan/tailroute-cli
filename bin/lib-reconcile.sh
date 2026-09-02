#!/usr/bin/env bash
# lib-reconcile.sh — Core reconciliation logic for tailroute
#
# Implements the decision matrix: detects Tailscale + VPN state and
# toggles MagicDNS accordingly.

set -euo pipefail

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-log.sh
source "$SCRIPT_DIR/lib-log.sh"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"
# shellcheck source=lib-dns.sh
source "$SCRIPT_DIR/lib-dns.sh"
# shellcheck source=lib-state.sh
source "$SCRIPT_DIR/lib-state.sh"

# =============================================================================
# Reconcile transition state
# =============================================================================
# reconcile() is invoked from three paths: debounced route events, the 60s
# safety-net poll, and SIGHUP. Route events can fire every few seconds while
# Tailscale is up, which historically re-ran the MagicDNS toggle and logged an
# INFO line on every invocation (~21k identical lines/day, each a `tailscale`
# CLI spawn). Track the last applied mode and the time of the last apply so
# unchanged ticks stay quiet (debug-level) and re-apply only on a mode
# transition or once RECONCILE_REASSERT_SECONDS have elapsed since the last
# apply — the re-assert preserves self-healing against out-of-band MagicDNS
# changes, which correlate with route churn (a Tailscale re-auth or roam
# churns routes while the mode samples unchanged). SIGHUP passes "force".
#
# All variables are per-process: the safety-net poll runs in a forked
# subshell (start_poll in lib-event-loop.sh) that inherits them at fork time
# and keeps its own copies. run_event_loop applies policy once BEFORE
# start_poll, so the fork inherits real state and the poll's first tick is a
# legitimate time-gated re-assert, not a duplicate apply.
#
# _RECONCILE_LAST_APPLY uses bash's SECONDS builtin (wall-clock seconds since
# shell start): no fork per check, it advances through `sleep` and counts
# time the machine spent asleep (first tick after wake re-asserts
# immediately), and a forked subshell continues the parent's baseline.
# =============================================================================
_reconcile_sanitize_reassert_seconds() {
    # Must be a positive base-10 integer: a non-numeric value is a fatal
    # "unbound variable" abort under set -u once used in arithmetic, and
    # 0 / negatives / leading-zero octal tokens (08) would re-assert on
    # every tick. Fall back to the default rather than trust a bad override.
    [[ "${RECONCILE_REASSERT_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] || RECONCILE_REASSERT_SECONDS=60
}
_RECONCILE_LAST_MODE=""
_RECONCILE_LAST_APPLY=0
RECONCILE_REASSERT_SECONDS="${RECONCILE_REASSERT_SECONDS:-60}"
_reconcile_sanitize_reassert_seconds

# =============================================================================
# reconcile — Main decision logic
# =============================================================================
# Detects current Tailscale and VPN state, then reconciles MagicDNS setting.
#
# Args:
#   $1 - optional "force": skip the unchanged-mode short-circuit (SIGHUP)
#
# Decision matrix:
#   TS + VPN active → disable MagicDNS (VPN needs internet access)
#   TS active, no VPN → enable MagicDNS (safe to use, no conflicts)
#   No TS → no action (state is per-Tailscale-session, resets on reconnect)
#   Multiple VPNs → log warning, do nothing (ambiguous state)
#
# Returns:
#   0 - Reconciliation completed successfully (including unchanged-mode skip)
#   1 - Failed to perform reconciliation
#
# Side effects:
#   - Calls `log_info()` on mode transitions and periodic re-asserts;
#     unchanged ticks log at debug level only
#   - May call `disable_magicdns()` or `enable_magicdns()`
#   - Updates state manifest via those functions
# =============================================================================
reconcile() {
    local force="${1:-}"
    local ts_interface
    local vpn_interface
    local ts_ip
    local mode

    # Detect current interfaces
    ts_interface=$(find_tailscale_interface 2>/dev/null) || ts_interface=""

    if [[ -z "$ts_interface" ]]; then
        # No Tailscale running — no action needed
        # (state is per-Tailscale-session, will reset on reconnect)
        mode="idle"
        ts_ip=""
        vpn_interface=""
    else
        # Extract Tailscale IP (informational)
        ts_ip=$(get_tailscale_ip "$ts_interface" 2>/dev/null) || ts_ip=""

        # Detect VPN (exclude Tailscale interface)
        vpn_interface=$(find_vpn_default_route "$ts_interface" 2>/dev/null) || vpn_interface=""

        if [[ -n "$vpn_interface" ]]; then
            mode="vpn"
        else
            mode="no-vpn"
        fi
    fi

    # Unchanged mode: stay quiet and skip the toggle, but re-assert
    # periodically so out-of-band MagicDNS changes still self-heal.
    if [[ "$force" != "force" && "$mode" == "$_RECONCILE_LAST_MODE" ]]; then
        # Wall clock stepped backward (NTP correction): elapsed would go
        # negative and stall the gate — treat as fully elapsed.
        if (( SECONDS < _RECONCILE_LAST_APPLY )); then
            _RECONCILE_LAST_APPLY=0
        fi
        if (( SECONDS - _RECONCILE_LAST_APPLY < RECONCILE_REASSERT_SECONDS )); then
            log_debug "reconcile: mode unchanged ($mode); skipping re-apply"
            return 0
        fi
        log_debug "reconcile: re-asserting unchanged mode ($mode) after ${RECONCILE_REASSERT_SECONDS}s"
    fi
    # Stamp BEFORE the toggle: a wedged tailscale CLI must re-apply at the
    # next gate expiry, not on every event tick. Do not move this below the
    # enable/disable calls.
    _RECONCILE_LAST_APPLY=$SECONDS
    _RECONCILE_LAST_MODE="$mode"

    case "$mode" in
        idle)
            log_info "No Tailscale interface detected; idle"
            return 0
            ;;
        vpn)
            # VPN is active with Tailscale — disable MagicDNS
            log_info "Tailscale detected ($ts_ip on $ts_interface), VPN active ($vpn_interface); disabling MagicDNS"

            if ! disable_magicdns; then
                log_error "Failed to disable MagicDNS"
                return 1
            fi
            return 0
            ;;
        no-vpn)
            # Tailscale active, no VPN — enable MagicDNS
            log_info "Tailscale detected ($ts_ip on $ts_interface), no VPN; ensuring MagicDNS is enabled"

            if ! enable_magicdns; then
                log_error "Failed to enable MagicDNS"
                return 1
            fi
            return 0
            ;;
    esac
}

# =============================================================================
# reconcile_dry_run — Preview reconciliation without making changes
# =============================================================================
# Detects current state and prints what reconcile() would do,
# without actually modifying any DNS settings.
#
# Returns:
#   0 - Always (diagnostic only)
#
# Output:
#   [DRY-RUN] messages to stdout showing actions that would be taken
# =============================================================================
reconcile_dry_run() {
    echo "[DRY-RUN] Checking interface state..."
    
    # Detect current interfaces
    local ts_interface
    local vpn_interface
    
    ts_interface=$(find_tailscale_interface 2>/dev/null) || ts_interface=""
    
    if [[ -z "$ts_interface" ]]; then
        echo "[DRY-RUN] No Tailscale interface; no action needed"
        return 0
    fi
    
    # Extract Tailscale IP
    local ts_ip
    ts_ip=$(get_tailscale_ip "$ts_interface" 2>/dev/null) || ts_ip=""
    
    echo "[DRY-RUN] Found Tailscale: $ts_interface${ts_ip:+ ($ts_ip)}"
    
    # Detect VPN
    vpn_interface=$(find_vpn_default_route "$ts_interface" 2>/dev/null) || vpn_interface=""
    
    if [[ -n "$vpn_interface" ]]; then
        echo "[DRY-RUN] Found VPN: $vpn_interface"
        echo "[DRY-RUN] Would disable MagicDNS (VPN active)"
    else
        echo "[DRY-RUN] No VPN detected"
        echo "[DRY-RUN] Would enable MagicDNS (VPN inactive)"
    fi
    
    return 0
}
