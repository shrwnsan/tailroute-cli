#!/usr/bin/env bash
# tunnel-fixtures.sh — shared sandbox and mocks for the tunnel test suites
#
# Sourced by test files (name deliberately does not match test-*.sh, so
# run-tests.sh never treats it as a suite). Everything runs in a sandbox:
# hosts file, LaunchAgents dir, ssh config, wrapper, and registry are
# redirected to a temp dir; launchctl/nc/ssh/tailscale/dscacheutil are
# mocked; TUNNEL_SUDO_CMD="" exercises the exact privileged code path
# without root.
#
# The launchctl mock models a persistent disabled-services store in
# LAUNCHCTL_DISABLED_STATE (one `label<TAB>disabled|enabled` line per
# label; entries are never deleted, matching real launchd, and `enable`
# writes an explicit `enabled` line rather than removing the entry).
# Failure seams: FAIL_BOOTSTRAP, FAIL_DISABLE, FAIL_ENABLE,
# FAIL_PRINT_DISABLED (each exits 1 with a stderr line; FAIL_BOOTSTRAP
# predates the store), STUCK_BOOTOUT=1 (bootout leaves the label loaded,
# exit 5). Unmodelled subcommands exit 64 so tests fail loudly.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared fixture constants — generic Tailscale CGNAT address and example
# tailnet, not real user data. Inputs (build/parse calls, fixture heredocs)
# reference these; assertions pin the literal expected output instead.
# Consumed by the sourcing suites, which shellcheck cannot see.
# shellcheck disable=SC2034
FX_PEER="prime"
FX_IP="100.100.100.100"
FX_HOSTNAME="prime.tailnet.ts.net"
FX_SUFFIX="tailnet.ts.net"
# shellcheck disable=SC2034  # consumed by the sourcing suites
FX_FWD1="8443:443"

_tunnel_setup_sandbox() {
    TUNNEL_SANDBOX="$(mktemp -d)"
    mkdir -p "$TUNNEL_SANDBOX/bin" "$TUNNEL_SANDBOX/launchagents" "$TUNNEL_SANDBOX/ssh" "$TUNNEL_SANDBOX/config"

    export TUNNEL_CONFIG_DIR="$TUNNEL_SANDBOX/config"
    export TUNNEL_REGISTRY="$TUNNEL_CONFIG_DIR/tunnels.json"
    export TUNNEL_LOCK_DIR="$TUNNEL_CONFIG_DIR/tunnel.lock"
    export TUNNEL_JOURNAL_PATH="$TUNNEL_CONFIG_DIR/tunnels.journal"
    export TUNNEL_HOSTS_LOCK_DIR="$TUNNEL_SANDBOX/hosts.lock"
    export TUNNEL_HOSTS_FILE="$TUNNEL_SANDBOX/hosts"
    export TUNNEL_LAUNCHAGENTS_DIR="$TUNNEL_SANDBOX/launchagents"
    export TUNNEL_LOG_DIR="$TUNNEL_SANDBOX/logs"
    export TUNNEL_SSH_CONFIG="$TUNNEL_SANDBOX/ssh/config"
    export TUNNEL_SSH_WRAPPER="$TUNNEL_SANDBOX/ssh/tailroute-proxy.sh"
    export TUNNEL_SUDO_CMD=""
    export LAUNCHCTL_STATE="$TUNNEL_SANDBOX/launchd-state"
    export LAUNCHCTL_DISABLED_STATE="$TUNNEL_SANDBOX/launchd-disabled"
    export FAKE_NC_OPEN=""
    export FAIL_BOOTSTRAP=0
    export FAIL_SSH=0
    export TUNNEL_WAIT_TRIES=1
    export FAKE_OPEN_LOG="$TUNNEL_SANDBOX/opened.log"
    : > "$FAKE_OPEN_LOG"
    export FAKE_PROBE_LOG="$TUNNEL_SANDBOX/probes.log"
    : > "$FAKE_PROBE_LOG"
    export FAKE_REMOTE_NC_REFUSE=""
    export FAKE_REMOTE_NO_NC=0
    : > "$LAUNCHCTL_STATE"
    : > "$LAUNCHCTL_DISABLED_STATE"
    printf '127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n' > "$TUNNEL_HOSTS_FILE"

    # --- mocks ---
    cat > "$TUNNEL_SANDBOX/bin/nc" <<'MOCK'
#!/bin/sh
case "$1" in
    -z) port="$3"
        case " $FAKE_NC_OPEN " in *" $port "*) exit 0 ;; *) exit 1 ;; esac ;;
    *) exit 0 ;;
esac
MOCK
    cat > "$TUNNEL_SANDBOX/bin/launchctl" <<'MOCK'
#!/bin/sh
state="$LAUNCHCTL_STATE"
disabled_state="$LAUNCHCTL_DISABLED_STATE"
cmd="$1"

_store_state_of() {
    # prints disabled|enabled for $1; empty when the store has no entry
    awk -v l="$1" -F'\t' '$1 == l { print $2; exit }' "$disabled_state" 2>/dev/null
}

_upsert_disabled() {
    # $1 = label, $2 = disabled|enabled. Upsert: the old line is replaced,
    # never deleted — real launchd keeps an explicit line after `enable`.
    awk -v l="$1" -F'\t' '$1 != l' "$disabled_state" > "$disabled_state.tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$1" "$2" >> "$disabled_state.tmp"
    mv "$disabled_state.tmp" "$disabled_state"
}

case "$cmd" in
    print)
        # target: gui/$UID/<label> — compare the label part
        label="${2##*/}"
        grep -qx "$label" "$state" 2>/dev/null && exit 0
        exit 1 ;;
    bootstrap)
        # args: bootstrap gui/$UID <plist-path>
        if [ "${FAIL_BOOTSTRAP:-0}" = "1" ]; then
            echo "mock launchctl: bootstrap failed" >&2
            exit 1
        fi
        label="$(basename "$3" .plist)"
        if [ "$(_store_state_of "$label")" = "disabled" ]; then
            echo "Bootstrap failed: 5: Input/output error" >&2
            exit 5
        fi
        echo "$label" >> "$state"
        exit 0 ;;
    bootout)
        # target: gui/$UID/<label>
        label="${2##*/}"
        if [ "${STUCK_BOOTOUT:-0}" = "1" ]; then
            echo "mock launchctl: bootout failed (label stays loaded)" >&2
            exit 5
        fi
        grep -vx "$label" "$state" > "$state.tmp" 2>/dev/null || true
        mv "$state.tmp" "$state"
        exit 0 ;;
    disable)
        [ "${FAIL_DISABLE:-0}" = "1" ] && { echo "mock launchctl: disable failed" >&2; exit 1; }
        _upsert_disabled "${2##*/}" disabled
        exit 0 ;;
    enable)
        [ "${FAIL_ENABLE:-0}" = "1" ] && { echo "mock launchctl: enable failed" >&2; exit 1; }
        _upsert_disabled "${2##*/}" enabled
        exit 0 ;;
    print-disabled)
        # target: gui/$UID — mirrors real `launchctl print-disabled` shape:
        # a header, tab-indented `"label" => state` lines, a footer. The
        # decoy line is always present so tests catch naive greps.
        if [ "${FAIL_PRINT_DISABLED:-0}" = "1" ]; then
            echo "mock launchctl: print-disabled failed" >&2
            exit 1
        fi
        printf '\tdisabled services = {\n'
        printf '\t\t"com.apple.decoy" => disabled\n'
        [ -f "$disabled_state" ] && \
            awk -F'\t' 'NF >= 2 { printf "\t\t\"%s\" => %s\n", $1, $2 }' "$disabled_state"
        printf '\t}\n'
        exit 0 ;;
    list)
        # `bin/tailroute.sh` daemon verbs call this; empty listing suffices
        exit 0 ;;
    *)
        echo "mock launchctl: unhandled $cmd" >&2
        exit 64 ;;
esac
MOCK
    cat > "$TUNNEL_SANDBOX/bin/ssh" <<'MOCK'
#!/bin/sh
[ -n "${SSH_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$SSH_CALL_LOG"
[ "${FAIL_SSH:-0}" = "1" ] && exit 255
# T-413: serve-status probe. Unset FAKE_SERVE_STATUS = locked-down peer
# (remote command fails) — silent fallback.
case "$*" in
    *"tailscale serve status"*)
        if [ -n "${FAKE_SERVE_STATUS:-}" ]; then
            printf '%s\n' "$FAKE_SERVE_STATUS"
            exit "${FAKE_SERVE_STATUS_RC:-0}"
        fi
        # T-439: reachable peer that reports no serve config (rc 0, no output)
        [ "${FAKE_SERVE_STATUS_EMPTY:-0}" = "1" ] && exit "${FAKE_SERVE_STATUS_RC:-0}"
        exit 1 ;;
esac
# Remote backend probe (v0.7.8): the CLI asks the peer to run
# '/usr/bin/nc -z <target> <port>'. Record the probe line in FAKE_PROBE_LOG so
# tests can pin the target, and model a Serve listener that answers its
# tailscale IP but refuses loopback via FAKE_REMOTE_NC_REFUSE ("<ip>:<port>"
# pairs).
# v0.8.2: the probe command carries an nc branch and a bash /dev/tcp fallback;
# FAKE_REMOTE_NO_NC=1 models a peer with no nc binary at all (production
# Ubuntu): the legacy '/usr/bin/nc' executor dies 127 there and only the
# fallback runs, which answers like any connector — same listener model as the
# nc branch (FAKE_REMOTE_NC_REFUSE). FAKE_NC_OPEN stays a LOCAL-port model.
for _mock_last; do :; done
case "${_mock_last:-}" in
    *"nc -z "*)
        [ -n "${FAKE_PROBE_LOG:-}" ] && printf '%s\n' "$_mock_last" >> "$FAKE_PROBE_LOG"
        # target sits directly after 'nc -z ' in both command shapes
        _mock_probe="$(printf '%s' "$_mock_last" | sed -n 's/.*nc -z \([0-9.]* [0-9][0-9]*\).*/\1/p')"
        [ -n "$_mock_probe" ] || _mock_probe="${_mock_last##*nc -z }"
        case " $FAKE_REMOTE_NC_REFUSE " in
            *" ${_mock_probe%% *}:${_mock_probe##* } "*) exit 1 ;;
        esac
        if [ "${FAKE_REMOTE_NO_NC:-0}" = "1" ]; then
            case "$_mock_last" in
                *"/usr/bin/nc -z "*) exit 127 ;;
            esac
        fi
        exit 0 ;;
esac
# v0.7.4: pre-flight hint testing - emit canned stderr and refuse
case "$*" in
    *" true")
        [ -n "${FAKE_SSH_STDERR:-}" ] && { printf '%s\n' "$FAKE_SSH_STDERR" >&2; exit 255; }
        # v0.7.5: simulate a key that is only reachable through the agent
        [ "${FAKE_SSH_NEEDS_AGENT:-0}" = "1" ] && [ -z "${SSH_AUTH_SOCK:-}" ] && exit 255 ;;
esac
exit 0
MOCK
    cat > "$TUNNEL_SANDBOX/bin/tailscale" <<'MOCK'
#!/bin/sh
if [ "$1" = "status" ] && [ "$2" = "--json" ]; then
    cat "$FAKE_TS_JSON"
    exit 0
fi
exit 0
MOCK
    # T-420: records URLs handed to the macOS `open` command
    cat > "$TUNNEL_SANDBOX/bin/open" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_OPEN_LOG"
exit 0
MOCK
    chmod +x "$TUNNEL_SANDBOX/bin/"*
    export NC_CMD="$TUNNEL_SANDBOX/bin/nc"
    export LAUNCHCTL_CMD="$TUNNEL_SANDBOX/bin/launchctl"
    export SSH_CMD="$TUNNEL_SANDBOX/bin/ssh"
    export TAILSCALE_CMD="$TUNNEL_SANDBOX/bin/tailscale"
    export OPEN_CMD="$TUNNEL_SANDBOX/bin/open"
    export DSCACHEUTIL_CMD=/usr/bin/true

    # Tailscale status fixture: peer "prime" online in tailnet "tailnet.ts.net"
    cat > "$TUNNEL_SANDBOX/ts.json" <<JSON
{
  "CurrentTailnet": {"MagicDNSSuffix": "$FX_SUFFIX"},
  "Peer": {
    "node1": {
      "HostName": "$FX_PEER",
      "DNSName": "${FX_HOSTNAME}.",
      "TailscaleIPs": ["$FX_IP", "fd7a:115c:a1e0::1"],
      "Online": true
    }
  }
}
JSON
    export FAKE_TS_JSON="$TUNNEL_SANDBOX/ts.json"

    # --- openssl mock (T-430) ---
    cat > "$TUNNEL_SANDBOX/bin/openssl" <<'MOCK'
#!/bin/sh
# Mock openssl s_client for TLS verification tests.
# Set FAKE_TLS_HOSTNAME to control what the mock certificate returns.
case "$1" in
    s_client)
        hostname="${FAKE_TLS_HOSTNAME:-prime.tailnet.ts.net}"
        case "$hostname" in
            fail-connect) exit 1 ;;
            no-cert)
                echo "depth=0 CN = $hostname" ;;
            wrong-host)
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\nsubject= /CN=evil.example.com\n    Verify return code: 0 (ok)\n' ;;
            expired)
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\nsubject= /O=Expired/CN=%s\n    Verify return code: 10 (certificate has expired)\n' "$hostname" ;;
            unverified)
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\nsubject= /CN=%s\n    Verify return code: 19 (self-signed certificate in certificate chain)\n' "$hostname" ;;
            libressl-ok)
                # v0.7.5: real LibreSSL s_client exits 1 even on a verified session
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\nsubject=/CN=prime.tailnet.ts.net\n    Verify return code: 0 (ok)\n'
                exit 1 ;;
            wildcard)
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\n \nDNS:*.tailnet.ts.net\n    Verify return code: 0 (ok)\n' ;;
            *)
                printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\nsubject= /CN=%s\n    Verify return code: 0 (ok)\n' "$hostname" ;;
        esac
        exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TUNNEL_SANDBOX/bin/openssl"
    export OPENSSL_CMD="$TUNNEL_SANDBOX/bin/openssl"

    # --- curl mock (tunnel check HTTP probe) ---
    # Mocks `curl -w '%{http_code}'`: FAKE_HTTP_CODE is what the write-out
    # reports (default 200); FAKE_CURL_RC models a transport-level failure,
    # where real curl still prints its write-out ("000").
    cat > "$TUNNEL_SANDBOX/bin/curl" <<'MOCK'
#!/bin/sh
printf '%s' "${FAKE_HTTP_CODE:-200}"
exit "${FAKE_CURL_RC:-0}"
MOCK
    chmod +x "$TUNNEL_SANDBOX/bin/curl"
    export CURL_CMD="$TUNNEL_SANDBOX/bin/curl"
    export FAKE_HTTP_CODE="200"
    export FAKE_CURL_RC=0

    # SSH config fixture with an adaptive proxy-prime entry
    cat > "$TUNNEL_SSH_CONFIG" <<CFG
Host proxy-$FX_PEER
    HostName $FX_IP
    ProxyCommand ~/.ssh/tailroute-proxy.sh %h %p
CFG

    # shellcheck source=/dev/null
    source "$TEST_DIR/../bin/lib-tunnel.sh"
}
