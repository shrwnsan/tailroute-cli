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
# reconcile — Main decision logic
# =============================================================================
# Detects current Tailscale and VPN state, then reconciles MagicDNS setting.
#
# Decision matrix:
#   TS + VPN active → disable MagicDNS (VPN needs internet access)
#   TS active, no VPN → enable MagicDNS (safe to use, no conflicts)
#   No TS → no action (state is per-Tailscale-session, resets on reconnect)
#   Multiple VPNs → log warning, do nothing (ambiguous state)
#
# Returns:
#   0 - Reconciliation completed successfully
#   1 - Failed to perform reconciliation
#
# Side effects:
#   - Calls `log_info()` to record reconciliation outcome
#   - May call `disable_magicdns()` or `enable_magicdns()`
#   - Updates state manifest via those functions
# =============================================================================
reconcile() {
    # Detect current interfaces
    local ts_interface
    local vpn_interface
    
    ts_interface=$(find_tailscale_interface 2>/dev/null) || ts_interface=""
    
    if [[ -z "$ts_interface" ]]; then
        # No Tailscale running — no action needed
        # (state is per-Tailscale-session, will reset on reconnect)
        log_info "No Tailscale interface detected; idle"
        return 0
    fi
    
    # Extract Tailscale IP (informational)
    local ts_ip
    ts_ip=$(get_tailscale_ip "$ts_interface" 2>/dev/null) || ts_ip=""
    
    # Detect VPN (exclude Tailscale interface)
    vpn_interface=$(find_vpn_default_route "$ts_interface" 2>/dev/null) || vpn_interface=""
    
    # Decision matrix
    if [[ -n "$vpn_interface" ]]; then
        # VPN is active with Tailscale — disable MagicDNS
        log_info "Tailscale detected ($ts_ip on $ts_interface), VPN active ($vpn_interface); toggling MagicDNS"
        
        if ! disable_magicdns; then
            log_error "Failed to disable MagicDNS"
            return 1
        fi
        return 0
    else
        # Tailscale active, no VPN — enable MagicDNS
        log_info "Tailscale detected ($ts_ip on $ts_interface), no VPN; ensuring MagicDNS is enabled"
        
        if ! enable_magicdns; then
            log_error "Failed to enable MagicDNS"
            return 1
        fi
        return 0
    fi
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
