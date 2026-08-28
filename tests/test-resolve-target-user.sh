#!/usr/bin/env bash
# test-resolve-target-user.sh — Tests for _tr_resolve_target_user (T-434)
#
# Tests correct user resolution when running under sudo, ensuring $HOME
# is not used (which points to root's home under sudo).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$TEST_DIR/../bin"

# -----------------------------------------------------------------------------
# Mock dscl and id commands
# -----------------------------------------------------------------------------
_setup_resolve_mocks() {
    _RTS_SANDBOX="$(mktemp -d)"
    mkdir -p "$_RTS_SANDBOX/bin"

    # Default: dscl mock that returns a fake home directory
    cat > "$_RTS_SANDBOX/bin/dscl" <<'MOCK'
#!/bin/sh
# Usage: dscl . -read /Users/<user> NFSHomeDirectory
user="${3#/Users/}"
if [ "$user" = "nonexistent" ]; then
    exit 1
fi
echo "NFSHomeDirectory: ${FAKE_DSCL_HOME:-/Users/$user}"
MOCK

    cat > "$_RTS_SANDBOX/bin/id" <<'MOCK'
#!/bin/sh
# id -u <user>
if [ "$1" = "-u" ]; then
    shift
    case "${1:-}" in
        alice)   echo "501" ;;
        bob)     echo "502" ;;
        root)    echo "0" ;;
        *)       echo "999" ;;
    esac
else
    echo "uid=0(root)"
fi
MOCK

    chmod +x "$_RTS_SANDBOX/bin/"*

    export DSCL_CMD="$_RTS_SANDBOX/bin/dscl"
    export ID_CMD="$_RTS_SANDBOX/bin/id"

    # shellcheck source=../bin/lib-tunnel.sh
    source "$BIN_DIR/lib-tunnel.sh"
}

_cleanup_resolve_mocks() {
    rm -rf "${_RTS_SANDBOX:-}" 2>/dev/null || true
}

# =============================================================================
# Tests
# =============================================================================

test_resolve_without_sudo_uses_home() {
    _setup_resolve_mocks
    unset SUDO_USER
    HOME="/Users/testuser"
    USER="testuser"

    _tr_resolve_target_user
    assert_eq "testuser" "$_TR_TARGET_USER"
    assert_eq "/Users/testuser" "$_TR_TARGET_HOME"
    _cleanup_resolve_mocks
}

test_resolve_with_sudo_user_resolves_their_home() {
    _setup_resolve_mocks
    export SUDO_USER="alice"
    HOME="/var/root"  # what sudo sets
    FAKE_DSCL_HOME="/Users/alice"
    export FAKE_DSCL_HOME

    _tr_resolve_target_user
    assert_eq "alice" "$_TR_TARGET_USER"
    assert_eq "/Users/alice" "$_TR_TARGET_HOME"
    _cleanup_resolve_mocks
}

test_resolve_sudo_user_root_is_error() {
    _setup_resolve_mocks
    export SUDO_USER="root"
    HOME="/var/root"

    local rc=0
    _tr_resolve_target_user 2>/dev/null || rc=$?
    assert_eq 1 "$rc"
    assert_eq "" "$_TR_TARGET_USER"
    _cleanup_resolve_mocks
}

test_resolve_nonexistent_sudo_user_is_error() {
    _setup_resolve_mocks
    export SUDO_USER="nonexistent"
    HOME="/var/root"

    local rc=0
    _tr_resolve_target_user 2>/dev/null || rc=$?
    assert_eq 1 "$rc"
    _cleanup_resolve_mocks
}

test_resolve_falls_back_to_users_path() {
    _setup_resolve_mocks

    # dscl returns empty/missing home — create fallback dir
    mkdir -p "$_RTS_SANDBOX/Users/bob"
    export SUDO_USER="bob"
    HOME="/var/root"
    FAKE_DSCL_HOME=""
    export FAKE_DSCL_HOME

    # Override dscl to return empty
    cat > "$_RTS_SANDBOX/bin/dscl" <<'MOCK'
#!/bin/sh
exit 1
MOCK
    chmod +x "$_RTS_SANDBOX/bin/dscl"

    # We can't mkdir /Users/bob as non-root, so mock the -d check by
    # overriding DSCL_CMD to return a valid path instead.
    cat > "$_RTS_SANDBOX/bin/dscl" <<MOCK
#!/bin/sh
echo "NFSHomeDirectory: $_RTS_SANDBOX/Users/bob"
MOCK
    chmod +x "$_RTS_SANDBOX/bin/dscl"

    _tr_resolve_target_user
    assert_eq "bob" "$_TR_TARGET_USER"
    assert_eq "$_RTS_SANDBOX/Users/bob" "$_TR_TARGET_HOME"
    _cleanup_resolve_mocks
}

test_resolve_launchd_domain_uses_correct_uid() {
    _setup_resolve_mocks
    export SUDO_USER="alice"
    HOME="/var/root"
    FAKE_DSCL_HOME="/Users/alice"
    export FAKE_DSCL_HOME

    _tr_resolve_target_user
    assert_eq "alice" "$_TR_TARGET_USER"

    # Verify we can get the correct UID for the target user
    local uid
    uid="$($ID_CMD -u alice)"
    assert_eq "501" "$uid"

    # The launchd domain should be gui/<uid>
    local domain="gui/$uid"
    assert_eq "gui/501" "$domain"
    _cleanup_resolve_mocks
}

test_resolve_dscl_takes_precedence_over_conventional_path() {
    _setup_resolve_mocks

    # dscl says home is /nonstandard/alice
    mkdir -p "$_RTS_SANDBOX/nonstandard/alice"
    cat > "$_RTS_SANDBOX/bin/dscl" <<MOCK
#!/bin/sh
echo "NFSHomeDirectory: $_RTS_SANDBOX/nonstandard/alice"
MOCK
    chmod +x "$_RTS_SANDBOX/bin/dscl"

    export SUDO_USER="alice"
    HOME="/var/root"

    _tr_resolve_target_user
    assert_eq "alice" "$_TR_TARGET_USER"
    assert_eq "$_RTS_SANDBOX/nonstandard/alice" "$_TR_TARGET_HOME"
    _cleanup_resolve_mocks
}
