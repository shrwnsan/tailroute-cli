#!/usr/bin/env bash
# lib-detect.sh — Network interface detection functions for tailroute
#
# Functions to detect Tailscale and VPN interfaces using macOS built-in tools.
# All external commands use absolute paths for security.

# Guard: prevent re-sourcing to avoid multiple sourcing of lib-validate.sh
if [[ "${_DETECT_SOURCED:-0}" == "1" ]]; then
    return 0
fi
readonly _DETECT_SOURCED=1

set -euo pipefail

# Source validation library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-validate.sh
source "$SCRIPT_DIR/lib-validate.sh"

# Paths to system commands (absolute for security)
IFCONFIG="/sbin/ifconfig"
NETSTAT="/usr/sbin/netstat"

# CGNAT range for Tailscale
TAILSCALE_CGNAT_CIDR="100.64.0.0/10"

# -----------------------------------------------------------------------------
# find_tailscale_interface — Find the utun interface with Tailscale CGNAT IP
# -----------------------------------------------------------------------------
# Scans all utun interfaces to find one with an IP in the 100.64.0.0/10 range.
# This is the Tailscale-specific CGNAT address block.
#
# Environment:
#   IFCONFIG_OUTPUT - If set, use this as mock ifconfig output (for testing)
#
# Returns:
#   0 - Tailscale interface found (interface name printed to stdout)
#   1 - No Tailscale interface found (empty string printed to stdout)
# -----------------------------------------------------------------------------
find_tailscale_interface() {
    local ifconfig_output

    # Use mock output if provided (for testing)
    if [[ -n "${IFCONFIG_OUTPUT:-}" ]]; then
        ifconfig_output="$IFCONFIG_OUTPUT"
    else
        ifconfig_output="$($IFCONFIG 2>/dev/null)" || return 1
    fi

    # Parse ifconfig output to find utun interfaces with CGNAT IPs
    # Format: interface blocks separated by blank lines
    # Each block has "utunN:" header followed by "inet 100.x.x.x ..."

    local current_interface=""
    local in_utun_block=false

    while IFS= read -r line; do
        # Check for interface header
        if [[ "$line" =~ ^(utun[0-9]+): ]]; then
            current_interface="${BASH_REMATCH[1]}"
            in_utun_block=true
            continue
        fi

        # Check for non-utun interface (resets block tracking)
        if [[ "$line" =~ ^[a-z]+[0-9]*: ]] && [[ ! "$line" =~ ^utun ]]; then
            in_utun_block=false
            current_interface=""
            continue
        fi

        # Check for inet address in current utun block
        if [[ "$in_utun_block" == true ]] && [[ "$line" =~ inet[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            local ip="${BASH_REMATCH[1]}"

            # Check if IP is in Tailscale CGNAT range
            if ip_in_cidr "$ip" "$TAILSCALE_CGNAT_CIDR" 2>/dev/null; then
                # Validate interface name before returning
                if validate_interface_name "$current_interface" 2>/dev/null; then
                    echo "$current_interface"
                    return 0
                fi
            fi
        fi
    done <<< "$ifconfig_output"

    # No Tailscale interface found
    echo ""
    return 1
}

# -----------------------------------------------------------------------------
# get_tailscale_ip — Extract the CGNAT IP from a Tailscale interface
# -----------------------------------------------------------------------------
# Given a validated interface name, extracts its 100.x.x.x IP address.
#
# Args:
#   $1 - Interface name (must be validated utun interface)
#
# Environment:
#   IFCONFIG_OUTPUT - If set, use this as mock ifconfig output (for testing)
#
# Returns:
#   0 - IP found (printed to stdout)
#   1 - No CGNAT IP on interface or invalid input (empty string printed)
# -----------------------------------------------------------------------------
get_tailscale_ip() {
    local interface="$1"

    # Validate interface name
    if ! validate_interface_name "$interface" 2>/dev/null; then
        echo ""
        return 1
    fi

    local ifconfig_output

    # Use mock output if provided (for testing)
    if [[ -n "${IFCONFIG_OUTPUT:-}" ]]; then
        ifconfig_output="$IFCONFIG_OUTPUT"
    else
        ifconfig_output="$($IFCONFIG "$interface" 2>/dev/null)" || {
            echo ""
            return 1
        }
    fi

    # Parse for inet addresses and find one in CGNAT range
    while IFS= read -r line; do
        if [[ "$line" =~ inet[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            local ip="${BASH_REMATCH[1]}"

            if ip_in_cidr "$ip" "$TAILSCALE_CGNAT_CIDR" 2>/dev/null; then
                if validate_ipv4 "$ip" 2>/dev/null; then
                    echo "$ip"
                    return 0
                fi
            fi
        fi
    done <<< "$ifconfig_output"

    echo ""
    return 1
}

# -----------------------------------------------------------------------------
# find_vpn_default_route — Find VPN interface with default route (excluding Tailscale)
# -----------------------------------------------------------------------------
# Parses routing table to find a utun interface (other than Tailscale) that
# has a default route (0.0.0.0/0). This indicates an active VPN tunnel.
#
# Args:
#   $1 - Tailscale interface name to exclude (can be empty if no Tailscale)
#
# Environment:
#   NETSTAT_OUTPUT - If set, use this as mock netstat output (for testing)
#
# Returns:
#   0 - VPN interface found (interface name printed to stdout)
#   1 - No VPN interface found (empty string printed to stdout)
# -----------------------------------------------------------------------------
find_vpn_default_route() {
    local ts_interface="${1:-}"

    local netstat_output

    # Use mock output if provided (for testing)
    if [[ -n "${NETSTAT_OUTPUT:-}" ]]; then
        netstat_output="$NETSTAT_OUTPUT"
    else
        netstat_output="$($NETSTAT -rn 2>/dev/null)" || return 1
    fi

    # Parse netstat -rn output for default routes
    # Format: "default    gateway_ip    interface"
    # We look for utun interfaces that are NOT the Tailscale interface

    while IFS= read -r line; do
         # Match default route lines with utun interface
         # Example: "default    10.8.0.1    utun3"
         # Skip IPv6 link-local routes (fe80::%utunX) — only want IPv4 default routes
         if [[ "$line" =~ ^default[[:space:]]+ ]] && [[ ! "$line" =~ fe80 ]]; then
             # Extract interface name (last field)
             local interface
             interface=$(echo "$line" | awk '{print $NF}')

             # Must be a utun interface
             if [[ ! "$interface" =~ ^utun[0-9]+$ ]]; then
                 continue
             fi

             # Skip if this is the Tailscale interface
             if [[ -n "$ts_interface" ]] && [[ "$interface" == "$ts_interface" ]]; then
                 continue
             fi

             # Validate interface name
             if validate_interface_name "$interface" 2>/dev/null; then
                 echo "$interface"
                 return 0
             fi
         fi
     done <<< "$netstat_output"

    echo ""
    return 1
}

# -----------------------------------------------------------------------------
# find_physical_gateway — Find default gateway on physical interface
# -----------------------------------------------------------------------------
# Finds the default gateway IP and interface for the physical network
# (Wi-Fi or Ethernet). This is used for understanding the "real" network path.
#
# Environment:
#   NETSTAT_OUTPUT - If set, use this as mock netstat output (for testing)
#
# Returns:
#   0 - Gateway found (prints "interface ip" to stdout)
#   1 - No physical gateway found (empty string printed)
# -----------------------------------------------------------------------------
find_physical_gateway() {
    local netstat_output

    # Use mock output if provided (for testing)
    if [[ -n "${NETSTAT_OUTPUT:-}" ]]; then
        netstat_output="$NETSTAT_OUTPUT"
    else
        netstat_output="$($NETSTAT -rn 2>/dev/null)" || return 1
    fi

    # Parse for default routes on physical interfaces (en0, en1, etc.)
    while IFS= read -r line; do
        if [[ "$line" =~ ^default[[:space:]]+ ]]; then
            # Extract gateway IP and interface
            local gateway_ip
            local interface
            gateway_ip=$(echo "$line" | awk '{print $2}')
            interface=$(echo "$line" | awk '{print $NF}')

            # Must be a physical interface (en0, en1, etc.)
            if [[ ! "$interface" =~ ^en[0-9]+$ ]]; then
                continue
            fi

            # Validate gateway IP
            if validate_ipv4 "$gateway_ip" 2>/dev/null; then
                echo "$interface $gateway_ip"
                return 0
            fi
        fi
    done <<< "$netstat_output"

    echo ""
    return 1
}
