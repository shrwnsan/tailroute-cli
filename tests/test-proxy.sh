#!/usr/bin/env bash
# test-proxy.sh — Proxy registry validation, binary location, and auth tests
#
# Covers issue #42:
#   - the proxy pidfile registry must be validated against reality (the pid
#     must be alive, must be a tailroute-proxy process, and must own the SOCKS
#     listener when one exists) and must self-heal on mismatch — a replaced
#     spawn left a stale pid that `proxy status` reported for days;
#   - a listener on the SOCKS port that is NOT tailroute-proxy must be
#     reported as such instead of a bare "Stopped";
#   - exactly one canonical proxy binary should exist per install (the legacy
#     /usr/local/bin placement is retired on install);
#   - `proxy auth` must surface the login URL or the NeedsLogin state instead
#     of printing "Open the URL below" with nothing under it.
#
# Everything here runs in a scratch HOME with a fixture process table — no
# live process, port, or binary is touched. mktemp always gets an explicit
# template path: bare `mktemp -d` ignores TMPDIR on macOS.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tailroute.sh bakes proxy paths from $HOME at source time, so the sandbox
# HOME must be in place before sourcing (inside each test's subshell).
_load_tailroute() {
    # shellcheck source=../bin/tailroute.sh
    source "$TEST_DIR/../bin/tailroute.sh"
}

# -----------------------------------------------------------------------------
# Fixture process table
# -----------------------------------------------------------------------------
# "Alive" fixture pids must be pids this shell may signal ($$ / $PPID);
# "dead" ones must not exist (e.g. 99999) — kill -0 stays real. Note pid 1
# is useless here: kill -0 from a non-root shell is EPERM, not success.
# ps/pgrep/lsof resolve from fixture files.

_setup_proxy_sandbox() {
    PROXY_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tailroute-proxy-test.XXXXXX")"
    export HOME="$PROXY_TEST_HOME"
    export PROXY_TEST_HOME   # fixture children record their argv/env under it
    mkdir -p "$PROXY_TEST_HOME/.tailroute/bin" "$PROXY_TEST_HOME/.tailroute/proxy-state"
    PROXY_TEST_PROC="$PROXY_TEST_HOME/proc"
    mkdir -p "$PROXY_TEST_PROC"
    _load_tailroute
    _install_proxy_mocks
}

_install_proxy_mocks() {
    # Matches the exact call shape in tailroute.sh: ps -p PID -o comm=
    ps() {
        local pid="${2:-}"
        if [[ -n "$pid" && -f "$PROXY_TEST_PROC/$pid" ]]; then
            cat "$PROXY_TEST_PROC/$pid"
            return 0
        fi
        return 1
    }
    # pgrep -f NAME — prints the fixture pid list, empty means no match
    pgrep() {
        if [[ -s "$PROXY_TEST_HOME/pgrep.out" ]]; then
            cat "$PROXY_TEST_HOME/pgrep.out"
            return 0
        fi
        return 1
    }
    # lsof -nP -iTCP:PORT -sTCP:LISTEN -t — prints fixture listener pids,
    # empty means nothing is listening
    lsof() {
        if [[ -s "$PROXY_TEST_HOME/lsof.out" ]]; then
            cat "$PROXY_TEST_HOME/lsof.out"
        fi
        return 0
    }
    # nc -z host port — port probes stay closed unless a test opens them
    nc() { return 1; }
    # readiness/stop wait loops must not actually wait
    sleep() { :; }
}

fake_comm() { printf '%s' "$2" > "$PROXY_TEST_PROC/$1"; }
fake_pgrep() {
    if [[ $# -eq 0 ]]; then : > "$PROXY_TEST_HOME/pgrep.out"
    else printf '%s\n' "$@" > "$PROXY_TEST_HOME/pgrep.out"; fi
}
fake_lsof() {
    if [[ $# -eq 0 ]]; then : > "$PROXY_TEST_HOME/lsof.out"
    else printf '%s\n' "$@" > "$PROXY_TEST_HOME/lsof.out"; fi
}

# =============================================================================
# Registry validation and self-heal (#42 defect 2)
# =============================================================================

test_missing_pidfile_resolves_live_proxy_and_writes_registry() {
    _setup_proxy_sandbox
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")" "registry written back from pgrep resolution"
}

test_registered_live_proxy_pid_is_trusted() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"
    fake_comm $$ tailroute-proxy

    assert_eq "$$" "$(get_proxy_pid)"
}

test_stale_pidfile_falls_back_to_live_proxy_and_self_heals() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"     # dead pid in the registry
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")" "registry must self-heal to the live proxy"
}

test_pidfile_pid_reused_by_foreign_process_is_rejected() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"        # alive — but it is this test shell
    fake_comm $$ bash
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)" "a reused pid must not read as the proxy"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")"
}

test_registered_proxy_displaced_from_the_socks_port_is_rejected() {
    # 2026-09-21 incident: the registry pointed at the old spawn while a
    # replaced spawn owned 1055. The listener is ground truth.
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"
    fake_comm $$ tailroute-proxy       # alive and looks right…
    fake_lsof $PPID                    # …but $PPID owns the SOCKS listener
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    assert_eq "$PPID" "$(get_proxy_pid)"
    assert_eq "$PPID" "$(cat "$PROXY_PID_FILE")"
}

test_startup_window_without_listener_still_reports_running() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"        # spawned (alive), not yet listening
    fake_comm $$ tailroute-proxy

    assert_ok is_proxy_running
    assert_eq "$$" "$(get_proxy_pid)"
}

test_dead_registry_entry_is_removed_when_nothing_is_running() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"
    fake_pgrep

    assert_fail is_proxy_running
    if [[ -f "$PROXY_PID_FILE" ]]; then
        _assert_fail "dead registry entry must be removed, not reported"
    fi
}

test_status_reports_foreign_listener_on_the_socks_port() {
    _setup_proxy_sandbox
    fake_pgrep
    fake_lsof 777
    fake_comm 777 nc                   # someone else holds 1055

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "held by pid 777" "$out"
    assert_contains "not tailroute-proxy" "$out"
}

test_status_reports_the_resolved_pid_not_the_stale_one() {
    _setup_proxy_sandbox
    echo 99999 > "$PROXY_PID_FILE"
    fake_pgrep $PPID
    fake_comm $PPID tailroute-proxy

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "Running (pid $PPID)" "$out"
}

# =============================================================================
# Daemon status: installed-but-not-running gets a repair hint (#42 defect 1)
# =============================================================================
# `tailroute status` found the daemon via pgrep on the incident host's
# successor, but when the daemon is genuinely down on an INSTALLED machine
# (label unloaded, launchd throttling), a bare "Not running" gives no
# repair path. The plist's presence is the tell.

test_status_hints_bootstrap_when_daemon_installed_but_not_running() {
    _setup_proxy_sandbox
    launchctl() { return 1; }                    # no user-domain label, pgrep empty
    _daemon_plist_path() { echo "$PROXY_TEST_HOME/daemon.plist"; }
    : > "$PROXY_TEST_HOME/daemon.plist"          # installed

    local out
    out=$(do_status 2>&1)
    assert_contains "Not running (installed" "$out"
    assert_contains "launchctl bootstrap system" "$out"
}

test_status_plain_not_running_when_daemon_not_installed() {
    _setup_proxy_sandbox
    launchctl() { return 1; }
    _daemon_plist_path() { echo "$PROXY_TEST_HOME/none.plist"; }

    local out
    out=$(do_status 2>&1)
    assert_contains "Daemon:         Not running" "$out"
    if grep -q "bootstrap" <<< "$out"; then
        _assert_fail "must not suggest bootstrap when the daemon is not installed"
    fi
}

# =============================================================================
# Canonical binary location and version awareness (#42 defect 3)
# =============================================================================

# Fixture "binaries" are /bin/sh stubs that answer --version. A leading
# "v" (Go binary style, real-world) and a bare version (CLI style) are
# both exercised below.

# _check_proxy_binary_version must not flag a binary whose version matches
# the CLI just because one prints a leading "v" and the other does not —
# that was the v0.9.0 false-positive skew trap.
test_check_version_accepts_match_with_v_prefix() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy v%s"\n' "$VERSION" > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"

    local out
    out=$(_check_proxy_binary_version "$PROXY_BIN_PATH" 2>&1)
    assert_contains "matches CLI" "$out"
    if [[ "$out" == *"Version skew"* ]]; then
        _assert_fail "v-prefix + matching bare version must not skew: $out"
    fi
}

# Skew against a genuine older version still surfaces.
test_check_version_flags_skew_with_older_version() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy 0.2.2"\n' > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"

    local out
    out=$(_check_proxy_binary_version "$PROXY_BIN_PATH" 2>&1)
    assert_contains "Version skew" "$out"
    assert_contains "0.2.2" "$out"
}

# Skew with a v-prefix on the binary side still trips the warning, which
# is the trigger tell do_proxy_install uses to self-heal.
test_check_version_flags_skew_with_v_prefix() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy v0.2.2"\n' > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"

    local out
    out=$(_check_proxy_binary_version "$PROXY_BIN_PATH" 2>&1)
    assert_contains "Version skew" "$out"
    assert_contains "v0.2.2" "$out"    # raw string is preserved in the display
}

# do_proxy_install self-heals on a mismatched binary instead of warning.
# The "rm ~/.tailroute/bin/tailroute-proxy first" workaround is gone —
# `proxy install` re-downloads on its own now.
test_install_self_heals_on_version_mismatch() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy v0.2.2"\n' > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }

    # curl / get_proxy_download_url stub: simulate a download that writes
    # a fake binary reporting v$VERSION (matching CLI), then return success.
    curl() {
        printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "v$VERSION" > "$PROXY_BIN_PATH"
        chmod +x "$PROXY_BIN_PATH"
        return 0
    }
    get_proxy_download_url() { echo "https://example.invalid/skip"; }

    local out
    out=$(do_proxy_install 2>&1)
    assert_contains "Replacing proxy binary" "$out"

    # The replacement must have actually landed — read back via the new file.
    local new_ver
    new_ver=$("$PROXY_BIN_PATH" --version 2>/dev/null | tail -n 1 | awk '{print $NF}')
    assert_eq "v$VERSION" "$new_ver" \
        "self-heal must overwrite the binary with a matching-version one"
}

# do_proxy_install on a matching version is a no-op: no download attempted.
test_install_no_op_on_matching_version() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "$VERSION" > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }

    # If curl ever runs, this counter goes above zero.
    local curl_runs=0
    curl() { curl_runs=$((curl_runs + 1)); return 0; }
    get_proxy_download_url() { echo "https://example.invalid/never"; }

    local out
    out=$(do_proxy_install 2>&1)
    assert_contains "matches CLI" "$out"
    assert_eq 0 "$curl_runs" "matching version must skip the download entirely"
}

# FORCE_INSTALL=1 (set by the `proxy install --force` dispatcher) re-downloads
# even on match — recovers from a corrupted-but-version-matched binary.
test_install_force_refreshes_even_when_match() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "$VERSION" > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }

    curl() {
        # "Fresh" binary — different version, so file content visibly changes.
        printf '#!/bin/sh\necho "tailroute-proxy v%s+rc"\n' "$VERSION" > "$PROXY_BIN_PATH"
        chmod +x "$PROXY_BIN_PATH"
        return 0
    }
    get_proxy_download_url() { echo "https://example.invalid/skip"; }

    local out
    out=$(FORCE_INSTALL=1 do_proxy_install 2>&1)
    local new_ver
    new_ver=$("$PROXY_BIN_PATH" --version 2>/dev/null | tail -n 1 | awk '{print $NF}')
    assert_eq "v$VERSION+rc" "$new_ver" \
        "FORCE_INSTALL=1 must replace the binary even on a clean version match"
}

# Fresh-install path still works under FORCE_INSTALL=1 (no binary present).
test_install_force_still_installs_when_binary_absent() {
    _setup_proxy_sandbox
    # No stub binary at PROXY_BIN_PATH — fresh install path.
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }
    curl() {
        printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "v$VERSION" > "$PROXY_BIN_PATH"
        chmod +x "$PROXY_BIN_PATH"
        return 0
    }
    get_proxy_download_url() { echo "https://example.invalid/skip"; }

    local out
    out=$(FORCE_INSTALL=1 do_proxy_install 2>&1)
    assert_contains "Installed:" "$out"
    if [[ ! -x "$PROXY_BIN_PATH" ]]; then
        _assert_fail "binary must be present after install"
    fi
}

test_install_retires_legacy_system_binary() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "$VERSION" > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    local legacy="$PROXY_TEST_HOME/system/tailroute-proxy"
    mkdir -p "$PROXY_TEST_HOME/system"
    printf '#!/bin/sh\nexit 0\n' > "$legacy"
    chmod +x "$legacy"
    _system_proxy_bin() { echo "$legacy"; }

    local out
    out=$(do_proxy_install 2>&1)
    assert_contains "Retired legacy proxy" "$out"
    if [[ -x "$legacy" ]]; then
        _assert_fail "legacy binary must be moved aside, not left spawnable"
    fi
    if [[ ! -x "$legacy.retired" ]]; then
        _assert_fail "retired binary must be preserved (rename, never rm)"
    fi
}

test_install_leaves_system_binary_alone_for_source_installs() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "$VERSION" > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    local legacy="$PROXY_TEST_HOME/system/tailroute-proxy"
    mkdir -p "$PROXY_TEST_HOME/system"
    printf '#!/bin/sh\nexit 0\n' > "$legacy"
    chmod +x "$legacy"
    _system_proxy_bin() { echo "$legacy"; }
    _script_is_system_install() { return 0; }               # `sudo tailroute install` layout

    do_proxy_install > /dev/null 2>&1
    if [[ ! -x "$legacy" ]]; then
        _assert_fail "the system install owns /usr/local/bin — it must not be retired"
    fi
}

test_start_warns_when_falling_back_to_legacy_system_binary() {
    _setup_proxy_sandbox
    local legacy="$PROXY_TEST_HOME/system/tailroute-proxy"
    mkdir -p "$PROXY_TEST_HOME/system"
    printf '#!/bin/sh\nexit 0\n' > "$legacy"                # spawn exits immediately; port stays closed
    chmod +x "$legacy"
    _system_proxy_bin() { echo "$legacy"; }

    local out
    out=$(do_proxy_start 2>&1 </dev/null)
    assert_contains "legacy" "$out"
}

# =============================================================================
# Auth state surfacing (#42 defect 4)
# =============================================================================

# Log lines are the exact markers observed on the incident host:
#   2026/09/23 01:55:26 LocalBackend state is NeedsLogin; running StartLoginInteractive...
#   2026/09/23 01:55:26 tsnet connected, state: NeedsLogin

test_auth_reports_pending_login_url_from_log() {
    _setup_proxy_sandbox
    : > "$PROXY_STATE_DIR/tailscaled.state"
    printf 'To login, visit: https://login.tailscale.com/a/0123456789abcdef\n' \
        > "$PROXY_TEST_HOME/.tailroute/proxy.log"

    local out
    out=$(do_proxy_auth 2>&1 </dev/null)
    assert_contains "https://login.tailscale.com/a/0123456789abcdef" "$out"
}

test_auth_detects_needslogin_loop_and_points_at_authkey() {
    _setup_proxy_sandbox
    : > "$PROXY_STATE_DIR/tailscaled.state"
    printf 'tsnet connected, state: NeedsLogin\n' > "$PROXY_TEST_HOME/.tailroute/proxy.log"

    local out rc=0
    out=$(do_proxy_auth 2>&1 </dev/null) || rc=$?
    assert_contains "NeedsLogin" "$out"
    assert_contains "TS_AUTHKEY" "$out"
    assert_eq "1" "$rc" "NeedsLogin state must not read as success"
}

test_auth_still_reports_authenticated_without_markers() {
    _setup_proxy_sandbox
    : > "$PROXY_STATE_DIR/tailscaled.state"
    printf 'tsnet connected, state: Running\n' > "$PROXY_TEST_HOME/.tailroute/proxy.log"

    local out
    out=$(do_proxy_auth 2>&1 </dev/null)
    assert_contains "already authenticated" "$out"
}

test_auth_flow_mentions_the_authkey_path_upfront() {
    _setup_proxy_sandbox
    printf '#!/bin/sh\nexit 0\n' > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"

    local out
    out=$(do_proxy_auth 2>&1 </dev/null)
    assert_contains "TS_AUTHKEY" "$out"
    if grep -q "Open the URL below" <<< "$out"; then
        _assert_fail "must not promise a URL it never prints"
    fi
}

test_start_passes_authkey_by_env_not_argv() {
    _setup_proxy_sandbox
    # Fixture records its argv and the TS_AUTHKEY it received.
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$PROXY_TEST_HOME/child-args"\nprintf "%%s" "${TS_AUTHKEY-}" > "$PROXY_TEST_HOME/child-env"\nexit 0\n' > "$PROXY_BIN_PATH"
    chmod +x "$PROXY_BIN_PATH"
    TS_AUTHKEY="tskey-auth-test-secret" do_proxy_start > /dev/null 2>&1 </dev/null

    # The spawn is asynchronous — wait for the fixture to record itself
    # (/bin/sleep, not the mocked sleep).
    local tries=0
    while [[ ! -f "$PROXY_TEST_HOME/child-env" && $tries -lt 100 ]]; do
        /bin/sleep 0.05
        tries=$((tries + 1))
    done

    assert_eq "tskey-auth-test-secret" "$(cat "$PROXY_TEST_HOME/child-env")" \
        "the key must reach the proxy through the environment"
    if grep -q "auth-key\|tskey" "$PROXY_TEST_HOME/child-args"; then
        _assert_fail "auth key must not appear in argv (world-readable via ps)"
    fi
}

test_status_reports_needslogin_when_running() {
    _setup_proxy_sandbox
    echo $$ > "$PROXY_PID_FILE"
    fake_comm $$ tailroute-proxy
    printf 'tsnet connected, state: NeedsLogin\n' > "$PROXY_TEST_HOME/.tailroute/proxy.log"

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "Needs login" "$out"
    assert_contains "proxy auth" "$out"
}

# =============================================================================
# Binary discovery and the non-interactive missing-binary path (UAT 2026-11-01)
# =============================================================================
# A Homebrew install links `tailroute` and `tailroute-proxy` into one bin dir
# (/opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel). The CLI only
# ever looked in $HOME/.tailroute/bin and /usr/local/bin, so on Apple Silicon it
# reported "Binary: Not installed" over a proxy sitting beside itself, and
# `proxy start` from the app hit an interactive prompt that could not answer.

# Nothing outside the scratch dir may resolve as a proxy binary. Also drops
# /opt/homebrew/bin from PATH so a real installed proxy cannot satisfy a
# "missing binary" test on a developer machine.
_isolate_proxy_bin_paths() {
    local empty="$PROXY_TEST_HOME/no-proxy-on-path"
    mkdir -p "$empty"
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }
    _proxy_sibling_bin() { echo "$PROXY_TEST_HOME/none"; }
    PATH="$empty:/usr/bin:/bin"
}

_install_fake_proxy() {
    local path="$1" version="${2:-$VERSION}"
    mkdir -p "$(dirname "$path")"
    printf '#!/bin/sh\necho "tailroute-proxy %s"\n' "$version" > "$path"
    chmod +x "$path"
}

test_resolve_proxy_bin_prefers_the_managed_copy() {
    _setup_proxy_sandbox
    _install_fake_proxy "$PROXY_BIN_PATH"
    _proxy_sibling_bin() { echo "$PROXY_TEST_HOME/sibling/tailroute-proxy"; }
    _install_fake_proxy "$PROXY_TEST_HOME/sibling/tailroute-proxy"

    assert_eq "$PROXY_BIN_PATH" "$(resolve_proxy_bin)" \
        "the managed copy must win so version self-heal keeps working"
}

test_resolve_proxy_bin_finds_the_binary_beside_the_script() {
    _setup_proxy_sandbox
    local sibling="$PROXY_TEST_HOME/sibling/tailroute-proxy"
    _install_fake_proxy "$sibling"
    _proxy_sibling_bin() { echo "$sibling"; }
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }

    assert_eq "$sibling" "$(resolve_proxy_bin)" \
        "a package install puts the proxy next to the tailroute script"
}

test_resolve_proxy_bin_falls_back_to_path() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths
    local onpath="$PROXY_TEST_HOME/on-path/tailroute-proxy"
    _install_fake_proxy "$onpath"
    PATH="$(dirname "$onpath"):/usr/bin:/bin"

    assert_eq "$onpath" "$(resolve_proxy_bin)"
}

# Each lib-*.sh reassigns SCRIPT_DIR to its own directory, so by the time the
# proxy is resolved SCRIPT_DIR points at <prefix>/lib, not the bin dir holding
# the executable. The sibling lookup must use the dir captured before the libs
# loaded, or it misses the proxy in exactly the layout it was added for.
test_sibling_lookup_ignores_the_script_dir_clobber() {
    _setup_proxy_sandbox
    local real_bin_dir="$PROXY_TEST_HOME/prefix/bin"
    mkdir -p "$real_bin_dir"
    TAILROUTE_BIN_DIR="$real_bin_dir"
    SCRIPT_DIR="$PROXY_TEST_HOME/prefix/lib"        # what the libs leave behind

    assert_eq "$real_bin_dir/tailroute-proxy" "$(_proxy_sibling_bin)" \
        "sibling resolution must not follow the libs' SCRIPT_DIR rewrite"
}

test_resolve_proxy_bin_reports_nothing_when_absent() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths
    if resolve_proxy_bin >/dev/null; then
        _assert_fail "resolve_proxy_bin must fail when no binary exists anywhere"
    fi
}

test_status_names_a_proxy_that_ships_with_the_cli() {
    _setup_proxy_sandbox
    local sibling="$PROXY_TEST_HOME/sibling/tailroute-proxy"
    _install_fake_proxy "$sibling"
    _proxy_sibling_bin() { echo "$sibling"; }
    _system_proxy_bin() { echo "$PROXY_TEST_HOME/none"; }

    local out
    out=$(do_proxy_status 2>&1)
    assert_contains "$sibling" "$out"
    assert_contains "ships with the CLI" "$out"
    if [[ "$out" == *"Not installed"* ]]; then
        _assert_fail "a binary beside the script must not report as Not installed"
    fi
}

# The shape the app lives in: no TTY, so stdin is EOF. It must fail with the
# reason on stderr — stdout-only text is what the app was discarding.
test_start_without_binary_fails_on_stderr_when_stdin_is_not_a_tty() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths

    local rc=0 stdout="" stderr=""
    stderr=$( (do_proxy_start 2>&1 >/dev/null </dev/null) ) || rc=$?
    stdout=$( (do_proxy_start 2>/dev/null </dev/null) ) || true

    assert_eq 1 "$rc" "a missing binary with no TTY must exit non-zero"
    assert_contains "Proxy binary not installed" "$stderr"
    assert_contains "proxy install" "$stderr"
    if [[ "$stderr" == *"Download tailroute-proxy"* ]]; then
        _assert_fail "must not prompt a caller whose stdin is not a TTY"
    fi
    if [[ "$stdout" == *"Proxy binary not installed"* ]]; then
        _assert_fail "the reason belongs on stderr so a GUI caller can show it"
    fi
}

test_start_honours_no_without_prompting() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths

    local rc=0 out=""
    out=$(PROXY_START_INSTALL=no do_proxy_start 2>&1 </dev/null) || rc=$?

    assert_eq 1 "$rc" "--no must refuse instead of downloading"
    assert_contains "proxy install" "$out"
    if [[ "$out" == *"Download tailroute-proxy"* ]]; then
        _assert_fail "--no must never fall through to the prompt"
    fi
}

test_start_yes_installs_then_starts() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths
    curl() { _install_fake_proxy "$PROXY_BIN_PATH"; return 0; }
    get_proxy_download_url() { echo "https://example.invalid/skip"; }

    local out=""
    out=$(PROXY_START_INSTALL=yes do_proxy_start 2>&1 </dev/null) || true

    assert_contains "Installed: $PROXY_BIN_PATH" "$out"
    if [[ -x "$PROXY_BIN_PATH" ]]; then :; else
        _assert_fail "--yes must download the binary before starting"
    fi
}

test_auth_without_binary_reports_on_stderr() {
    _setup_proxy_sandbox
    _isolate_proxy_bin_paths

    local rc=0 stderr=""
    stderr=$( (do_proxy_auth 2>&1 >/dev/null) ) || rc=$?

    assert_eq 1 "$rc"
    assert_contains "Proxy binary not installed" "$stderr"
}


# `proxy-config shell` piped the status JSON into `python3 -` while the same
# command also supplied a heredoc, and the heredoc won: python read its script
# from stdin, never saw the JSON, and the peer list silently stayed empty.
test_proxy_config_shell_lists_peers_from_tailscale_status() {
    _setup_proxy_sandbox
    SHELL=/bin/bash
    tailscale() {
        printf '%s' '{"CurrentTailnet":{"MagicDNSSuffix":"example.ts.net"},"Peer":{"a":{"DNSName":"alpha.example.ts.net."},"b":{"HostName":"beta"}}}'
    }

    local out
    out=$(do_proxy_config_shell "127.0.0.1:1055" 2>&1)
    assert_contains "Available peers: alpha.example.ts.net beta.example.ts.net" "$out"
}

test_proxy_config_shell_falls_back_when_status_is_unreadable() {
    _setup_proxy_sandbox
    SHELL=/bin/bash
    tailscale() { printf 'not json'; }

    local out
    out=$(do_proxy_config_shell "127.0.0.1:1055" 2>&1)
    assert_contains "see 'tailscale status'" "$out"
}
