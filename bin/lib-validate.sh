#!/usr/bin/env bash
# lib-validate.sh — Input validation functions for tailroute
#
# All functions return 0 on valid input, 1 on invalid.
# Errors are logged to stderr.

set -euo pipefail

# -----------------------------------------------------------------------------
# validate_interface_name — Check if name is a valid utun interface
# -----------------------------------------------------------------------------
# Args:
#   $1 - interface name to validate
# Returns:
#   0 - valid utun interface name (matches ^utun[0-9]+$)
#   1 - invalid
# -----------------------------------------------------------------------------
validate_interface_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "ERROR: interface name is empty" >&2
        return 1
    fi

    # Must be utun followed by one or more digits only
    if [[ "$name" =~ ^utun[0-9]+$ ]]; then
        return 0
    else
        echo "ERROR: invalid interface name '$name' (expected utunN format)" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# validate_ipv4 — Check if string is a valid IPv4 address
# -----------------------------------------------------------------------------
# Args:
#   $1 - IP address to validate
# Returns:
#   0 - valid IPv4 address
#   1 - invalid
# -----------------------------------------------------------------------------
validate_ipv4() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address is empty" >&2
        return 1
    fi

    # Must match N.N.N.N format where N is 0-255
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: invalid IP address format '$ip'" >&2
        return 1
    fi

    # Validate each octet is 0-255
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            echo "ERROR: IP octet out of range in '$ip'" >&2
            return 1
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# validate_cidr — Check if string is a valid CIDR notation
# -----------------------------------------------------------------------------
# Args:
#   $1 - CIDR to validate (e.g., "100.64.0.0/10")
# Returns:
#   0 - valid CIDR
#   1 - invalid
# -----------------------------------------------------------------------------
validate_cidr() {
    local cidr="$1"

    if [[ -z "$cidr" ]]; then
        echo "ERROR: CIDR is empty" >&2
        return 1
    fi

    # Must match N.N.N.N/P format
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: invalid CIDR format '$cidr'" >&2
        return 1
    fi

    # Split into IP and prefix
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Validate IP part
    if ! validate_ipv4 "$ip" 2>/dev/null; then
        echo "ERROR: invalid IP portion in CIDR '$cidr'" >&2
        return 1
    fi

    # Validate prefix is 0-32
    if (( prefix < 0 || prefix > 32 )); then
        echo "ERROR: CIDR prefix out of range in '$cidr' (must be 0-32)" >&2
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# ip_in_cidr — Check if an IP falls within a CIDR range
# -----------------------------------------------------------------------------
# Args:
#   $1 - IP address
#   $2 - CIDR range
# Returns:
#   0 - IP is within CIDR
#   1 - IP is NOT within CIDR (or invalid input)
# -----------------------------------------------------------------------------
ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Validate inputs
    if ! validate_ipv4 "$ip" 2>/dev/null; then
        return 1
    fi
    if ! validate_cidr "$cidr" 2>/dev/null; then
        return 1
    fi

    # Extract prefix length
    local prefix="${cidr#*/}"

    # Convert IP to 32-bit integer
    local ip_int=0
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        ip_int=$(( (ip_int << 8) | octet ))
    done

    # Extract network portion of CIDR
    local net_ip="${cidr%/*}"
    local net_int=0
    read -ra net_octets <<< "$net_ip"
    for octet in "${net_octets[@]}"; do
        net_int=$(( (net_int << 8) | octet ))
    done

    # Calculate mask
    local mask
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    # Check if IP is in network
    if (( (ip_int & mask) == (net_int & mask) )); then
        return 0
    else
        return 1
    fi
}
