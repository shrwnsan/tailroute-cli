#!/usr/bin/env bash
# test-lib-ui.sh — Tests for lib-ui.sh (presentation helpers)

# Source the library under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bin/lib-ui.sh"

# Escape byte used in "must not contain SGR" assertions
ESC=$'\033'

# =============================================================================
# ui_ok — color gate
# =============================================================================

test_ui_ok_plain_with_no_color() {
    local out
    out="$(NO_COLOR=1 ui_ok "daemon running")"
    # Byte-identical plain text: glyph retained, no escape byte anywhere
    assert_eq "✓ daemon running" "$out"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "NO_COLOR output must not contain an escape byte: $out"
    fi
}

test_ui_ok_colored_with_clicolor_force() {
    local out
    out="$(CLICOLOR_FORCE=1 ui_ok "daemon running")"
    assert_contains "$(printf '\033[32m✓\033[0m daemon running')" "$out"
    assert_contains "$(printf '\033[0m')" "$out"
}

test_ui_ok_no_color_with_term_dumb() {
    local out
    out="$(unset CLICOLOR_FORCE FORCE_COLOR; TERM=dumb ui_ok "daemon running")"
    assert_eq "✓ daemon running" "$out"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "TERM=dumb output must not contain an escape byte: $out"
    fi
}

test_ui_color_never_overrides_clicolor_force() {
    local out
    out="$(TAILROUTE_COLOR=never CLICOLOR_FORCE=1 ui_ok "daemon running")"
    assert_eq "✓ daemon running" "$out"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "TAILROUTE_COLOR=never must win over CLICOLOR_FORCE: $out"
    fi
}

test_ui_color_always_forces_color_when_piped() {
    local out
    out="$(TAILROUTE_COLOR=always ui_ok "daemon running")"
    assert_contains "$(printf '\033[32m')" "$out"
}

test_ui_empty_no_color_does_not_disable_but_nonempty_does() {
    # no-color.org semantics: NO_COLOR must be set AND non-empty to disable
    local out
    out="$(NO_COLOR= CLICOLOR_FORCE=1 ui_ok "msg")"
    assert_contains "$(printf '\033[32m')" "$out"
    out="$(NO_COLOR=1 CLICOLOR_FORCE=1 ui_ok "msg")"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "non-empty NO_COLOR must disable forced color: $out"
    fi
}

test_ui_force_color_env_forces_color() {
    local out
    out="$(unset CLICOLOR_FORCE; FORCE_COLOR=1 ui_ok "msg")"
    assert_contains "$(printf '\033[32m')" "$out"
}

test_ui_gate_env_overrides_apply_per_call() {
    # The gate is evaluated per call, so a forced decision on one call must
    # not leak into a later unforced call (and vice versa).
    local first second
    first="$(CLICOLOR_FORCE=1 ui_ok "a")"
    second="$(ui_ok "b")"
    assert_contains "$(printf '\033[32m')" "$first"
    assert_eq "✓ b" "$second"
}

# =============================================================================
# ui_ok — message handling
# =============================================================================

test_ui_ok_multi_word_message() {
    local out
    out="$(NO_COLOR=1 ui_ok "multi" "word" "message")"
    assert_eq "✓ multi word message" "$out"
}

test_ui_ok_message_not_format_interpreted() {
    local out
    out="$(NO_COLOR=1 ui_ok "100% of %s tokens \n")"
    assert_eq "✓ 100% of %s tokens \\n" "$out"
}

# =============================================================================
# ui_warn — stream and marker
# =============================================================================

test_ui_warn_writes_to_stderr() {
    local out err
    out="$(NO_COLOR=1 ui_warn "something is off" 2>/dev/null)"
    err="$(NO_COLOR=1 ui_warn "something is off" 2>&1 >/dev/null)"
    assert_eq "" "$out"
    assert_eq "WARN: something is off" "$err"
}

test_ui_warn_plain_has_no_escape_byte() {
    local err
    err="$(NO_COLOR=1 ui_warn "something is off" 2>&1 >/dev/null)"
    assert_eq "WARN: something is off" "$err"
    if [[ "$err" == *"$ESC"* ]]; then
        _assert_fail "NO_COLOR stderr must not contain an escape byte: $err"
    fi
}

test_ui_warn_colored_token_only_on_stderr() {
    local err
    err="$(CLICOLOR_FORCE=1 ui_warn "body stays plain" 2>&1 >/dev/null)"
    assert_contains "$(printf '\033[33mWARN:\033[0m body stays plain')" "$err"
}

test_ui_warn_multi_word_message() {
    local err
    err="$(NO_COLOR=1 ui_warn "a" "b" "c" 2>&1 >/dev/null)"
    assert_eq "WARN: a b c" "$err"
}

# =============================================================================
# ui_dim — hint lines
# =============================================================================

test_ui_dim_plain_fallback() {
    local out
    out="$(NO_COLOR=1 ui_dim "  Check status: tailroute status")"
    assert_eq "  Check status: tailroute status" "$out"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "NO_COLOR dim output must not contain an escape byte: $out"
    fi
}

test_ui_dim_whole_line_colored_when_forced() {
    local out
    out="$(CLICOLOR_FORCE=1 ui_dim "  Check status: tailroute status")"
    assert_contains "$(printf '\033[2m')" "$out"
    assert_contains "$(printf '\033[0m')" "$out"
}

# =============================================================================
# ui_url — underline only, no color
# =============================================================================

test_ui_url_plain_fallback() {
    local out
    out="$(NO_COLOR=1 ui_url "https://prime.tailnet.ts.net:8443")"
    assert_eq "https://prime.tailnet.ts.net:8443" "$out"
    if [[ "$out" == *"$ESC"* ]]; then
        _assert_fail "NO_COLOR url output must not contain an escape byte: $out"
    fi
}

test_ui_url_underline_without_color_codes() {
    local out
    out="$(CLICOLOR_FORCE=1 ui_url "https://prime.tailnet.ts.net:8443")"
    assert_contains "$(printf '\033[4m')" "$out"
    assert_contains "$(printf '\033[0m')" "$out"
    # Theme-safe: SGR 4 only — no green/yellow/dim codes may appear
    if [[ "$out" == *$(printf '\033[32m')* || "$out" == *$(printf '\033[33m')* || "$out" == *$(printf '\033[2m')* ]]; then
        _assert_fail "ui_url must underline only (no color SGR): $out"
    fi
}

# =============================================================================
# Gate robustness
# =============================================================================

test_ui_helpers_never_fail_under_strict_mode() {
    local rc=0
    (
        set -euo pipefail
        NO_COLOR=1 ui_ok "strict" >/dev/null
        NO_COLOR=1 ui_warn "strict" 2>/dev/null
        NO_COLOR=1 ui_dim "strict" >/dev/null
        NO_COLOR=1 ui_url "https://x.test" >/dev/null
    ) || rc=$?
    assert_eq 0 "$rc" "ui_* helpers must be safe under set -euo pipefail"
}

test_ui_helpers_re_sourcing_is_gated() {
    local rc=0
    source "$SCRIPT_DIR/../bin/lib-ui.sh" || rc=$?
    assert_eq 0 "$rc" "re-sourcing lib-ui.sh must be a no-op, not an error"
}
