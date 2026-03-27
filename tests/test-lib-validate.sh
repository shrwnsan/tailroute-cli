#!/usr/bin/env bash
# test-lib-validate.sh — Tests for lib-validate.sh

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-validate.sh"

# Suppress error output during tests
exec 2>/dev/null

# =============================================================================
# validate_interface_name tests
# =============================================================================

test_interface_name_valid_utun0() {
    assert_ok validate_interface_name "utun0"
}

test_interface_name_valid_utun12() {
    assert_ok validate_interface_name "utun12"
}

test_interface_name_valid_utun999() {
    assert_ok validate_interface_name "utun999"
}

test_interface_name_invalid_eth0() {
    assert_fail validate_interface_name "eth0"
}

test_interface_name_invalid_utun_no_number() {
    assert_fail validate_interface_name "utun"
}

test_interface_name_invalid_utun_dash() {
    assert_fail validate_interface_name "utun-1"
}

test_interface_name_invalid_command_injection() {
    assert_fail validate_interface_name "utun0; rm -rf /"
}

test_interface_name_invalid_empty() {
    assert_fail validate_interface_name ""
}

test_interface_name_invalid_en0() {
    assert_fail validate_interface_name "en0"
}

# =============================================================================
# validate_ipv4 tests
# =============================================================================

test_ipv4_valid_10_0_0_1() {
    assert_ok validate_ipv4 "10.0.0.1"
}

test_ipv4_valid_100_100_45_12() {
    assert_ok validate_ipv4 "100.100.45.12"
}

test_ipv4_valid_0_0_0_0() {
    assert_ok validate_ipv4 "0.0.0.0"
}

test_ipv4_valid_255_255_255_255() {
    assert_ok validate_ipv4 "255.255.255.255"
}

test_ipv4_valid_192_168_1_1() {
    assert_ok validate_ipv4 "192.168.1.1"
}

test_ipv4_invalid_octet_over_255() {
    assert_fail validate_ipv4 "10.0.0.999"
}

test_ipv4_invalid_not_an_ip() {
    assert_fail validate_ipv4 "not-an-ip"
}

test_ipv4_invalid_empty() {
    assert_fail validate_ipv4 ""
}

test_ipv4_invalid_missing_octet() {
    assert_fail validate_ipv4 "10.0.0"
}

test_ipv4_invalid_extra_octet() {
    assert_fail validate_ipv4 "10.0.0.1.5"
}

test_ipv4_invalid_letters() {
    assert_fail validate_ipv4 "10.0.0.abc"
}

# =============================================================================
# validate_cidr tests
# =============================================================================

test_cidr_valid_100_64_0_0_10() {
    assert_ok validate_cidr "100.64.0.0/10"
}

test_cidr_valid_10_0_0_0_8() {
    assert_ok validate_cidr "10.0.0.0/8"
}

test_cidr_valid_192_168_0_0_16() {
    assert_ok validate_cidr "192.168.0.0/16"
}

test_cidr_valid_0_0_0_0_0() {
    assert_ok validate_cidr "0.0.0.0/0"
}

test_cidr_valid_32_prefix() {
    assert_ok validate_cidr "192.168.1.1/32"
}

test_cidr_invalid_no_prefix() {
    assert_fail validate_cidr "100.64.0.0"
}

test_cidr_invalid_prefix_over_32() {
    assert_fail validate_cidr "10.0.0.0/33"
}

test_cidr_invalid_octet_over_255() {
    assert_fail validate_cidr "999.0.0.0/10"
}

test_cidr_invalid_empty() {
    assert_fail validate_cidr ""
}

test_cidr_invalid_foo() {
    assert_fail validate_cidr "foo/10"
}

# =============================================================================
# ip_in_cidr tests
# =============================================================================

test_ip_in_cidr_100_100_in_100_64() {
    assert_ok ip_in_cidr "100.100.45.12" "100.64.0.0/10"
}

test_ip_in_cidr_100_127_in_100_64() {
    assert_ok ip_in_cidr "100.127.255.255" "100.64.0.0/10"
}

test_ip_in_cidr_100_63_not_in_100_64() {
    assert_fail ip_in_cidr "100.63.255.255" "100.64.0.0/10"
}

test_ip_in_cidr_10_5_in_10_0_0_0_8() {
    assert_ok ip_in_cidr "10.5.6.7" "10.0.0.0/8"
}

test_ip_in_cidr_192_168_not_in_10_0_0_0_8() {
    assert_fail ip_in_cidr "192.168.1.1" "10.0.0.0/8"
}

test_ip_in_cidr_invalid_ip() {
    assert_fail ip_in_cidr "invalid" "10.0.0.0/8"
}

test_ip_in_cidr_invalid_cidr() {
    assert_fail ip_in_cidr "10.0.0.1" "invalid"
}
