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
    [ -n "${1:-}" ] || { echo "${FAKE_EUID:-999}"; exit 0; }
    case "${1:-}" in
        alice)   echo "501" ;;
        bob)     echo "502" ;;
        root|toor) echo "0" ;;
        *)       echo "999" ;;
    esac
else
    echo "uid=0(root)"
fi
MOCK

    # stat -f %Su /dev/console: FAKE_CONSOLE_USER names the console owner
    cat > "$_RTS_SANDBOX/bin/stat" <<'MOCK'
#!/bin/sh
echo "${FAKE_CONSOLE_USER:-}"
MOCK

    # launchctl print gui/<uid>: succeeds only when the user has a GUI session
    cat > "$_RTS_SANDBOX/bin/launchctl" <<'MOCK'
#!/bin/sh
[ "${FAKE_GUI_SESSION:-yes}" = "yes" ]
MOCK

    chmod +x "$_RTS_SANDBOX/bin/"*

    export DSCL_CMD="$_RTS_SANDBOX/bin/dscl"
    export ID_CMD="$_RTS_SANDBOX/bin/id"
    export STAT_CMD="$_RTS_SANDBOX/bin/stat"
    export LAUNCHCTL_CMD="$_RTS_SANDBOX/bin/launchctl"
    unset FAKE_EUID FAKE_CONSOLE_USER FAKE_GUI_SESSION

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

# =============================================================================
# Console-user fallback, uid + GUI-session validation, other-user report (T-434)
# =============================================================================

test_t434_root_without_sudo_falls_back_to_the_console_user() {
    _setup_resolve_mocks
    unset SUDO_USER
    HOME="/var/root"
    FAKE_EUID=0; FAKE_CONSOLE_USER="alice"; FAKE_DSCL_HOME="/Users/alice"
    export FAKE_EUID FAKE_CONSOLE_USER FAKE_DSCL_HOME

    local rc=0
    _tr_resolve_target_user || rc=$?
    assert_eq 0 "$rc"
    assert_eq "alice" "$_TR_TARGET_USER"
    assert_eq "/Users/alice" "$_TR_TARGET_HOME"
    assert_eq "501" "$_TR_TARGET_UID"
    _cleanup_resolve_mocks
}

test_t434_root_without_sudo_and_no_console_user_has_no_target() {
    _setup_resolve_mocks
    unset SUDO_USER
    HOME="/var/root"
    local who
    for who in "" root loginwindow _mbsetupuser; do
        FAKE_EUID=0; FAKE_CONSOLE_USER="$who"
        export FAKE_EUID FAKE_CONSOLE_USER
        local rc=0
        _tr_resolve_target_user 2>/dev/null || rc=$?
        assert_eq 2 "$rc" "console user '$who' is not an unambiguous person"
        assert_eq "" "$_TR_TARGET_USER" "must not guess a user for '$who'"
    done
    _cleanup_resolve_mocks
}

test_t434_sudo_user_wins_over_the_console_user() {
    _setup_resolve_mocks
    export SUDO_USER="bob"
    HOME="/var/root"
    FAKE_EUID=0; FAKE_CONSOLE_USER="alice"; FAKE_DSCL_HOME="/Users/bob"
    export FAKE_EUID FAKE_CONSOLE_USER FAKE_DSCL_HOME

    _tr_resolve_target_user
    assert_eq "bob" "$_TR_TARGET_USER"
    assert_eq "502" "$_TR_TARGET_UID"
    _cleanup_resolve_mocks
}

test_t434_gui_session_is_reported_per_target() {
    _setup_resolve_mocks
    export SUDO_USER="alice"
    HOME="/var/root"
    FAKE_DSCL_HOME="/Users/alice"; export FAKE_DSCL_HOME

    FAKE_GUI_SESSION=yes; export FAKE_GUI_SESSION
    _tr_resolve_target_user
    assert_eq "yes" "$_TR_TARGET_GUI"

    FAKE_GUI_SESSION=no; export FAKE_GUI_SESSION
    local rc=0
    _tr_resolve_target_user || rc=$?
    assert_eq 0 "$rc" "a user with no GUI session is still a valid target"
    assert_eq "no" "$_TR_TARGET_GUI"
    _cleanup_resolve_mocks
}

test_t434_uid_zero_target_is_rejected() {
    _setup_resolve_mocks
    export SUDO_USER="toor"
    HOME="/var/root"
    FAKE_DSCL_HOME="/var/root"; export FAKE_DSCL_HOME

    local rc=0
    _tr_resolve_target_user 2>/dev/null || rc=$?
    assert_eq 1 "$rc"
    assert_eq "" "$_TR_TARGET_USER"
    _cleanup_resolve_mocks
}

test_t434_unsafe_user_names_are_rejected() {
    _setup_resolve_mocks
    HOME="/var/root"
    local bad
    for bad in '../etc' 'a b' 'x;y' '-flag' ''; do
        [ -n "$bad" ] || continue
        export SUDO_USER="$bad"
        local rc=0
        _tr_resolve_target_user 2>/dev/null || rc=$?
        assert_eq 1 "$rc" "user name '$bad' must be rejected"
    done
    _cleanup_resolve_mocks
}

test_t434_other_user_registries_are_reported() {
    _setup_resolve_mocks
    local users="$_RTS_SANDBOX/Users"
    mkdir -p "$users/alice/.config/tailroute" "$users/bob/.config/tailroute" "$users/carol" "$users/Shared"
    printf '{"version":2,"tunnels":[{"peer":"a1"}]}\n' > "$users/alice/.config/tailroute/tunnels.json"
    printf '{"version":2,"tunnels":[{"peer":"b1"},{"peer":"b2"}]}\n' > "$users/bob/.config/tailroute/tunnels.json"
    export TR_USERS_DIR="$users"

    local out
    out="$(_tr_report_other_user_registries "$users/alice")"
    assert_contains "bob: 2 tunnels" "$out"
    case "$out" in *alice*) _assert_fail "the target user's own registry must not be reported: $out" ;; esac
    case "$out" in *carol*|*Shared*) _assert_fail "users without a registry must not be reported: $out" ;; esac
    assert_contains "tailroute tunnel remove-all" "$out"
    unset TR_USERS_DIR
    _cleanup_resolve_mocks
}

test_t434_no_other_user_registries_prints_nothing() {
    _setup_resolve_mocks
    local users="$_RTS_SANDBOX/Users"
    mkdir -p "$users/alice/.config/tailroute" "$users/carol"
    export TR_USERS_DIR="$users"
    assert_eq "" "$(_tr_report_other_user_registries "$users/alice")"
    unset TR_USERS_DIR
    _cleanup_resolve_mocks
}

test_t434_repeat_remove_all_is_a_clean_noop() {
    _setup_resolve_mocks
    local cfg="$_RTS_SANDBOX/cfg"
    mkdir -p "$cfg"
    TUNNEL_CONFIG_DIR="$cfg" TUNNEL_REGISTRY="$cfg/tunnels.json" TUNNEL_JOURNAL_PATH="$cfg/tunnels.journal" \
        TUNNEL_LOG_DIR="$cfg/logs" tunnel_remove_all >/dev/null 2>&1 || _assert_fail "first remove-all on an empty registry failed"
    TUNNEL_CONFIG_DIR="$cfg" TUNNEL_REGISTRY="$cfg/tunnels.json" TUNNEL_JOURNAL_PATH="$cfg/tunnels.journal" \
        TUNNEL_LOG_DIR="$cfg/logs" tunnel_remove_all >/dev/null 2>&1 || _assert_fail "repeat remove-all failed"
    _cleanup_resolve_mocks
}
