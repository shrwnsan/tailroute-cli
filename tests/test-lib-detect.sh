#!/usr/bin/env bash
# test-lib-detect.sh — Tests for lib-detect.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-detect.sh"

# Suppress error output during tests
exec 2>/dev/null

# =============================================================================
# find_tailscale_interface tests
# =============================================================================

test_find_tailscale_interface_found() {
    local ifconfig_output=$(cat <<'EOF'
utun0: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet6 fe80::1%utun0 prefixlen 64 scopeid 0x5
	nd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>
utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.100.45.12 netmask 0xffffffff
	inet6 fe80::1%utun4 prefixlen 64 scopeid 0x4
	nd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>
en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 00:11:22:33:44:55
	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" "utun4"
}

test_find_tailscale_interface_not_found() {
    local ifconfig_output=$(cat <<'EOF'
en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 00:11:22:33:44:55
	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" ""
}

test_find_tailscale_interface_multiple_utun() {
    local ifconfig_output=$(cat <<'EOF'
utun0: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 10.8.0.6 netmask 0xffffffff
utun3: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.50.1 netmask 0xffffffff
utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.100.45.12 netmask 0xffffffff
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" "utun4"
}

test_find_tailscale_interface_cgnat_boundary_low() {
    local ifconfig_output=$(cat <<'EOF'
utun0: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.64.0.1 netmask 0xffffffff
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" "utun0"
}

test_find_tailscale_interface_cgnat_boundary_high() {
    local ifconfig_output=$(cat <<'EOF'
utun0: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.127.255.255 netmask 0xffffffff
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" "utun0"
}

test_find_tailscale_interface_cgnat_boundary_low_excludes() {
    local ifconfig_output=$(cat <<'EOF'
utun0: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.63.255.255 netmask 0xffffffff
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(find_tailscale_interface)
    
    assert_eq "$result" ""
}

# =============================================================================
# get_tailscale_ip tests
# =============================================================================

test_get_tailscale_ip_valid() {
    local ifconfig_output=$(cat <<'EOF'
utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 100.100.45.12 netmask 0xffffffff
	inet6 fe80::1%utun4 prefixlen 64 scopeid 0x4
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(get_tailscale_ip "utun4")
    
    assert_eq "$result" "100.100.45.12"
}

test_get_tailscale_ip_invalid_interface_name() {
    export IFCONFIG_OUTPUT=""
    
    local result
    result=$(get_tailscale_ip "eth0")
    
    assert_eq "$result" ""
}

test_get_tailscale_ip_interface_not_cgnat() {
    local ifconfig_output=$(cat <<'EOF'
utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 10.8.0.6 netmask 0xffffffff
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(get_tailscale_ip "utun4")
    
    assert_eq "$result" ""
}

test_get_tailscale_ip_empty_interface() {
    export IFCONFIG_OUTPUT=""
    
    local result
    result=$(get_tailscale_ip "")
    
    assert_eq "$result" ""
}

test_get_tailscale_ip_multiple_ips() {
    local ifconfig_output=$(cat <<'EOF'
utun4: flags=8051<UP,POINTOPOINT,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.1 netmask 0xffffffff
	inet 100.100.45.12 netmask 0xffffffff
	inet6 fe80::1%utun4 prefixlen 64 scopeid 0x4
EOF
    )
    export IFCONFIG_OUTPUT="$ifconfig_output"
    
    local result
    result=$(get_tailscale_ip "utun4")
    
    assert_eq "$result" "100.100.45.12"
}

# =============================================================================
# find_vpn_default_route tests
# =============================================================================

test_find_vpn_default_route_found() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.8.0.1           UGc          utun3
0.0.0.0/1          10.8.0.1           UGc          utun3
127.0.0.1          127.0.0.1          UH           lo0
en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST>
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "utun4")
    
    assert_eq "$result" "utun3"
}

test_find_vpn_default_route_not_found() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "")
    
    assert_eq "$result" ""
}

test_find_vpn_default_route_exclude_tailscale() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.100.0.1         UGc          utun4
default            10.8.0.1           UGc          utun3
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "utun4")
    
    assert_eq "$result" "utun3"
}

test_find_vpn_default_route_only_tailscale() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.100.0.1         UGc          utun4
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "utun4")
    
    assert_eq "$result" ""
}

test_find_vpn_default_route_ignores_physical() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            192.168.1.1        UGc           en0
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "")
    
    assert_eq "$result" ""
}

test_find_vpn_default_route_empty_ts_interface() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.8.0.1           UGc          utun3
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_vpn_default_route "")
    
    assert_eq "$result" "utun3"
}

# =============================================================================
# find_physical_gateway tests
# =============================================================================

test_find_physical_gateway_wifi() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            192.168.1.1        UGc           en0
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_physical_gateway)
    
    assert_eq "$result" "en0 192.168.1.1"
}

test_find_physical_gateway_ethernet() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.0.0.1           UGc           en1
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_physical_gateway)
    
    assert_eq "$result" "en1 10.0.0.1"
}

test_find_physical_gateway_not_found() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.8.0.1           UGc          utun3
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_physical_gateway)
    
    assert_eq "$result" ""
}

test_find_physical_gateway_prefers_first() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            192.168.1.1        UGc           en0
default            10.0.0.1           UGc           en1
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_physical_gateway)
    
    assert_eq "$result" "en0 192.168.1.1"
}

test_find_physical_gateway_ignores_utun() {
    local netstat_output=$(cat <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags       Netif Expire
default            10.8.0.1           UGc          utun3
default            192.168.1.1        UGc           en0
127.0.0.1          127.0.0.1          UH           lo0
EOF
    )
    export NETSTAT_OUTPUT="$netstat_output"
    
    local result
    result=$(find_physical_gateway)
    
    assert_eq "$result" "en0 192.168.1.1"
}
