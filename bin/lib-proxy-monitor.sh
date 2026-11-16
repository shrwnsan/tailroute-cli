#!/usr/bin/env bash
# lib-proxy-monitor.sh — Health monitoring and auto-restart for tailroute-proxy
#
# The proxy is a user-context process with only a PID file keeping its
# identity; before this lib, a crash left tunnel access silently broken
# until someone ran `proxy status` by hand. The daemon (root) runs a poll
# that keeps a *running* proxy alive: 30s checks, restart with exponential
# backoff 5s→10s→20s, and a hard stop at 3 restarts in any 60s window.
#
# Fail-safe contract (T-001, parameters ratified by the owner 2026-11-13):
#   - Never auto-starts a proxy the user did not start. A missing PID file
#     means "stopped on purpose" (do_proxy_stop removes it) — hands off.
#   - A present-but-dead PID means the process crashed — restart, with
#     backoff and the restart-loop guard.
#   - The guard DISABLES the monitor and surfaces the state; it never
#     deletes the proxy binary (a stopped proxy is recoverable; a deleted
#     user binary is not).
#   - Manual `tailroute proxy start` clears the disabled state.
#
# The monitor does not take the reconcile lock: it owns the proxy, the
# reconcile owns DNS state, and neither should stall the other.

# Guard: prevent re-sourcing
[[ -n "${_TAILROUTE_LIB_PROXY_MONITOR_SOURCED:-}" ]] && return 0
_TAILROUTE_LIB_PROXY_MONITOR_SOURCED=1

# shellcheck source=lib-log.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-log.sh"

# Paths to system commands (absolute for security; overridable in tests)
PM_SUDO_CMD="${PM_SUDO_CMD:-/usr/bin/sudo}"
PM_NC_CMD="${PM_NC_CMD:-/usr/bin/nc}"
PM_CHOWN_CMD="${PM_CHOWN_CMD:-/usr/sbin/chown}"
PM_KILL_CMD="${PM_KILL_CMD:-/bin/kill}"
PM_CAT_CMD="${PM_CAT_CMD:-/bin/cat}"
PM_SLEEP_CMD="${PM_SLEEP_CMD:=/bin/sleep}"

# Tunables (defaults are the ratified parameters)
PROXY_MONITOR_SECONDS="${PROXY_MONITOR_SECONDS:-30}"
PROXY_MONITOR_MAX_RESTARTS="${PROXY_MONITOR_MAX_RESTARTS:-3}"
PROXY_MONITOR_WINDOW="${PROXY_MONITOR_WINDOW:-60}"
PROXY_MONITOR_BACKOFF_BASE="${PROXY_MONITOR_BACKOFF_BASE:-5}"   # 5s → 10s → 20s
PROXY_MONITOR_READY_TRIES="${PROXY_MONITOR_READY_TRIES:-15}"    # 15 × 1s port wait
PROXY_MONITOR_PID=""    # PID of the monitor poll subshell (start/stop below)

# Monitor state (in-memory, inside the monitor poll subshell)
_PM_STATE=""            # "" | "running" | "restarting" | "disabled"
_PM_CRASHES=()          # epochs of crashes inside the window
_PM_NEXT_ATTEMPT=0      # epoch of the next allowed restart
_PM_PID=""              # PID written by the last restart

# =============================================================================
# _pm_now — Monotonic-ish clock for windows and backoff
# =============================================================================
# SECONDS is the tick source (bash builtin, immune to wall-clock steps the
# way Date.now is not). Split out so tests can drive time deterministically.
# =============================================================================
_pm_now() {
    printf '%s' "$SECONDS"
}

# =============================================================================
# _pm_state_file / _pm_pid_file — Target-user paths for monitor artifacts
# =============================================================================
# The proxy (and its PID file) live in the console user's home; the daemon
# runs as root with root's $HOME, so every path goes through the target-user
# resolution. rc 2 from _tr_resolve_target_user (no identifiable console
# user) means there is nobody to monitor for — hands off.
# =============================================================================
_pm_resolve_target() {
    _tr_resolve_target_user || return 1
    [[ -n "$_TR_TARGET_HOME" ]] || return 1
    return 0
}

_pm_base_dir() {
    printf '%s/.tailroute' "$_TR_TARGET_HOME"
}

_pm_pid_file() {
    printf '%s/proxy.pid' "$(_pm_base_dir)"
}

_pm_state_file() {
    printf '%s/proxy-monitor.state' "$(_pm_base_dir)"
}

_pm_log_file() {
    printf '%s/proxy.log' "$(_pm_base_dir)"
}

# =============================================================================
# _pm_write_state — Persist monitor state for the user-facing CLI to read
# =============================================================================
# Format (one key=value per line, parsed by do_proxy_status):
#   state=running|restarting|disabled
#   next_attempt=<epoch or 0>
#   updated=<epoch>
# Root writes it, then hands ownership to the user so `proxy start` (running
# as the user) can delete it to re-arm a disabled monitor.
# =============================================================================
_pm_write_state() {
    local file
    file=$(_pm_state_file)
    {
        printf 'state=%s\n' "${_PM_STATE:-running}"
        printf 'next_attempt=%s\n' "$_PM_NEXT_ATTEMPT"
        printf 'updated=%s\n' "$(_pm_now)"
    } > "$file" 2>/dev/null || {
        log_debug "proxy-monitor: cannot write state file $file"
        return 0
    }
    if [[ "$(id -u)" -eq 0 && -n "${_TR_TARGET_USER:-}" ]]; then
        "$PM_CHOWN_CMD" "${_TR_TARGET_USER}" "$file" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# proxy_monitor_reset — Clear monitor state (manual proxy start re-arms)
# =============================================================================
proxy_monitor_reset() {
    _PM_STATE=""
    _PM_CRASHES=()
    _PM_NEXT_ATTEMPT=0
    _PM_PID=""
    if declare -F _tr_resolve_target_user >/dev/null &&
        _pm_resolve_target; then
        rm -f "$(_pm_state_file)" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# _pm_proxy_bin — Resolve the proxy binary (daemon-safe)
# =============================================================================
# resolve_proxy_bin lives in tailroute.sh; the daemon has it by the time the
# monitor runs. The test harness and any future caller without it fall back
# to the managed install path.
# =============================================================================
_pm_proxy_bin() {
    if declare -F resolve_proxy_bin >/dev/null; then
        resolve_proxy_bin && return 0
    fi
    local fallback
    fallback="$(_pm_base_dir)/bin/tailroute-proxy"
    [[ -x "$fallback" ]] || return 1
    printf '%s' "$fallback"
}

# =============================================================================
# _pm_port_open — SOCKS port probe (mock seam for tests)
# =============================================================================
_pm_port_open() {
    "$PM_NC_CMD" -z 127.0.0.1 1055 >/dev/null 2>&1
}

# =============================================================================
# _pm_spawn_proxy — Restart the proxy as the target user (mock seam)
# =============================================================================
# Root spawning a user-context process: sudo drops privilege, env HOME points
# tsnet at the user's state dir (identity persists there — first auth is the
# only run that needs TS_AUTHKEY), output appends to the user's proxy log.
# The PID file is written here, so the next tick's liveness check has the
# same discriminator the user CLI established (present PID = ours to watch).
# Detached with nohup: the daemon's EXIT trap kills only tracked PIDs, and
# the proxy must outlive daemon restarts exactly like a CLI-started one.
# =============================================================================
_pm_spawn_proxy() {
    local user="$1" home="$2" bin="$3" pid_file log_file pid
    pid_file=$(_pm_pid_file)
    log_file=$(_pm_log_file)

    if [[ "$(id -u)" -eq 0 ]]; then
        "$PM_SUDO_CMD" -u "$user" env HOME="$home" "$bin" \
            --socks-addr "${PROXY_SOCKS_ADDR:-127.0.0.1:1055}" \
            --state-dir "$home/.tailroute/proxy-state" \
            >>"$log_file" 2>&1 &
    else
        env HOME="$home" "$bin" \
            --socks-addr "${PROXY_SOCKS_ADDR:-127.0.0.1:1055}" \
            --state-dir "$home/.tailroute/proxy-state" \
            >>"$log_file" 2>&1 &
    fi
    pid=$!
    disown "$pid" 2>/dev/null || true
    printf '%s\n' "$pid" > "$pid_file" 2>/dev/null || true
    _PM_PID="$pid"
    return 0
}

# =============================================================================
# _pm_wait_ready — Wait for the SOCKS port after a restart (mock seam)
# =============================================================================
_pm_wait_ready() {
    local i
    for ((i = 0; i < PROXY_MONITOR_READY_TRIES; i++)); do
        if _pm_port_open; then
            return 0
        fi
        "$PM_SLEEP_CMD" 1
    done
    return 1
}

# =============================================================================
# proxy_monitor_tick — One health check; the whole monitor decision table
# =============================================================================
# Returns:
#   0 - Always (monitoring must never break the poll that hosts it)
# =============================================================================
proxy_monitor_tick() {
    _pm_resolve_target || return 0

    local pid_file pid
    pid_file=$(_pm_pid_file)
    pid=$("$PM_CAT_CMD" "$pid_file" 2>/dev/null || true)
    case "$pid" in
        "" | *[!0-9]*) pid="" ;;
    esac

    # Live proxy: healthy, reset the crash window after sustained uptime.
    if [[ -n "$pid" ]] && "$PM_KILL_CMD" -0 "$pid" 2>/dev/null; then
        if [[ "$_PM_STATE" != "running" ]]; then
            log_info "proxy-monitor: proxy is up (pid $pid)"
        fi
        _PM_STATE="running"
        if ((${#_PM_CRASHES[@]} > 0)); then
            local now last
            now=$(_pm_now)
            last=${_PM_CRASHES[${#_PM_CRASHES[@]} - 1]}
            if ((now - last > PROXY_MONITOR_WINDOW)); then
                _PM_CRASHES=()
            fi
        fi
        _pm_write_state
        return 0
    fi

    # No PID at all: either stopped on purpose (do_proxy_stop removes the
    # file — hands off, the monitor never starts a proxy the user did not
    # start) or a restart just landed and its PID-file write failed. In the
    # second case, heal the PID file from the spawn we know about.
    if [[ -z "$pid" ]]; then
        if [[ "$_PM_STATE" == "restarting" && -n "$_PM_PID" ]] &&
            "$PM_KILL_CMD" -0 "$_PM_PID" 2>/dev/null; then
            printf '%s\n' "$_PM_PID" > "$pid_file" 2>/dev/null || true
            _pm_write_state
            return 0
        fi
        if [[ -n "$_PM_STATE" ]]; then
            log_info "proxy-monitor: proxy stopped by user; disengaging"
        fi
        _PM_STATE=""
        _PM_CRASHES=()
        _PM_NEXT_ATTEMPT=0
        _PM_PID=""
        rm -f "$(_pm_state_file)" 2>/dev/null || true
        return 0
    fi

    # PID present but dead: a crash. Previous-healthy is implied by the PID
    # file existing (only `proxy start` and this monitor write it).
    local now
    now=$(_pm_now)

    # Restart-loop guard: prune the window, then count.
    local kept=() ts
    for ts in "${_PM_CRASHES[@]}"; do
        ((now - ts <= PROXY_MONITOR_WINDOW)) && kept+=("$ts")
    done
    _PM_CRASHES=("${kept[@]}")

    if ((${#_PM_CRASHES[@]} >= PROXY_MONITOR_MAX_RESTARTS)); then
        if [[ "$_PM_STATE" != "disabled" ]]; then
            log_error "proxy-monitor: ${#_PM_CRASHES[@]} restarts in ${PROXY_MONITOR_WINDOW}s — disabling auto-restart; run 'tailroute proxy start' to re-arm"
            _PM_STATE="disabled"
            _pm_write_state
        fi
        return 0
    fi

    # Backoff gate: 5s → 10s → 20s as crashes accumulate in the window.
    local delay
    delay=$((PROXY_MONITOR_BACKOFF_BASE * (1 << ${#_PM_CRASHES[@]})))
    ((delay > 20)) && delay=20
    if ((now < _PM_NEXT_ATTEMPT)); then
        _PM_STATE="restarting"
        _pm_write_state
        return 0
    fi

    _PM_CRASHES+=("$now")
    _PM_NEXT_ATTEMPT=$((now + delay))
    _PM_STATE="restarting"
    _pm_write_state

    local bin
    if ! bin=$(_pm_proxy_bin); then
        log_warn "proxy-monitor: proxy crashed but no binary found; run 'tailroute proxy install'"
        return 0
    fi

    log_warn "proxy-monitor: proxy crashed (pid ${pid:-unknown}); restarting in ${delay}s window"
    _pm_spawn_proxy "$_TR_TARGET_USER" "$_TR_TARGET_HOME" "$bin" ||
        log_error "proxy-monitor: restart spawn failed"

    if _pm_wait_ready; then
        log_info "proxy-monitor: proxy restarted (pid ${_PM_PID:-unknown}), port open"
    else
        log_warn "proxy-monitor: proxy restarted (pid ${_PM_PID:-unknown}) but port not open yet; check $(_pm_log_file)"
    fi
    return 0
}

# =============================================================================
# proxy_monitor_state — Readable one-liner for status surfaces
# =============================================================================
# Prints: healthy | restarting | disabled (…) | off
# Reads the persisted state file so the *user* CLI (separate process from
# the root daemon's monitor subshell) sees the same truth. No countdown:
# the backoff clock is the daemon's SECONDS, meaningless to another process.
# =============================================================================
proxy_monitor_state() {
    local state_file="$1" state="off" line key val
    [[ -f "$state_file" ]] || { printf 'off'; return 0; }
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            state) state="$val" ;;
        esac
    done < "$state_file"
    case "$state" in
        running) printf 'healthy' ;;
        restarting) printf 'restarting (auto-restart in progress)' ;;
        disabled) printf 'disabled (restart loop; run ''"''tailroute proxy start''"'' to re-arm)' ;;
        *) printf '%s' "$state" ;;
    esac
    return 0
}

# =============================================================================
# start_proxy_monitor_poll — Background monitor poll (mirrors start_poll)
# =============================================================================
# Same trap/wait structure as the reconcile poll so a TERM during a tick
# behaves identically (flag raised, in-flight tick completes, exit). Own
# PID in PROXY_MONITOR_PID; cleanup kills both polls.
# =============================================================================
stop_proxy_monitor_poll() {
    if [[ -n "${PROXY_MONITOR_PID:-}" ]] && "$PM_KILL_CMD" -0 "$PROXY_MONITOR_PID" 2>/dev/null; then
        log_debug "Killing proxy monitor poll: $PROXY_MONITOR_PID"
        "$PM_KILL_CMD" "$PROXY_MONITOR_PID" 2>/dev/null || true
        wait "$PROXY_MONITOR_PID" 2>/dev/null || true
    fi
    PROXY_MONITOR_PID=""
    return 0
}

start_proxy_monitor_poll() {
    log_debug "Starting proxy monitor poll (${PROXY_MONITOR_SECONDS}s interval)"
    (
        _PM_STOP=0
        _PM_SLEEP_PID=""
        # shellcheck disable=SC2329  # invoked indirectly via the trap below
        _pm_poll_halt() {
            _PM_STOP=1
            if [[ -n "$_PM_SLEEP_PID" ]]; then
                "$PM_KILL_CMD" "$_PM_SLEEP_PID" 2>/dev/null || true
            fi
        }
        trap _pm_poll_halt TERM INT

        while ((_PM_STOP == 0)); do
            "$PM_SLEEP_CMD" "$PROXY_MONITOR_SECONDS" &
            _PM_SLEEP_PID=$!
            ((_PM_STOP == 1)) && "$PM_KILL_CMD" "$_PM_SLEEP_PID" 2>/dev/null || true
            wait "$_PM_SLEEP_PID" 2>/dev/null || true
            _PM_SLEEP_PID=""
            ((_PM_STOP == 1)) && break

            proxy_monitor_tick || log_warn "proxy-monitor: tick failed (continuing)"
        done

        exit 0
    ) &

    PROXY_MONITOR_PID=$!
    log_debug "Proxy monitor poll started: PID $PROXY_MONITOR_PID"
    return 0
}
