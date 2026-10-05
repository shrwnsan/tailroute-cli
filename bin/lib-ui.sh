#!/usr/bin/env bash
# lib-ui.sh — Paint-only presentation helpers for tailroute CLI output
#
# Design: a TTY-aware color gate plus four one-line printers (ui_ok, ui_warn,
# ui_dim, ui_url). Every glyph carries redundant, non-color meaning — the ✓
# mark, the WARN: token, dimming of hint lines, underlining of URLs — so text
# stays fully readable when SGR codes are stripped: glyphs are retained and
# only the escape sequences disappear. ANSI output never reaches pipes or log
# files because the gate defaults to "is the target stream a TTY?", and
# TAILROUTE_COLOR / NO_COLOR / CLICOLOR_FORCE / FORCE_COLOR / TERM=dumb give
# users and scripts explicit control.
#
# Bash 3.2 compatible: LaunchAgents resolve `env bash` to /bin/bash under
# launchd. No mapfile, no declare -A, no ${var,,}.

# Guard: prevent re-sourcing to avoid readonly variable conflicts
if [[ "${_UI_SOURCED:-0}" == "1" ]]; then
    return 0
fi
readonly _UI_SOURCED=1

set -euo pipefail

# The gate is evaluated per call, never cached: per-call env prefixes
# (e.g. `NO_COLOR=1 ui_ok …`) then apply to exactly that call, and a decision
# made for one stream can never leak into another context.

# SGR sequences (ANSI-C quoting is bash 2.0+; safe for bash 3.2)
readonly _UI_SGR_GREEN=$'\033[32m'
readonly _UI_SGR_YELLOW=$'\033[33m'
readonly _UI_SGR_DIM=$'\033[2m'
readonly _UI_SGR_UNDERLINE=$'\033[4m'
readonly _UI_SGR_RESET=$'\033[0m'

# -----------------------------------------------------------------------------
# _ui_color_enabled — Decide whether the given stream may carry SGR codes
# -----------------------------------------------------------------------------
# Args:
#   $1 - stream file descriptor to test (1 for stdout helpers, 2 for stderr)
# Precedence (first match wins):
#   1. TAILROUTE_COLOR=never → off; TAILROUTE_COLOR=always → on;
#      auto/unset (or any other value) → keep deciding
#   2. NO_COLOR set and non-empty → off (https://no-color.org)
#   3. CLICOLOR_FORCE or FORCE_COLOR non-empty → on (bypasses the TTY check)
#   4. TERM=dumb → off
#   5. Default: on iff the target stream is a TTY
# -----------------------------------------------------------------------------
_ui_color_enabled() {
    local fd="$1"
    case "${TAILROUTE_COLOR:-auto}" in
        never)  return 1 ;;
        always) return 0 ;;
    esac
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi
    if [[ -n "${CLICOLOR_FORCE:-}" || -n "${FORCE_COLOR:-}" ]]; then
        return 0
    fi
    if [[ "${TERM:-}" == "dumb" ]]; then
        return 1
    fi
    [[ -t "$fd" ]]
}

# Resolve the stdout gate for this call.
_ui_gate_out() {
    _ui_color_enabled 1
}

# Resolve the stderr gate for this call.
_ui_gate_err() {
    _ui_color_enabled 2
}

# -----------------------------------------------------------------------------
# ui_ok — Print a success line to stdout
# -----------------------------------------------------------------------------
# Message goes through "%s" only: its content is never interpreted as a
# format string. With color off the output is byte-identical plain text and
# the ✓ glyph is retained.
# -----------------------------------------------------------------------------
ui_ok() {
    if _ui_gate_out; then
        printf '%s✓%s %s\n' "$_UI_SGR_GREEN" "$_UI_SGR_RESET" "$*"
    else
        printf '✓ %s\n' "$*"
    fi
}

# -----------------------------------------------------------------------------
# ui_warn — Print a warning line to stderr
# -----------------------------------------------------------------------------
# The WARN: token is yellow; the message body stays uncolored so it survives
# copy/paste cleanly. This is the single warning spelling for CLI output.
# -----------------------------------------------------------------------------
ui_warn() {
    if _ui_gate_err; then
        printf '%sWARN:%s %s\n' "$_UI_SGR_YELLOW" "$_UI_SGR_RESET" "$*" >&2
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

# -----------------------------------------------------------------------------
# ui_dim — Print a hint line to stdout, dimmed as a whole when color is on
# -----------------------------------------------------------------------------
ui_dim() {
    if _ui_gate_out; then
        printf '%s%s%s\n' "$_UI_SGR_DIM" "$*" "$_UI_SGR_RESET"
    else
        printf '%s\n' "$*"
    fi
}

# -----------------------------------------------------------------------------
# ui_url — Print a URL to stdout, underlined when color is on
# -----------------------------------------------------------------------------
# Underline (SGR 4) only, deliberately no color: links stay theme-safe.
# -----------------------------------------------------------------------------
ui_url() {
    if _ui_gate_out; then
        printf '%s%s%s\n' "$_UI_SGR_UNDERLINE" "$*" "$_UI_SGR_RESET"
    else
        printf '%s\n' "$*"
    fi
}
