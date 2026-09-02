#!/usr/bin/env bash
# test-lib-tunnel.sh — Tests for lib-tunnel.sh (browser tunnels, PRD-004)
#
# Everything runs in a sandbox: hosts file, LaunchAgents dir, ssh config,
# wrapper, and registry are redirected to a temp dir; launchctl/nc/ssh/
# tailscale/dscacheutil are mocked; TUNNEL_SUDO_CMD="" exercises the exact
# privileged code path without root.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared fixture constants — generic Tailscale CGNAT address and example
# tailnet, not real user data. Inputs (build/parse calls, fixture heredocs)
# reference these; assertions pin the literal expected output instead.
FX_PEER="prime"
FX_IP="100.97.245.83"
FX_HOSTNAME="prime.tailnet.ts.net"
FX_SUFFIX="tailnet.ts.net"
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
    export FAKE_NC_OPEN=""
    export FAIL_BOOTSTRAP=0
    export FAIL_SSH=0
    export TUNNEL_WAIT_TRIES=1
    export FAKE_OPEN_LOG="$TUNNEL_SANDBOX/opened.log"
    : > "$FAKE_OPEN_LOG"
    export FAKE_PROBE_LOG="$TUNNEL_SANDBOX/probes.log"
    : > "$FAKE_PROBE_LOG"
    export FAKE_REMOTE_NC_REFUSE=""
    : > "$LAUNCHCTL_STATE"
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
cmd="$1"
case "$cmd" in
    print)
        # target: gui/$UID/<label> — compare the label part
        label="${2##*/}"
        grep -qx "$label" "$state" 2>/dev/null && exit 0
        exit 1 ;;
    bootstrap)
        # args: bootstrap gui/$UID <plist-path>
        [ "${FAIL_BOOTSTRAP:-0}" = "1" ] && exit 1
        label="$(basename "$3" .plist)"
        echo "$label" >> "$state"
        exit 0 ;;
    bootout)
        # target: gui/$UID/<label>
        label="${2##*/}"
        grep -vx "$label" "$state" > "$state.tmp" 2>/dev/null || true
        mv "$state.tmp" "$state"
        exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    cat > "$TUNNEL_SANDBOX/bin/ssh" <<'MOCK'
#!/bin/sh
[ "${FAIL_SSH:-0}" = "1" ] && exit 255
# T-413: serve-status probe. Unset FAKE_SERVE_STATUS = locked-down peer
# (remote command fails) — silent fallback.
case "$*" in
    *"tailscale serve status"*)
        [ -n "${FAKE_SERVE_STATUS:-}" ] && { printf '%s\n' "$FAKE_SERVE_STATUS"; exit 0; }
        exit 1 ;;
esac
# Remote backend probe (v0.7.8): the CLI asks the peer to run
# '/usr/bin/nc -z <target> <port>'. Record the probe line in FAKE_PROBE_LOG so
# tests can pin the target, and model a Serve listener that answers its
# tailscale IP but refuses loopback via FAKE_REMOTE_NC_REFUSE ("<ip>:<port>"
# pairs).
for _mock_last; do :; done
case "${_mock_last:-}" in
    *"nc -z "*)
        [ -n "${FAKE_PROBE_LOG:-}" ] && printf '%s\n' "$_mock_last" >> "$FAKE_PROBE_LOG"
        _mock_probe="${_mock_last##*nc -z }"
        case " $FAKE_REMOTE_NC_REFUSE " in
            *" ${_mock_probe%% *}:${_mock_probe##* } "*) exit 1 ;;
        esac
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

    # SSH config fixture with an adaptive proxy-prime entry
    cat > "$TUNNEL_SSH_CONFIG" <<CFG
Host proxy-$FX_PEER
    HostName $FX_IP
    ProxyCommand ~/.ssh/tailroute-proxy.sh %h %p
CFG

    # shellcheck source=../bin/lib-tunnel.sh
    source "$TEST_DIR/../bin/lib-tunnel.sh"
}

# =============================================================================
# Validation (T-402.1)
# =============================================================================

test_validate_peer_label_accepts_valid() {
    _tunnel_setup_sandbox
    assert_ok tunnel_validate_peer_label prime
    assert_ok tunnel_validate_peer_label a
    assert_ok tunnel_validate_peer_label node-2-l9otta
}

test_validate_peer_label_rejects_hostile() {
    _tunnel_setup_sandbox
    assert_fail tunnel_validate_peer_label "-R9000"       # leading dash = ssh arg injection
    assert_fail tunnel_validate_peer_label "Okay"          # uppercase (must normalize first)
    assert_fail tunnel_validate_peer_label "a_b"
    assert_fail tunnel_validate_peer_label "a.b"
    assert_fail tunnel_validate_peer_label ""
    assert_fail tunnel_validate_peer_label "x;rm"
    assert_fail tunnel_validate_peer_label "$(printf 'peer\n127.0.0.1 bank.com')"
}

test_validate_suffix_shape() {
    _tunnel_setup_sandbox
    assert_ok tunnel_validate_suffix tailnet.ts.net
    assert_ok tunnel_validate_suffix a-b.tailnet.ts.net
    assert_fail tunnel_validate_suffix tailnet.com
    assert_fail tunnel_validate_suffix ""
    assert_fail tunnel_validate_suffix "../../etc/passwd"
}

test_validate_hostname_must_match_suffix() {
    _tunnel_setup_sandbox
    assert_ok tunnel_validate_hostname prime.tailnet.ts.net tailnet.ts.net
    assert_fail tunnel_validate_hostname bank.com tailnet.ts.net
    assert_fail tunnel_validate_hostname github.com.ts.net tailnet.ts.net
    assert_fail tunnel_validate_hostname evil.other.ts.net tailnet.ts.net
}

test_validate_cgnat_ip() {
    _tunnel_setup_sandbox
    assert_ok tunnel_validate_cgnat_ip 100.97.245.83
    assert_ok tunnel_validate_cgnat_ip 100.64.0.1
    assert_ok tunnel_validate_cgnat_ip 100.127.255.255
    assert_fail tunnel_validate_cgnat_ip 100.63.0.1
    assert_fail tunnel_validate_cgnat_ip 100.128.0.1
    assert_fail tunnel_validate_cgnat_ip 192.168.1.1
    assert_fail tunnel_validate_cgnat_ip "100.97.245.999"
}

# =============================================================================
# Registry (T-401)
# =============================================================================

test_registry_add_get_remove_roundtrip() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1")"
    assert_ok tunnel_registry_add prime "$entry"
    local got
    got="$(tunnel_registry_get prime)"
    assert_contains '"peer": "prime"' "$got"
    assert_contains '"localPort": 8443' "$got"
    assert_ok tunnel_registry_all
    assert_ok tunnel_registry_remove prime
    assert_fail tunnel_registry_get prime
}

test_registry_version_field_and_bak() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1")"
    tunnel_registry_add prime "$entry" >/dev/null
    assert_contains '"version": 2' "$(tunnel_registry_all)"
    [ -f "$TUNNEL_REGISTRY" ] || { echo "registry file missing"; return 1; }
    local entry2
    entry2="$(tunnel_build_entry_json alpha 100.64.0.5 alpha.tailnet.ts.net tailnet.ts.net 8444:443)"
    tunnel_registry_add alpha "$entry2" >/dev/null
    [ -f "$TUNNEL_REGISTRY.bak" ] || { echo ".bak not retained"; return 1; }
    assert_contains '"peer": "prime"' "$(cat "$TUNNEL_REGISTRY.bak")"
}

test_registry_duplicate_and_missing() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1")"
    tunnel_registry_add prime "$entry" >/dev/null
    local rc=0
    tunnel_registry_add prime "$entry" >/dev/null 2>&1 || rc=$?
    assert_eq 4 "$rc" "duplicate add should exit 4"
    rc=0
    tunnel_registry_remove ghost >/dev/null 2>&1 || rc=$?
    assert_eq 5 "$rc" "remove missing should exit 5"
}

test_registry_corrupt_and_version_mismatch() {
    _tunnel_setup_sandbox
    tunnel_registry_check_env
    echo "{ not json" > "$TUNNEL_REGISTRY"
    local rc=0
    tunnel_registry_all >/dev/null 2>&1 || rc=$?
    assert_eq 6 "$rc" "corrupt registry should exit 6"
    echo '{"version": 99, "tunnels": []}' > "$TUNNEL_REGISTRY"
    rc=0
    tunnel_registry_all >/dev/null 2>&1 || rc=$?
    assert_eq 6 "$rc" "unknown version should exit 6"
}

test_registry_symlink_refused() {
    _tunnel_setup_sandbox
    mkdir -p "$TUNNEL_SANDBOX/elsewhere"
    tunnel_registry_check_env
    rm -f "$TUNNEL_REGISTRY"
    ln -s "$TUNNEL_SANDBOX/elsewhere/evil" "$TUNNEL_REGISTRY"
    assert_fail tunnel_registry_check_env
}

# =============================================================================
# Managed hosts block (T-403)
# =============================================================================

test_hosts_add_creates_managed_block() {
    _tunnel_setup_sandbox
    assert_ok tunnel_hosts_apply add prime.tailnet.ts.net
    grep -q "^# BEGIN tailroute-tunnel\$" "$TUNNEL_HOSTS_FILE" || { echo "no BEGIN marker"; return 1; }
    grep -q "^127.0.0.1	prime.tailnet.ts.net\$" "$TUNNEL_HOSTS_FILE" || { echo "no mapping"; return 1; }
    grep -q "^# END tailroute-tunnel\$" "$TUNNEL_HOSTS_FILE" || { echo "no END marker"; return 1; }
    grep -q "^255.255.255.255	broadcasthost\$" "$TUNNEL_HOSTS_FILE" || { echo "unmarked line touched"; return 1; }
}

test_hosts_add_idempotent() {
    _tunnel_setup_sandbox
    tunnel_hosts_apply add prime.tailnet.ts.net >/dev/null
    local before after
    before="$(cat "$TUNNEL_HOSTS_FILE")"
    tunnel_hosts_apply add prime.tailnet.ts.net >/dev/null
    after="$(cat "$TUNNEL_HOSTS_FILE")"
    assert_eq "$before" "$after" "second add must be a no-op"
}

test_hosts_remove_only_exact_line() {
    _tunnel_setup_sandbox
    tunnel_hosts_apply add prime.tailnet.ts.net >/dev/null
    tunnel_hosts_apply add alpha.tailnet.ts.net >/dev/null
    # foreign line inside the block must survive removal of another peer
    printf '127.0.0.1\tforged.tailnet.ts.net\n' >> /dev/null # (block grows via add only)
    assert_ok tunnel_hosts_apply remove prime.tailnet.ts.net
    if grep -q "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE"; then
        _assert_fail "prime mapping still present after remove"
    fi
    grep -q "alpha.tailnet.ts.net" "$TUNNEL_HOSTS_FILE" || { echo "alpha mapping lost"; return 1; }
    grep -q "^255.255.255.255	broadcasthost\$" "$TUNNEL_HOSTS_FILE" || { echo "unmarked line touched"; return 1; }
}

test_hosts_remove_spares_unmanaged_same_hostname() {
    _tunnel_setup_sandbox
    # unmanaged line outside markers for a hostname never added via add()
    printf '127.0.0.1\tmanual.tailnet.ts.net\n' >> "$TUNNEL_HOSTS_FILE"
    tunnel_hosts_apply add prime.tailnet.ts.net >/dev/null
    tunnel_hosts_apply remove prime.tailnet.ts.net >/dev/null
    grep -q "manual.tailnet.ts.net" "$TUNNEL_HOSTS_FILE" || { echo "unmanaged line was removed"; return 1; }
}

test_hosts_duplicate_markers_refused() {
    _tunnel_setup_sandbox
    printf '# BEGIN tailroute-tunnel\n# END tailroute-tunnel\n# BEGIN tailroute-tunnel\n' >> "$TUNNEL_HOSTS_FILE"
    assert_fail tunnel_hosts_apply add prime.tailnet.ts.net
}

test_hosts_unbalanced_markers_refused() {
    _tunnel_setup_sandbox
    printf '# BEGIN tailroute-tunnel\n' >> "$TUNNEL_HOSTS_FILE"
    assert_fail tunnel_hosts_apply add prime.tailnet.ts.net
}

test_hosts_symlink_hosts_file_refused() {
    _tunnel_setup_sandbox
    local real="$TUNNEL_SANDBOX/hosts.real"
    mv "$TUNNEL_HOSTS_FILE" "$real"
    ln -s "$real" "$TUNNEL_HOSTS_FILE"
    assert_fail tunnel_hosts_apply add prime.tailnet.ts.net
}

test_hosts_adopt_migrates_unmanaged_line() {
    _tunnel_setup_sandbox
    printf '127.0.0.1\tprime.tailnet.ts.net\n' >> "$TUNNEL_HOSTS_FILE"
    assert_ok tunnel_hosts_adopt_mapping prime.tailnet.ts.net
    # Now inside the managed block
    awk -v h="prime.tailnet.ts.net" -v b="# BEGIN tailroute-tunnel" -v e="# END tailroute-tunnel" '
        BEGIN { inb = 0; found = 0 }
        $0 == b { inb = 1; next }
        $0 == e { inb = 0; next }
        inb && $0 ~ ("127\\.0\\.0\\.1[[:space:]]+" h "$") { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$TUNNEL_HOSTS_FILE" || { echo "mapping not inside managed block"; return 1; }
    local count
    count="$(grep -c "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE" || true)"
    assert_eq 1 "$count" "exactly one mapping after adoption"
}

# =============================================================================
# Plist generation (T-404.1)
# =============================================================================

test_plist_lints_and_contains_hardening() {
    _tunnel_setup_sandbox
    local plist="$TUNNEL_SANDBOX/t.plist"
    mkdir -p "$TUNNEL_SANDBOX/logs"
    tunnel_generate_plist "$FX_PEER" "$FX_IP" "$TUNNEL_SANDBOX/logs/tunnel-prime.log" "$FX_PEER" "$FX_FWD1" > "$plist"
    assert_ok tunnel_plist_lint "$plist"
    local content
    content="$(cat "$plist")"
    assert_contains "com.tailroute.tunnel.prime" "$content"
    assert_contains "127.0.0.1:8443:100.97.245.83:443" "$content"
    assert_contains "ExitOnForwardFailure" "$content"
    assert_contains "ControlMaster" "$content"
    assert_contains "ControlPath" "$content"
    assert_contains "proxy-prime" "$content"
    assert_contains "tunnel-prime.log" "$content"
}

test_plist_two_forwards() {
    _tunnel_setup_sandbox
    local plist="$TUNNEL_SANDBOX/t.plist"
    tunnel_generate_plist "$FX_PEER" "$FX_IP" "$TUNNEL_SANDBOX/t.log" "$FX_PEER" "$FX_FWD1" 9000:9000 > "$plist"
    assert_ok tunnel_plist_lint "$plist"
    grep -q "127.0.0.1:8443:100.97.245.83:443" "$plist" || { echo "first forward missing"; return 1; }
    grep -q "127.0.0.1:9000:100.97.245.83:9000" "$plist" || { echo "second forward missing"; return 1; }
}

# =============================================================================
# Prototype adoption parsing (T-404.4)
# =============================================================================

_adopt_fixture() {
    cat > "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tailroute.tunnel.prime</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-N</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-L</string>
        <string>8443:100.97.245.83:443</string>
        <string>-L</string>
        <string>10254:100.97.245.83:10254</string>
        <string>proxy-prime</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
}

test_adoption_parse_accepts_prototype() {
    _tunnel_setup_sandbox
    _adopt_fixture
    local out
    out="$(tunnel_parse_existing_plist "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist")"
    assert_contains "8443:443" "$out"
    assert_contains "10254:10254" "$out"
    assert_contains "prime" "$(printf '%s' "$out" | cut -f2)"
}

test_adoption_parse_rejects_reverse_tunnel() {
    _tunnel_setup_sandbox
    _adopt_fixture
    /usr/bin/sed -i '' 's|<string>proxy-prime</string>|<string>-R</string><string>9000:localhost:80</string><string>proxy-prime</string>|' "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    assert_fail tunnel_parse_existing_plist "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
}

test_adoption_parse_rejects_unsafe_option() {
    _tunnel_setup_sandbox
    _adopt_fixture
    /usr/bin/sed -i '' 's|<string>ExitOnForwardFailure=yes</string>|<string>PermitLocalCommand=yes</string>|' "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    assert_fail tunnel_parse_existing_plist "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
}

test_adoption_parse_rejects_public_bind() {
    _tunnel_setup_sandbox
    _adopt_fixture
    /usr/bin/sed -i '' 's|<string>8443:100.97.245.83:443</string>|<string>0.0.0.0:8443:100.97.245.83:443</string>|' "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    assert_fail tunnel_parse_existing_plist "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
}

# =============================================================================
# Lock (T-401.2)
# =============================================================================

test_lock_acquire_release_and_stale() {
    _tunnel_setup_sandbox
    mkdir -p "$TUNNEL_CONFIG_DIR"
    assert_ok tunnel_lock_acquire
    assert_fail tunnel_lock_acquire   # would loop 10s then fail; hold PID alive = this shell
    tunnel_lock_release
    assert_ok tunnel_lock_acquire
    tunnel_lock_release
    # Stale lock (dead PID) is reclaimed
    mkdir -p "$TUNNEL_LOCK_DIR"
    echo 999999 > "$TUNNEL_LOCK_DIR/pid"
    assert_ok tunnel_lock_acquire
    tunnel_lock_release
}

# =============================================================================
# Port allocation (T-402/T-404)
# =============================================================================

test_pick_port_skips_bound_and_registered() {
    _tunnel_setup_sandbox
    FAKE_NC_OPEN="8443 8444"
    local entry
    entry="$(tunnel_build_entry_json taken 100.64.0.9 taken.tailnet.ts.net tailnet.ts.net 8445:443)"
    tunnel_registry_add taken "$entry" >/dev/null
    local picked
    picked="$(tunnel_pick_port)"
    assert_eq 8446 "$picked"
}

# =============================================================================
# Adaptive wrapper (T-410)
# =============================================================================

test_wrapper_install_and_replace_guard() {
    _tunnel_setup_sandbox
    assert_ok tunnel_install_ssh_wrapper no
    [ -x "$TUNNEL_SSH_WRAPPER" ] || { echo "wrapper not executable"; return 1; }
    assert_ok tunnel_install_ssh_wrapper no   # identical content = ok
    printf '#!/bin/sh\nexec /bin/evil\n' > "$TUNNEL_SSH_WRAPPER"
    assert_fail tunnel_install_ssh_wrapper no    # different content, no replace
    assert_ok tunnel_install_ssh_wrapper yes
    assert_contains "SOCKS5 proxy" "$(cat "$TUNNEL_SSH_WRAPPER")"
}

# Legacy wrapper migration (T-433)

test_wrapper_detects_legacy_nc_z_probe() {
    _tunnel_setup_sandbox
    # Write old-style wrapper
    cat > "$TUNNEL_SSH_WRAPPER" <<'WRAP'
#!/bin/sh
if /usr/bin/nc -z 127.0.0.1 1055 2>/dev/null; then
    exec /usr/bin/nc -X 5 -x 127.0.0.1:1055 "$@"
else
    exec /usr/bin/nc "$@"
fi
WRAP
    assert_ok tunnel_ssh_wrapper_is_legacy
}

test_wrapper_not_legacy_after_migration() {
    _tunnel_setup_sandbox
    assert_ok tunnel_install_ssh_wrapper no
    assert_fail tunnel_ssh_wrapper_is_legacy
}

test_wrapper_auto_migrates_legacy() {
    _tunnel_setup_sandbox
    # Write old-style wrapper
    cat > "$TUNNEL_SSH_WRAPPER" <<'WRAP'
#!/bin/sh
if /usr/bin/nc -z 127.0.0.1 1055 2>/dev/null; then
    exec /usr/bin/nc -X 5 -x 127.0.0.1:1055 "$@"
else
    exec /usr/bin/nc "$@"
fi
WRAP
    chmod 0755 "$TUNNEL_SSH_WRAPPER"
    # Install with replace=no should auto-migrate (no prompt)
    assert_ok tunnel_install_ssh_wrapper no
    # New wrapper should be in place (no nc -z)
    if grep -q 'nc -z' "$TUNNEL_SSH_WRAPPER"; then
        _assert_fail "legacy nc -z probe survived migration"
    fi
    assert_contains "SOCKS5 proxy" "$(cat "$TUNNEL_SSH_WRAPPER")"
}

# =============================================================================
# End-to-end add / status / remove against mocks
# =============================================================================

test_add_creates_full_state() {
    _tunnel_setup_sandbox
    local out
    out="$(tunnel_do_add prime --yes)" || { echo "add failed: $out"; return 1; }
    assert_contains "https://prime.tailnet.ts.net:8443" "$out"
    assert_contains '"peer": "prime"' "$(tunnel_registry_get prime)"
    grep -q "127.0.0.1	prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE" || { echo "hosts mapping missing"; return 1; }
    assert_ok tunnel_plist_lint "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    grep -qx "com.tailroute.tunnel.prime" "$LAUNCHCTL_STATE" || { echo "job not bootstrapped"; return 1; }
}

test_add_existing_peer_refuses() {
    _tunnel_setup_sandbox
    FAKE_NC_OPEN="8443"
    tunnel_do_add prime --yes >/dev/null
    local rc=0
    tunnel_do_add prime --yes >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "re-add must refuse (guides to remove)"
}

test_add_rollback_on_bootstrap_failure() {
    _tunnel_setup_sandbox
    FAIL_BOOTSTRAP=1
    local rc=0
    tunnel_do_add prime --yes >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc"
    # Full unwind: no registry entry, no hosts mapping, no plist
    assert_fail tunnel_registry_get prime
    if grep -q "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE"; then
        _assert_fail "hosts mapping survived rollback"
    fi
    [ ! -f "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" ] || { echo "plist survived rollback"; return 1; }
}

test_add_requires_ssh_config_entry() {
    _tunnel_setup_sandbox
    printf '' > "$TUNNEL_SSH_CONFIG"
    local rc=0
    tunnel_do_add prime --yes >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "must abort without proxy-prime entry (no interactive prompt under --yes)"
}

test_add_rejects_hostile_peer_via_lookup() {
    _tunnel_setup_sandbox
    cat > "$FAKE_TS_JSON" <<'JSON'
{
  "CurrentTailnet": {"MagicDNSSuffix": "tailnet.ts.net"},
  "Peer": {
    "node1": {
      "HostName": "prime",
      "DNSName": "prime.tailnet.ts.net.\n127.0.0.1 bank.com",
      "TailscaleIPs": ["100.97.245.83"],
      "Online": true
    }
  }
}
JSON
    local rc=0
    tunnel_do_add prime --yes >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "newline-injected DNSName must be rejected"
    if grep -q "bank.com" "$TUNNEL_HOSTS_FILE"; then
        _assert_fail "arbitrary domain was written to hosts"
    fi
}

test_add_adopts_prototype_job() {
    _tunnel_setup_sandbox
    # peer hostname is "prime" here; use a DIFFERENT alias to prove alias plumbing
    _adopt_fixture
    /usr/bin/sed -i '' 's|<string>proxy-prime</string>|<string>proxy-aliasname</string>|' "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    printf 'Host proxy-aliasname\n    HostName 100.97.245.83\n' >> "$TUNNEL_SSH_CONFIG"
    echo "com.tailroute.tunnel.prime" >> "$LAUNCHCTL_STATE"
    printf '127.0.0.1\tprime.tailnet.ts.net\n' >> "$TUNNEL_HOSTS_FILE"
    local out
    out="$(tunnel_do_add prime --adopt --yes)" || { echo "adoption add failed: $out"; return 1; }
    assert_contains '"sshAlias": "aliasname"' "$(tunnel_registry_get prime)"
    # Adopted forwards preserved verbatim (non-sequential locals included)
    assert_contains '"localPort": 8443' "$(tunnel_registry_get prime)"
    assert_contains '"localPort": 10254' "$(tunnel_registry_get prime)"
    grep -q "127.0.0.1:8443:100.97.245.83:443" "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    grep -q "127.0.0.1:10254:100.97.245.83:10254" "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist"
    # Hosts line migrated into managed block exactly once
    local count
    count="$(grep -c "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE" || true)"
    assert_eq 1 "$count"
}

test_add_with_explicit_ssh_alias() {
    _tunnel_setup_sandbox
    # peer HostName is "prime" but the ssh entry uses an unrelated alias
    printf 'Host proxy-shorty\n    HostName %s\n    ProxyCommand ~/.ssh/tailroute-proxy.sh %%h %%p\n' "$FX_IP" >> "$TUNNEL_SSH_CONFIG"
    local out
    out="$(tunnel_do_add prime --ssh-alias shorty --yes)" || { echo "add with alias failed: $out"; return 1; }
    assert_contains '"sshAlias": "shorty"' "$(tunnel_registry_get prime)"
    grep -q "<string>proxy-shorty</string>" "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" || {
        echo "plist does not use the alias"; return 1; }
}

test_status_healthy_and_degraded() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    # Job loaded + port listening (mock marks 8443 open) -> healthy
    FAKE_NC_OPEN="8443"
    assert_ok tunnel_do_status prime
    local json
    json="$(tunnel_do_status --json)"
    assert_contains '"healthy": true' "$json"
    # Job dies + port closes -> degraded (exit 1)
    grep -vx "com.tailroute.tunnel.prime" "$LAUNCHCTL_STATE" > "$LAUNCHCTL_STATE.tmp" || true
    mv "$LAUNCHCTL_STATE.tmp" "$LAUNCHCTL_STATE"
    FAKE_NC_OPEN=""
    local rc=0
    tunnel_do_status prime >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc"
}

test_status_not_found_and_empty() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_status ghost >/dev/null 2>&1 || rc=$?
    assert_eq 3 "$rc"
    local out
    out="$(tunnel_do_status)"
    assert_contains "No tunnels configured" "$out"
    # T-435: empty JSON also carries adaptivePath and orphans
    assert_contains '"tunnels": []' "$(tunnel_do_status --json)"
    assert_contains '"adaptivePath"' "$(tunnel_do_status --json)"
}

test_remove_cleans_all_state() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    assert_ok tunnel_do_remove prime
    assert_fail tunnel_registry_get prime
    if grep -q "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE"; then
        _assert_fail "hosts mapping survived remove"
    fi
    [ ! -f "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" ] || { echo "plist survived remove"; return 1; }
    grep -qx "com.tailroute.tunnel.prime" "$LAUNCHCTL_STATE" && { echo "job still loaded"; return 1; }
    assert_ok true
}

test_restart_roundtrip() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    assert_ok tunnel_do_restart prime
    grep -qx "com.tailroute.tunnel.prime" "$LAUNCHCTL_STATE" || { echo "job not loaded after restart"; return 1; }
}

test_list_json() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    local line
    line="$(tunnel_do_list)"
    assert_contains '"peer": "prime"' "$line"
    echo "$line" | "$PYTHON3_CMD" -c 'import json,sys; json.loads(sys.stdin.read())' || { echo "list is not JSON"; return 1; }
}

# =============================================================================
# TLS identity verification (T-430)
# =============================================================================

test_tls_verify_valid_cert() {
    _tunnel_setup_sandbox
    FAKE_TLS_HOSTNAME="prime.tailnet.ts.net"
    assert_ok _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_rejects_wrong_hostname() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    assert_fail _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_rejects_expired() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="expired"
    assert_fail _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_rejects_connection_failure() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="fail-connect"
    assert_fail _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_accepts_wildcard() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wildcard"
    assert_ok _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_skip_flag() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    assert_ok tunnel_tls_verify_or_skip prime.tailnet.ts.net 8443 yes
}

test_tls_verify_no_skip() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    assert_fail tunnel_tls_verify_or_skip prime.tailnet.ts.net 8443 no
}

test_tls_verify_accepts_libressl_exit_one() {
    _tunnel_setup_sandbox
    # v0.7.5: LibreSSL s_client exits non-zero after a verified handshake;
    # verification must judge the OUTPUT, not the exit status.
    export FAKE_TLS_HOSTNAME="libressl-ok"
    assert_ok _tun_tls_verify prime.tailnet.ts.net 8443
}

test_tls_verify_rejects_unverified_chain() {
    _tunnel_setup_sandbox
    # cert is presented but the chain does not verify - must be refused even
    # though the hostname matches
    export FAKE_TLS_HOSTNAME="unverified"
    assert_fail _tun_tls_verify prime.tailnet.ts.net 8443
}

test_preflight_warns_when_auth_depends_on_agent() {
    _tunnel_setup_sandbox
    # mock key only authenticates when SSH_AUTH_SOCK is present (launchd
    # jobs run without it) - preflight must warn, not fail
    FAKE_SSH_NEEDS_AGENT=1; export FAKE_SSH_NEEDS_AGENT
    SSH_AUTH_SOCK="/fake/agent.sock"; export SSH_AUTH_SOCK
    local out rc=0
    out="$(tunnel_preflight "$FX_PEER" "$(tunnel_lookup_peer "$FX_PEER")" "$FX_PEER" 2>&1)" || rc=$?
    assert_eq 0 "$rc" "agent-dependent auth must not fail preflight itself"
    assert_contains "launchd tunnel job runs without it" "$out"
    assert_contains "UseKeychain yes" "$out"
}

test_add_rollback_on_tls_failure() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    local rc=0
    tunnel_do_add prime --yes >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc"
    # Full rollback: no registry, no hosts mapping, no plist
    assert_fail tunnel_registry_get prime
    if grep -q "prime.tailnet.ts.net" "$TUNNEL_HOSTS_FILE"; then
        _assert_fail "hosts mapping survived TLS rollback"
    fi
    [ ! -f "$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.prime.plist" ] || { echo "plist survived TLS rollback"; return 1; }
}

test_add_with_allow_unverified_tls_flag() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    local out
    out="$(tunnel_do_add prime --allow-unverified-tls --yes 2>&1)" || { echo "add with --allow-unverified-tls failed: $out"; return 1; }
    assert_contains "skipping TLS identity verification" "$out"
    assert_contains "Tunnel added: prime" "$out"
}

# =============================================================================
# Durable transactions (T-431)
# =============================================================================

test_registry_v2_schema_has_new_fields() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1")"
    tunnel_registry_add prime "$entry" >/dev/null
    local got
    got="$(tunnel_registry_get prime)"
    assert_contains '"peer": "prime"' "$got"
    # v2 fields
    assert_contains '"peerID"' "$got"
    assert_contains '"jobID"' "$got"
    assert_contains '"allowUnverifiedTLS": false' "$got"
    assert_contains '"transactions": []' "$got"
    assert_contains '"magicDNSSuffix": "tailnet.ts.net"' "$got"
}

test_registry_v1_auto_migrates_to_v2() {
    _tunnel_setup_sandbox
    # Write a v1 registry directly (no peerID, jobID, etc.)
    printf '{"version": 1, "tunnels": [{"peer": "oldpeer", "tailscaleIP": "100.64.0.5", "hostname": "old.tailnet.ts.net", "magicDNSSuffix": "tailnet.ts.net", "sshAlias": "oldpeer", "forwards": [{"localPort": 8443, "remotePort": 443}], "plistPath": "/tmp/old.plist", "createdAt": "2026-01-01T00:00:00Z"}]}' > "$TUNNEL_REGISTRY"
    chmod 0600 "$TUNNEL_REGISTRY"
    # Reading should auto-migrate and return v2 fields
    local got
    got="$(tunnel_registry_get oldpeer 2>&1)"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "registry_get failed with rc=$rc: $got" >&2
        return 1
    fi
    assert_contains '"peerID"' "$got"
    assert_contains '"jobID"' "$got"
    assert_contains '"allowUnverifiedTLS": false' "$got"
    assert_contains '"transactions": []' "$got"
    # Registry file should now be version 2
    assert_contains '"version": 2' "$(tunnel_registry_all)"
}

test_registry_v2_stores_allow_unverified_tls() {
    _tunnel_setup_sandbox
    local entry
    # args: peer ip hostname suffix forwards sshAlias allow_unverified_tls
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1" "$FX_PEER" yes)"
    tunnel_registry_add prime "$entry" >/dev/null 2>&1 || { echo "registry_add failed"; return 1; }
    assert_contains '"allowUnverifiedTLS": true' "$(tunnel_registry_get prime 2>&1)"
}

test_journal_written_and_cleared_on_add() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null 2>&1
    # Journal should be cleared after successful add
    [ ! -f "$TUNNEL_JOURNAL_PATH" ] || { echo "journal survives successful add"; return 1; }
}

test_journal_written_and_cleared_on_remove() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null 2>&1
    tunnel_do_remove prime >/dev/null 2>&1
    # Journal should be cleared after successful remove
    [ ! -f "$TUNNEL_JOURNAL_PATH" ] || { echo "journal survives successful remove"; return 1; }
}

test_status_detects_incomplete_journal() {
    _tunnel_setup_sandbox
    # Write an incomplete journal
    printf '{"op":"add","peer":"prime","steps":["registry","hosts","plist"],"completed":["registry"],"pid":99999,"ts":"2026-08-30T05:00:00Z"}' > "$TUNNEL_JOURNAL_PATH"
    local rc=0
    tunnel_do_status >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "status should report incomplete journal"
    # Should mention 'INCOMPLETE JOURNAL'
    local out
    out="$(tunnel_do_status 2>&1)" || true
    assert_contains "INCOMPLETE JOURNAL" "$out"
}

test_hosts_lock_acquired_and_released() {
    _tunnel_setup_sandbox
    # The hosts lock dir should not exist before add
    [ ! -d "$TUNNEL_HOSTS_LOCK_DIR" ] || { echo "hosts lock dir pre-exists"; return 1; }
    tunnel_do_add prime --yes >/dev/null 2>&1
    # After add, hosts lock should be released (dir removed)
    [ ! -d "$TUNNEL_HOSTS_LOCK_DIR" ] || { echo "hosts lock dir not released after add"; return 1; }
}

test_add_with_allow_unverified_tls_persists() {
    _tunnel_setup_sandbox
    export FAKE_TLS_HOSTNAME="wrong-host"
    local out
    out="$(tunnel_do_add prime --allow-unverified-tls --yes 2>&1)" || { echo "add failed: $out"; return 1; }
    assert_contains "Tunnel added: prime" "$out"
    # Verify the registry persists the flag
    assert_contains '"allowUnverifiedTLS": true' "$(tunnel_registry_get prime)"
}

test_remove_all_clears_journal() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null 2>&1
    # Write a stale journal
    printf '{"op":"add","peer":"ghost","steps":["registry"],"completed":[],"pid":1,"ts":"2026-08-30T00:00:00Z"}' > "$TUNNEL_JOURNAL_PATH"
    tunnel_remove_all >/dev/null 2>&1
    [ ! -f "$TUNNEL_JOURNAL_PATH" ] || { echo "journal survives remove_all"; return 1; }
}

# =============================================================================
# Non-interactive plists (T-432)
# =============================================================================

test_plist_contains_batchmode_and_stricthostkey() {
    _tunnel_setup_sandbox
    local plist="$TUNNEL_SANDBOX/t.plist"
    mkdir -p "$TUNNEL_SANDBOX/logs"
    tunnel_generate_plist "$FX_PEER" "$FX_IP" "$TUNNEL_SANDBOX/logs/t.log" "$FX_PEER" "$FX_FWD1" > "$plist"
    local content
    content="$(cat "$plist")"
    assert_ok tunnel_plist_lint "$plist"
    assert_contains "BatchMode=yes" "$content"
    assert_contains "ConnectTimeout=10" "$content"
    assert_contains "StrictHostKeyChecking=yes" "$content"
    # Original options still present
    assert_contains "ExitOnForwardFailure" "$content"
    assert_contains "ControlMaster=no" "$content"
}

test_remove_cleans_log_file() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    # Create a log file (the add doesn't actually create one in sandbox)
    mkdir -p "$TUNNEL_LOG_DIR"
    printf 'test log\n' > "$TUNNEL_LOG_DIR/tunnel-prime.log"
    [ -f "$TUNNEL_LOG_DIR/tunnel-prime.log" ] || { echo "log not created"; return 1; }
    assert_ok tunnel_do_remove prime
    [ ! -f "$TUNNEL_LOG_DIR/tunnel-prime.log" ] || { echo "log survived remove"; return 1; }
}

test_remove_all_cleans_all_logs() {
    _tunnel_setup_sandbox
    tunnel_do_add prime --yes >/dev/null
    mkdir -p "$TUNNEL_LOG_DIR"
    printf 'log1\n' > "$TUNNEL_LOG_DIR/tunnel-prime.log"
    printf 'log2\n' > "$TUNNEL_LOG_DIR/tunnel-alpha.log"
    tunnel_remove_all >/dev/null
    [ ! -f "$TUNNEL_LOG_DIR/tunnel-prime.log" ] || { echo "prime log survived"; return 1; }
    [ ! -f "$TUNNEL_LOG_DIR/tunnel-alpha.log" ] || { echo "alpha log survived"; return 1; }
}

# =============================================================================
# Incremental forwards and per-forward status (T-436)
# =============================================================================

test_t436_update_remote_port_appends_forward() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || { echo "incremental add failed: $out"; return 1; }
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_contains "8443:443" "$fwd"
    assert_contains "8444:8080" "$fwd"
}

test_t436_update_accepts_comma_separated_remote_ports() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8000,8765,10254,10255 --yes 2>&1)" || { echo "comma-list incremental add failed: $out"; return 1; }
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    # all four land in ONE transactional update, in order
    assert_eq "8443:443 8444:8000 8445:8765 8446:10254 8447:10255" "$fwd"
}

test_t436_update_mixed_comma_and_repeated_remote_ports() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8000 --remote-port 8765,10254 --yes 2>&1)" || { echo "mixed-form incremental add failed: $out"; return 1; }
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_eq "8443:443 8444:8000 8445:8765 8446:10254" "$fwd"
}

test_t436_update_rejects_invalid_port_in_comma_list() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out rc=0
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8000,abc --yes 2>&1)" || rc=$?
    assert_eq 2 "$rc" "invalid token in comma list must be rejected before any state changes"
    assert_contains "invalid remote port" "$out"
    # pre-transaction validation: registry untouched
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(len(json.load(sys.stdin)["forwards"]))')"
    assert_eq 1 "$fwd" "registry must be untouched when the list is invalid"
}

test_t436_update_adopts_stored_ssh_alias_without_flag() {
    _tunnel_setup_sandbox
    # tunnel registered with --ssh-alias shorty; config has proxy-shorty but
    # NO proxy-prime - an incremental add without --ssh-alias must adopt the
    # stored alias instead of demanding a new 'proxy-<peer>' entry
    printf 'Host proxy-shorty\n    HostName %s\n    ProxyCommand ~/.ssh/tailroute-proxy.sh %%h %%p\n' "$FX_IP" > "$TUNNEL_SSH_CONFIG"
    tunnel_do_add "$FX_PEER" --ssh-alias shorty --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || { echo "incremental add without alias flag failed: $out"; return 1; }
    if printf '%s' "$out" | grep -q "PREFLIGHT_NEED_SSH_CONFIG"; then
        _assert_fail "stored ssh alias was not adopted: $out"
    fi
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_eq "8443:443 8444:8080" "$fwd"
}

test_t436_update_rejects_duplicate_remote_port() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local rc=0 out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 443 --yes 2>&1)" || rc=$?
    assert_eq 1 "$rc" "duplicate remote port should be refused"
    assert_contains "already forwarded" "$out"
    local n
    n="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(len(json.load(sys.stdin)["forwards"]))')"
    assert_eq 1 "$n" "registry should be unchanged after refused duplicate"
}

test_t436_update_regenerates_job_with_all_forwards() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    tunnel_do_add "$FX_PEER" --remote-port 8080 --yes >/dev/null 2>&1
    local plist="$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.$FX_PEER.plist"
    grep -q "127.0.0.1:8443:$FX_IP:443" "$plist" || { echo "original forward missing from plist"; return 1; }
    grep -q "127.0.0.1:8444:$FX_IP:8080" "$plist" || { echo "new forward missing from plist"; return 1; }
    tunnel_job_is_loaded "$(tunnel_label_for_peer "$FX_PEER")" || { echo "job not running after update"; return 1; }
}

test_t436_update_rollback_on_tls_failure_restores_previous_job() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    FAKE_TLS_HOSTNAME="wrong-host"
    export FAKE_TLS_HOSTNAME
    local rc=0 out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || rc=$?
    assert_eq 1 "$rc" "update should fail on TLS identity mismatch"
    assert_contains "ROLLED BACK" "$out"
    local n
    n="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(len(json.load(sys.stdin)["forwards"]))')"
    assert_eq 1 "$n" "registry should be rolled back to one forward"
    local plist="$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.$FX_PEER.plist"
    grep -q "127.0.0.1:8443:$FX_IP:443" "$plist" || { echo "original forward missing from restored plist"; return 1; }
    if grep -q "8080" "$plist"; then echo "new forward leaked into restored plist"; return 1; fi
    tunnel_job_is_loaded "$(tunnel_label_for_peer "$FX_PEER")" || { echo "previous job not restored"; return 1; }
}

test_t436_update_rollback_on_bootstrap_failure() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    FAIL_BOOTSTRAP=1
    export FAIL_BOOTSTRAP
    local rc=0 out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || rc=$?
    assert_eq 1 "$rc" "update should fail when bootstrap fails"
    assert_contains "ROLLED BACK" "$out"
    local n
    n="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(len(json.load(sys.stdin)["forwards"]))')"
    assert_eq 1 "$n" "registry should be rolled back"
    local plist="$TUNNEL_LAUNCHAGENTS_DIR/com.tailroute.tunnel.$FX_PEER.plist"
    grep -q "127.0.0.1:8443:$FX_IP:443" "$plist" || { echo "original forward missing from restored plist"; return 1; }
    if grep -q "8080" "$plist"; then echo "new forward leaked into restored plist"; return 1; fi
    [ ! -f "$plist.prev" ] || { echo "stale .prev backup left behind"; return 1; }
}

test_t436_status_lists_every_forward() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    tunnel_do_add "$FX_PEER" --remote-port 8080 --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_status --skip-remote-check 2>&1)"
    assert_contains "127.0.0.1:8443 -> remote 443" "$out"
    assert_contains "127.0.0.1:8444 -> remote 8080" "$out"
}

test_t436_status_json_exposes_per_forward_state() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    tunnel_do_add "$FX_PEER" --remote-port 8080 --yes >/dev/null 2>&1
    local json
    json="$(tunnel_do_status --json --skip-remote-check)"
    printf '%s' "$json" | "$PYTHON3_CMD" -c '
import json, sys
d = json.load(sys.stdin)
fw = d["tunnels"][0]["forwards"]
assert len(fw) == 2, fw
assert [(f["localPort"], f["remotePort"]) for f in fw] == [(8443, 443), (8444, 8080)], fw
assert fw[0]["listener"] == "closed", fw[0]
assert fw[0]["backend"] == "n/a", fw[0]
assert fw[0]["tls"] == "verified", fw[0]
print("ok")
' || { echo "json per-forward assertions failed: $json"; return 1; }
}

test_t436_status_json_reports_unverified_tls() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1" "$FX_PEER" yes)"
    tunnel_registry_add "$FX_PEER" "$entry" >/dev/null
    local json
    json="$(tunnel_do_status --json --skip-remote-check)"
    printf '%s' "$json" | "$PYTHON3_CMD" -c '
import json, sys
fw = json.load(sys.stdin)["tunnels"][0]["forwards"]
assert fw[0]["tls"] == "unverified", fw[0]
print("ok")
' || { echo "unverified tls not reported: $json"; return 1; }
}

test_t436_status_mixed_forwards_exit_degraded() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    tunnel_do_add "$FX_PEER" --remote-port 8080 --yes >/dev/null 2>&1
    # 8443 listening, 8444 closed -> mixed: one healthy forward, one degraded
    FAKE_NC_OPEN="8443"
    export FAKE_NC_OPEN
    local rc=0
    tunnel_do_status "$FX_PEER" --skip-remote-check >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "mixed forwards should exit degraded"
    local json
    json="$(tunnel_do_status --json --skip-remote-check)"
    printf '%s' "$json" | "$PYTHON3_CMD" -c '
import json, sys
t = json.load(sys.stdin)["tunnels"][0]
states = {f["localPort"]: f["listener"] for f in t["forwards"]}
assert states == {8443: "listening", 8444: "closed"}, states
assert t["forwards"][0]["healthy"] is True, t["forwards"][0]
assert t["forwards"][1]["healthy"] is False, t["forwards"][1]
assert t["healthy"] is False, t  # any closed listener -> degraded peer
print("ok")
' || { echo "mixed-state json assertions failed: $json"; return 1; }
}

test_t436_update_blocked_by_incomplete_journal() {
    _tunnel_setup_sandbox
    local entry
    entry="$(tunnel_build_entry_json "$FX_PEER" "$FX_IP" "$FX_HOSTNAME" "$FX_SUFFIX" "$FX_FWD1")"
    tunnel_registry_add "$FX_PEER" "$entry" >/dev/null
    printf '{"op":"update","peer":"prime","steps":["registry","plist"],"completed":["registry"],"pid":99999,"ts":"2026-08-31T00:00:00Z"}' > "$TUNNEL_JOURNAL_PATH"
    local rc=0 out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || rc=$?
    assert_eq 1 "$rc" "update should refuse while an update journal is incomplete"
    assert_contains "incomplete journal" "$out"
    assert_contains '"forwards": [{"localPort": 8443, "remotePort": 443}]' "$(tunnel_registry_get "$FX_PEER")"
}

# =============================================================================
# Remote backend probe target + incremental add output (v0.7.8)
# =============================================================================
# Tailscale Serve listeners bind the peer's tailscale interface, not its
# loopback, and the launchd forward targets <peer-ip>:<rport> — so the
# backend check must ask the PEER about its tailscale IP. Probing the peer's
# 127.0.0.1 reports every healthy serve target as down.

test_probe_backend_targets_peer_ts_ip() {
    _tunnel_setup_sandbox
    # Real-world shape: loopback refuses, tailscale IP answers
    FAKE_REMOTE_NC_REFUSE="127.0.0.1:443"
    export FAKE_REMOTE_NC_REFUSE
    local out
    out="$(tunnel_do_add "$FX_PEER" --yes 2>&1)" || { echo "add failed: $out"; return 1; }
    if printf '%s' "$out" | grep -q "not accepting on $FX_PEER"; then
        _assert_fail "healthy serve target reported as not accepting: $out"
    fi
    assert_contains "/usr/bin/nc -z $FX_IP 443" "$(cat "$FAKE_PROBE_LOG")"
}

test_probe_backend_warns_when_target_refuses() {
    _tunnel_setup_sandbox
    FAKE_REMOTE_NC_REFUSE="$FX_IP:443"
    export FAKE_REMOTE_NC_REFUSE
    local out
    out="$(tunnel_do_add "$FX_PEER" --yes 2>&1)" || { echo "add failed: $out"; return 1; }
    assert_contains "WARN: remote port 443 not accepting on $FX_PEER" "$out"
}

test_status_backend_probe_targets_peer_ts_ip() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    FAKE_REMOTE_NC_REFUSE="127.0.0.1:443"
    export FAKE_REMOTE_NC_REFUSE
    : > "$FAKE_PROBE_LOG"
    local out
    out="$(tunnel_do_status "$FX_PEER" 2>&1 || true)"
    assert_contains "backend accepting" "$out"
    assert_contains "/usr/bin/nc -z $FX_IP 443" "$(cat "$FAKE_PROBE_LOG")"
}

test_incremental_add_prints_forward_added_once_after_urls() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_add "$FX_PEER" --remote-port 8080 --yes 2>&1)" || { echo "incremental add failed: $out"; return 1; }
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^Forward added:')" "exactly one 'Forward added' line expected"
    local url_line added_line
    url_line="$(printf '%s\n' "$out" | grep -n 'URL:.*8444' | head -1 | cut -d: -f1)"
    added_line="$(printf '%s\n' "$out" | grep -n '^Forward added:' | head -1 | cut -d: -f1)"
    [ -n "$url_line" ] || { echo "no URL line for the new forward: $out"; return 1; }
    [ -n "$added_line" ] || { echo "no 'Forward added' line: $out"; return 1; }
    [ "$url_line" -lt "$added_line" ] || _assert_fail "URL list must precede 'Forward added': $out"
}

# =============================================================================
# Production-asymmetry hardening (v0.7.4)
# =============================================================================

test_hosts_edits_use_writable_mktemp() {
    _tunnel_setup_sandbox
    export MKTEMP_LOG="$TUNNEL_SANDBOX/mktemp.log"; : > "$MKTEMP_LOG"
    MKTEMP_CMD="$TUNNEL_SANDBOX/bin/mktemp-logger"
    cat > "$MKTEMP_CMD" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" >> "$MKTEMP_LOG"
exec /usr/bin/mktemp "$@"
MOCK
    chmod +x "$MKTEMP_CMD"; export MKTEMP_CMD
    # unmanaged line (pre-marker era): adopt must migrate it into the block
    printf '127.0.0.1\t%s\n' "$FX_HOSTNAME" >> "$TUNNEL_HOSTS_FILE"
    tunnel_hosts_adopt_mapping "$FX_HOSTNAME"
    local n; n="$(grep -c "$FX_HOSTNAME" "$TUNNEL_HOSTS_FILE")"
    assert_eq 1 "$n" "adopt should leave exactly one managed line"
    tunnel_hosts_apply add "$FX_HOSTNAME"
    n="$(grep -c "$FX_HOSTNAME" "$TUNNEL_HOSTS_FILE")"
    assert_eq 1 "$n" "apply must stay idempotent"
    if grep -q "tailroute.XXXXXX" "$MKTEMP_LOG"; then
        _assert_fail "mktemp was handed a hosts-dir template - temp must live in user-writable TMPDIR"
    fi
}

test_hosts_lock_acquires_via_sudo_fallback() {
    _tunnel_setup_sandbox
    mkdir -p "$TUNNEL_SANDBOX/locked-parent"
    chmod 555 "$TUNNEL_SANDBOX/locked-parent"          # production: /var/db/tailroute is root-owned
    TUNNEL_HOSTS_LOCK_DIR="$TUNNEL_SANDBOX/locked-parent/hosts.lock"
    export TUNNEL_HOSTS_LOCK_TRIES=2                   # fast busy path; no contention elsewhere
    export TUNNEL_SUDO_LOG="$TUNNEL_SANDBOX/sudo.log"; : > "$TUNNEL_SUDO_LOG"; export TUNNEL_SUDO_LOG
    # Passthrough sudo: same-uid, so it cannot truly elevate — assert the
    # INVOCATIONS (shape + count), not elevation outcomes.
    cat > "$TUNNEL_SANDBOX/bin/sudo" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TUNNEL_SUDO_LOG"
if [ "$1" = "/bin/sh" ] && [ "$2" = "-c" ]; then
    exec /bin/sh -c "$3"        # tunnel_privileged_run shape
fi
exec "$@"                       # direct calls (release/stale-removal: rm -rf)
MOCK
    chmod +x "$TUNNEL_SANDBOX/bin/sudo"
    export TUNNEL_SUDO_CMD="$TUNNEL_SANDBOX/bin/sudo"
    local rc=0
    tunnel_hosts_lock_acquire "$TUNNEL_HOSTS_LOCK_DIR" 2>/dev/null || rc=$?
    assert_eq 1 "$rc" "unwritable parent without working elevation must degrade gracefully (busy)"
    if [ -e "$TUNNEL_HOSTS_LOCK_DIR" ]; then
        _assert_fail "busy acquire must not leave a lock dir behind"
    fi
    local n
    n="$(grep -c "mkdir -p" "$TUNNEL_SUDO_LOG" || true)"
    assert_eq 1 "$n" "sudo fallback must be attempted exactly once per acquire call"
    grep -q "chown" "$TUNNEL_SUDO_LOG" || { _assert_fail "fallback must hand the lock dir to the user"; }
    # Simulate the fallback having succeeded: parent now writable.
    chmod 755 "$TUNNEL_SANDBOX/locked-parent"
    assert_ok tunnel_hosts_lock_acquire "$TUNNEL_HOSTS_LOCK_DIR"
    [ -f "$TUNNEL_HOSTS_LOCK_DIR/pid" ] || { _assert_fail "pid file missing after acquire"; }
    n="$(grep -c "mkdir -p" "$TUNNEL_SUDO_LOG" || true)"
    assert_eq 1 "$n" "writable parent must take the plain mkdir path (no sudo)"
    assert_ok tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"
    [ ! -d "$TUNNEL_HOSTS_LOCK_DIR" ] || { _assert_fail "lock dir not released"; }
}

test_preflight_surfaces_policy_denial_and_full_rerun() {
    _tunnel_setup_sandbox
    printf 'Host proxy-shorty\n    HostName %s\n    ProxyCommand ~/.ssh/tailroute-proxy.sh %%h %%p\n' "$FX_IP" >> "$TUNNEL_SSH_CONFIG"
    lookup="$(tunnel_lookup_peer "$FX_PEER")"
    FAKE_SSH_STDERR="tailscale: tailnet policy does not permit you to SSH to this node"
    export FAKE_SSH_STDERR
    local out rc=0
    out="$(tunnel_preflight "$FX_PEER" "$lookup" shorty 2>&1)" || rc=$?
    assert_eq 1 "$rc" "preflight should fail on policy denial"
    assert_contains "ssh said: $FAKE_SSH_STDERR" "$out"
    assert_contains "Tailscale SSH enabled" "$out"
    assert_contains "tailroute tunnel add $FX_PEER --ssh-alias shorty" "$out"
}

# =============================================================================
# Serve port autodetect (T-413)
# =============================================================================

test_t413_add_autodetects_serve_ports() {
    _tunnel_setup_sandbox
    FAKE_SERVE_STATUS='{"Web":{"https://prime.tailnet.ts.net:8443":{"Handlers":{"/":{"Backend":"http://127.0.0.1:3000"}}}}}'
    export FAKE_SERVE_STATUS
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_eq "8443:8443" "$fwd" "autodetected serve listen port should be the forward target"
}

test_t413_add_falls_back_silently_without_serve() {
    _tunnel_setup_sandbox
    # FAKE_SERVE_STATUS unset — locked-down peer; fall back to 443 without noise
    local out
    out="$(tunnel_do_add "$FX_PEER" --yes 2>&1)"
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_eq "8443:443" "$fwd" "locked-down peer falls back to 443"
    if printf '%s' "$out" | grep -qi "serve"; then
        _assert_fail "fallback should be silent, got: $out"
    fi
}

test_t413_add_autodetects_multiple_serve_ports() {
    _tunnel_setup_sandbox
    FAKE_SERVE_STATUS='{"Web":{"https://prime.tailnet.ts.net:8443":{"Handlers":{"/":{"Backend":"http://127.0.0.1:3000"}}},"http://prime.tailnet.ts.net:3000":{"Handlers":{"/":{"Backend":"http://127.0.0.1:5000"}}}}}'
    export FAKE_SERVE_STATUS
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local fwd
    fwd="$(tunnel_registry_get "$FX_PEER" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
    assert_eq "8443:8443 8444:3000" "$fwd" "each serve listen port becomes a forward"
}

# =============================================================================
# Tunnel open (T-420)
# =============================================================================

test_t420_open_opens_bookmark_url() {
    _tunnel_setup_sandbox
    tunnel_do_add "$FX_PEER" --yes >/dev/null 2>&1
    local out
    out="$(tunnel_do_open "$FX_PEER" 2>&1)" || { echo "open failed: $out"; return 1; }
    assert_contains "https://$FX_HOSTNAME:8443" "$out"
    assert_contains "https://$FX_HOSTNAME:8443" "$(cat "$FAKE_OPEN_LOG")"
}

test_t420_open_unknown_peer_fails() {
    _tunnel_setup_sandbox
    local rc=0
    tunnel_do_open ghost >/dev/null 2>&1 || rc=$?
    assert_eq 3 "$rc" "unknown peer should exit 3 like status"
}
