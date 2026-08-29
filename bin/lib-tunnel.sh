#!/usr/bin/env bash
# lib-tunnel.sh — Browser tunnel management for tailroute (PRD-004 / tasks-005)
#
# Manages launchd-backed SSH local forwards ("tunnels") that let a browser
# reach Tailscale Serve endpoints on peers while a VPN is active:
#
#   browser → https://<peer>.<tailnet>.ts.net:<port>
#          → /etc/hosts (managed block) → 127.0.0.1:<port>
#          → ssh -L forward → peer's Tailscale Serve (valid TLS)
#
# Security model (see tasks-005 "Adversarial review outcomes"):
#   - Peer data from `tailscale status --json` is semi-untrusted (hostnames
#     are self-reported by other tailnet members). Everything is validated
#     (tunnel_validate_*) before it reaches plist XML, /etc/hosts, the SSH
#     config, the registry, or a shell string.
#   - Hosts mappings are restricted to *.<current-tailnet-suffix> — the
#     managed block can never map an arbitrary domain.
#   - add/remove are transactional under a user-space lock; /etc/hosts is
#     modified by a single privileged act with in-act symlink checks.
#
# Bash 3.2 compatible: LaunchAgents resolve `env bash` to /bin/bash under
# launchd. No mapfile, no declare -A, no ${var,,}.

# Guard: prevent re-sourcing
if [[ "${_TUNNEL_SOURCED:-0}" == "1" ]]; then
    return 0
fi
readonly _TUNNEL_SOURCED=1

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths and commands — overridable for tests
# -----------------------------------------------------------------------------
TUNNEL_CONFIG_DIR="${TUNNEL_CONFIG_DIR:-$HOME/.config/tailroute}"
TUNNEL_REGISTRY="${TUNNEL_REGISTRY:-$TUNNEL_CONFIG_DIR/tunnels.json}"
TUNNEL_LOCK_DIR="${TUNNEL_LOCK_DIR:-$TUNNEL_CONFIG_DIR/tunnel.lock}"
TUNNEL_HOSTS_FILE="${TUNNEL_HOSTS_FILE:-/etc/hosts}"
TUNNEL_LAUNCHAGENTS_DIR="${TUNNEL_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
TUNNEL_LOG_DIR="${TUNNEL_LOG_DIR:-$HOME/Library/Logs/Tailroute}"
TUNNEL_SSH_CONFIG="${TUNNEL_SSH_CONFIG:-$HOME/.ssh/config}"
TUNNEL_SSH_WRAPPER="${TUNNEL_SSH_WRAPPER:-$HOME/.ssh/tailroute-proxy.sh}"

TUNNEL_REGISTRY_VERSION=1
TUNNEL_PORT_START="${TUNNEL_PORT_START:-8443}"
OPENSSL_CMD="${OPENSSL_CMD:-/usr/bin/openssl}"
TUNNEL_TLS_VERIFY_TIMEOUT="${TUNNEL_TLS_VERIFY_TIMEOUT:-5}"
TUNNEL_PORT_END="${TUNNEL_PORT_END:-8499}"
TUNNEL_LABEL_PREFIX="com.tailroute.tunnel"
TUNNEL_HOSTS_BEGIN="# BEGIN tailroute-tunnel"
TUNNEL_HOSTS_END="# END tailroute-tunnel"

# Commands (absolute paths; overridable for tests; TUNNEL_SUDO_CMD="" runs
# the privileged code path unprivileged against a test hosts file)
DSCL_CMD="${DSCL_CMD:-/usr/bin/dscl}"
ID_CMD="${ID_CMD:-/usr/bin/id}"
TAILSCALE_CMD="${TAILSCALE_CMD:-/opt/homebrew/bin/tailscale}"
SSH_CMD="${SSH_CMD:-/usr/bin/ssh}"
NC_CMD="${NC_CMD:-/usr/bin/nc}"
PLUTIL_CMD="${PLUTIL_CMD:-/usr/bin/plutil}"
LAUNCHCTL_CMD="${LAUNCHCTL_CMD:-/bin/launchctl}"
DSCACHEUTIL_CMD="${DSCACHEUTIL_CMD:-/usr/bin/dscacheutil}"
PYTHON3_CMD="${PYTHON3_CMD:-/usr/bin/python3}"
MKTEMP_CMD="${MKTEMP_CMD:-/usr/bin/mktemp}"
# ${VAR:-sudo} would also override an explicitly-empty value; tests set
# TUNNEL_SUDO_CMD="" to run the privileged path unprivileged.
if [ -z "${TUNNEL_SUDO_CMD+x}" ]; then
    TUNNEL_SUDO_CMD="sudo"
fi

# -----------------------------------------------------------------------------
# Target user resolution (for sudo contexts)
# -----------------------------------------------------------------------------
# When tailroute runs under sudo, $HOME points to root's home, not the
# invoking user's.  _tr_resolve_target_user determines the real user and
# their home directory so that per-user state (config, tunnels, launchd)
# is cleaned up correctly.
#
# Sets _TR_TARGET_USER and _TR_TARGET_HOME on success.
# Returns 0 on success, 1 on error (message printed to stderr).
# Overridable for tests: DSCL_CMD, ID_CMD.
_tr_resolve_target_user() {
    _TR_TARGET_USER=""
    _TR_TARGET_HOME=""

    # Not under sudo — use current environment
    if [ -z "${SUDO_USER:-}" ]; then
        _TR_TARGET_USER="${USER:-$(id -un)}"
        _TR_TARGET_HOME="$HOME"
        return 0
    fi

    # SUDO_USER=root is an error (someone did sudo -u root)
    if [ "$SUDO_USER" = "root" ]; then
        echo "ERROR: SUDO_USER=root — cannot determine the real user" >&2
        return 1
    fi

    _TR_TARGET_USER="$SUDO_USER"

    # Look up home directory via dscl (authoritative on macOS)
    local dscl_home
    dscl_home="$("$DSCL_CMD" . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory:[[:space:]]*//')" || true

    if [ -n "$dscl_home" ]; then
        _TR_TARGET_HOME="$dscl_home"
    elif [ -d "/Users/$SUDO_USER" ]; then
        # Fallback: conventional home path
        _TR_TARGET_HOME="/Users/$SUDO_USER"
    else
        echo "ERROR: user '$SUDO_USER' does not exist or has no home directory" >&2
        return 1
    fi

    return 0
}

# Tunnel ssh options: forwards must fail loudly, and the tunnel must never
# join a user's ControlMaster session (closing an interactive
# `ssh proxy-<peer>` would otherwise kill it).
TUNNEL_SSH_OPTS="-o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=no -o ControlPath=none -o ControlPersist=no"

# -----------------------------------------------------------------------------
# Validation — hard gate before any peer-derived data is used
# -----------------------------------------------------------------------------
# Peer label (post lowercase-normalization): no leading dash (also prevents
# ssh argument injection), max DNS label length.
tunnel_validate_peer_label() {
    local re='^[a-z0-9][a-z0-9-]{0,62}$'
    [[ "$1" =~ $re ]]
}

# The MagicDNS suffix must itself look like <labels>.ts.net before the
# "hostname ends with suffix" check can be trusted.
tunnel_validate_suffix() {
    local re='^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$'
    [[ -n "$1" && "$1" =~ $re ]]
}

tunnel_validate_hostname() {
    local hostname="$1" suffix="$2"
    tunnel_validate_suffix "$suffix" || return 1
    [[ "$hostname" == *."$suffix" ]] || return 1
    tunnel_validate_peer_label "${hostname%."$suffix"}"
}

# IPv4 inside Tailscale CGNAT 100.64.0.0/10 (first octet 100.64–100.127)
tunnel_validate_cgnat_ip() {
    local ip="$1"
    local re='^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.([0-9]{1,3})\.([0-9]{1,3})$'
    [[ "$ip" =~ $re ]] || return 1
    local o3 o4
    o3="${ip#100.*.*.}"; o3="${o3%%.*}"
    o4="${ip##*.}"
    [ "$o3" -le 255 ] && [ "$o4" -le 255 ]
}

tunnel_validate_port() {
    local re='^[0-9]+$'
    [[ "$1" =~ $re ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

tunnel_normalize_lower() {
    # ASCII-only by design: non-ASCII input must fail validation, not be folded
    # shellcheck disable=SC2018,SC2019
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

tunnel_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

tunnel_label_for_peer() {
    printf '%s.%s' "$TUNNEL_LABEL_PREFIX" "$1"
}

tunnel_plist_path_for_peer() {
    printf '%s/%s.%s.plist' "$TUNNEL_LAUNCHAGENTS_DIR" "$TUNNEL_LABEL_PREFIX" "$1"
}

# Run a shell script privileged (sudo) or directly when TUNNEL_SUDO_CMD is
# empty (tests exercise the exact same code path without root).
tunnel_privileged_run() {
    if [ -n "$TUNNEL_SUDO_CMD" ]; then
        "$TUNNEL_SUDO_CMD" /bin/sh -c "$@"
    else
        /bin/sh -c "$@"
    fi
}

# -----------------------------------------------------------------------------
# Transaction lock (user-space, mkdir-based — same pattern as lib-lock.sh)
# -----------------------------------------------------------------------------
tunnel_lock_acquire() {
    local waited=0 lock_pid
    while true; do
        if mkdir "$TUNNEL_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$TUNNEL_LOCK_DIR/pid"
            return 0
        fi
        lock_pid="$(cat "$TUNNEL_LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "$TUNNEL_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -ge 10 ]; then
            echo "ERROR: another tailroute tunnel operation is in progress ($TUNNEL_LOCK_DIR)" >&2
            return 1
        fi
        sleep 1
    done
}

tunnel_lock_release() {
    rm -rf "$TUNNEL_LOCK_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Registry (versioned JSON, atomic write, 0600, .bak retained)
# -----------------------------------------------------------------------------
tunnel_registry_check_env() {
    if [[ -L "$TUNNEL_CONFIG_DIR" ]]; then
        echo "ERROR: $TUNNEL_CONFIG_DIR is a symlink — refusing" >&2
        return 1
    fi
    mkdir -p "$TUNNEL_CONFIG_DIR"
    chmod 0700 "$TUNNEL_CONFIG_DIR"
    if [[ -L "$TUNNEL_REGISTRY" ]]; then
        echo "ERROR: $TUNNEL_REGISTRY is a symlink — refusing" >&2
        return 1
    fi
    return 0
}

# tunnel_registry_op <mode> [peer] [entry-json-or-ip]
# modes: all | get <peer> | add <peer> <entry> | remove <peer> | update-ip <peer> <ip>
# Exit: 0 ok · 2 invalid data · 4 already registered · 5 not found · 6 registry corrupt/version
tunnel_registry_op() {
    TUNNEL_REGISTRY_PATH="$TUNNEL_REGISTRY" \
    TUNNEL_REG_VERSION="$TUNNEL_REGISTRY_VERSION" \
    TUNNEL_REG_MODE="$1" \
    TUNNEL_REG_PEER="${2:-}" \
    TUNNEL_REG_ENTRY="${3:-}" \
    "$PYTHON3_CMD" <<'PY'
import json, os, re, sys, tempfile

path = os.environ["TUNNEL_REGISTRY_PATH"]
expected_version = int(os.environ["TUNNEL_REG_VERSION"])
mode = os.environ["TUNNEL_REG_MODE"]
peer = os.environ.get("TUNNEL_REG_PEER", "")
entry_raw = os.environ.get("TUNNEL_REG_ENTRY", "")

def die(code, msg):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
CGNAT_RE = re.compile(r"^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.([0-9]{1,3})\.([0-9]{1,3})$")

def load():
    if not os.path.exists(path):
        return {"version": expected_version, "tunnels": []}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        die(6, "ERROR: registry corrupt (%s): %s\nRestore %s.bak or remove and re-add tunnels." % (path, e, path))
    if not isinstance(data, dict) or data.get("version") != expected_version:
        got = data.get("version") if isinstance(data, dict) else "?"
        die(6, "ERROR: registry version unsupported (%s); expected %s" % (got, expected_version))
    if not isinstance(data.get("tunnels"), list):
        die(6, "ERROR: registry corrupt: 'tunnels' is not a list")
    return data

def validate_entry(entry):
    if not LABEL_RE.match(entry.get("peer", "")):
        die(2, "ERROR: invalid peer label in entry")
    if not CGNAT_RE.match(entry.get("tailscaleIP", "")):
        die(2, "ERROR: invalid Tailscale IP in entry")
    hostname = entry.get("hostname", "")
    suffix = entry.get("magicDNSSuffix", "")
    if not (suffix.endswith(".ts.net") and hostname.endswith("." + suffix)
            and LABEL_RE.match(hostname[: -(len(suffix) + 1)])):
        die(2, "ERROR: hostname/suffix invariant violated")
    if "sshAlias" in entry and not LABEL_RE.match(entry["sshAlias"]):
        die(2, "ERROR: invalid sshAlias")
    fw = entry.get("forwards", [])
    if not isinstance(fw, list) or not fw:
        die(2, "ERROR: forwards must be a non-empty list")
    for f in fw:
        lp, rp = f.get("localPort"), f.get("remotePort")
        if not (isinstance(lp, int) and 1 <= lp <= 65535 and isinstance(rp, int) and 1 <= rp <= 65535):
            die(2, "ERROR: invalid port in forwards")

def save(data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tunnels.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        bak = path + ".bak"
        if os.path.islink(bak):
            os.unlink(bak)
        if os.path.exists(path):
            os.replace(path, bak)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

data = load()
tunnels = data["tunnels"]

if mode == "all":
    print(json.dumps(data))
elif mode == "get":
    for t in tunnels:
        if t["peer"] == peer:
            print(json.dumps(t))
            sys.exit(0)
    die(5, "ERROR: tunnel for '%s' not found" % peer)
elif mode == "add":
    try:
        entry = json.loads(entry_raw)
    except Exception:
        die(2, "ERROR: invalid entry JSON")
    validate_entry(entry)
    for t in tunnels:
        if t["peer"] == peer:
            die(4, "ERROR: tunnel for '%s' already registered — remove it first" % peer)
    tunnels.append(entry)
    save(data)
elif mode == "remove":
    kept = [t for t in tunnels if t["peer"] != peer]
    if len(kept) == len(tunnels):
        die(5, "ERROR: tunnel for '%s' not found" % peer)
    data["tunnels"] = kept
    save(data)
elif mode == "update-ip":
    hit = False
    for t in tunnels:
        if t["peer"] == peer:
            if not CGNAT_RE.match(entry_raw):
                die(2, "ERROR: invalid IP for update")
            t["tailscaleIP"] = entry_raw
            hit = True
    if not hit:
        die(5, "ERROR: tunnel for '%s' not found" % peer)
    save(data)
else:
    die(2, "ERROR: unknown registry mode %s" % mode)
PY
}

tunnel_registry_all() {
    tunnel_registry_check_env || return 1
    tunnel_registry_op all
}

tunnel_registry_get()   { tunnel_registry_op get "$1"; }
tunnel_registry_add()   { tunnel_registry_op add "$1" "$2"; }
tunnel_registry_remove(){ tunnel_registry_op remove "$1"; }

# Python one-shots over registry JSON (kept trivial; validation lives in the registry op)
tunnel_registry_field() { # <entry-json> <field>
    printf '%s' "$1" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin)["'"$2"'"])'
}

tunnel_registry_entries() { # emits one entry JSON per line
    tunnel_registry_all | "$PYTHON3_CMD" -c '
import json, sys
for t in json.load(sys.stdin)["tunnels"]:
    print(json.dumps(t))
'
}

# -----------------------------------------------------------------------------
# Tailscale lookups (tailscale status --json via python3)
# -----------------------------------------------------------------------------
# Prints TSV: hostname<TAB>dnsname<TAB>ip<TAB>suffix<TAB>online
tunnel_lookup_peer() {
    local peer="$1" status_json
    status_json="$("$TAILSCALE_CMD" status --json 2>/dev/null)" || {
        echo "ERROR: tailscale status failed" >&2
        return 1
    }
    TUNNEL_LOOKUP_PEER="$peer" TS_STATUS_JSON="$status_json" "$PYTHON3_CMD" <<'PY'
import json, os, sys

peer = os.environ["TUNNEL_LOOKUP_PEER"].lower()
try:
    data = json.loads(os.environ["TS_STATUS_JSON"])
except Exception:
    sys.stderr.write("ERROR: cannot parse tailscale status\n")
    sys.exit(2)

tailnet = data.get("CurrentTailnet") or {}
suffix = tailnet.get("MagicDNSSuffix", "") or data.get("MagicDNSSuffix", "") or ""
if not suffix:
    sys.stderr.write("ERROR: no MagicDNS suffix (logged out?)\n")
    sys.exit(2)

for p in (data.get("Peer") or {}).values():
    hostname = (p.get("HostName") or "").lower()
    dns = (p.get("DNSName") or "").rstrip(".").lower()
    if peer not in (hostname, dns):
        continue
    ip = ""
    for candidate in p.get("TailscaleIPs") or []:
        if ":" not in candidate:
            ip = candidate
            break
    if not ip:
        sys.stderr.write("ERROR: peer has no IPv4 address\n")
        sys.exit(2)
    online = "yes" if p.get("Online") else "no"
    print("\t".join([hostname, dns, ip, suffix, online]))
    sys.exit(0)

sys.stderr.write("ERROR: peer '%s' not found in tailnet\n" % peer)
sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# Managed /etc/hosts block
# -----------------------------------------------------------------------------
# Emit file content with exactly one trailing newline (command substitution
# strips trailing newlines; re-adding one keeps hosts stable across edits).
tunnel_hosts_normalize() {
    printf '%s\n' "$(cat "$1" 2>/dev/null || true)"
}

# tunnel_hosts_transform <file> <add|remove> <hostname> — emits new content
# on stdout; refuses duplicate/unbalanced markers; only touches lines inside
# the managed markers, and on remove only exact-mapping lines.
tunnel_hosts_transform() {
    local file="$1" action="$2" hostname="$3"
    local begins ends
    begins="$(grep -c "^${TUNNEL_HOSTS_BEGIN}\$" "$file" 2>/dev/null || true)"
    ends="$(grep -c "^${TUNNEL_HOSTS_END}\$" "$file" 2>/dev/null || true)"
    begins="${begins:-0}"; ends="${ends:-0}"
    if [ "$begins" -gt 1 ] || [ "$ends" -gt 1 ]; then
        echo "ERROR: duplicate tailroute-tunnel markers in $file — refusing to edit; fix manually" >&2
        return 1
    fi
    if [ "$begins" -ne "$ends" ]; then
        echo "ERROR: unbalanced tailroute-tunnel markers in $file — refusing to edit; fix manually" >&2
        return 1
    fi

    if [ "$action" = "add" ]; then
        if grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+${hostname}([[:space:]]|\$)" "$file" 2>/dev/null; then
            tunnel_hosts_normalize "$file"   # already mapped — idempotent
            return 0
        fi
        if [ "$begins" = "1" ]; then
            awk -v h="$hostname" -v end="$TUNNEL_HOSTS_END" '
                { print }
                $0 == end { print "127.0.0.1\t" h }
            ' "$file"
        else
            tunnel_hosts_normalize "$file"
            printf '\n%s\n127.0.0.1\t%s\n%s\n' "$TUNNEL_HOSTS_BEGIN" "$hostname" "$TUNNEL_HOSTS_END"
        fi
    elif [ "$action" = "remove" ]; then
        awk -v h="$hostname" -v begin="$TUNNEL_HOSTS_BEGIN" -v end="$TUNNEL_HOSTS_END" '
            BEGIN { inblock = 0 }
            $0 == begin { inblock = 1; print; next }
            $0 == end   { inblock = 0; print; next }
            inblock && $0 ~ ("^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+" h "([[:space:]]|$)") { next }
            { print }
        ' "$file"
    else
        echo "ERROR: unknown hosts action '$action'" >&2
        return 1
    fi
}

# tunnel_hosts_apply <add|remove> <hostname>
# Single privileged act: symlink/regular-file checks run INSIDE the
# privileged shell (TOCTOU-safe); tmp created with mktemp in the hosts
# directory; atomic install; verify after write.
tunnel_hosts_apply() {
    local action="$1" hostname="$2"
    local hosts="$TUNNEL_HOSTS_FILE"
    local new_content tmp
    new_content="$(tunnel_hosts_transform "$hosts" "$action" "$hostname")" || return 1
    tmp="$("$MKTEMP_CMD" "${hosts}.tailroute.XXXXXX")"
    printf '%s\n' "$new_content" > "$tmp"

    # shellcheck disable=SC2016  # script runs privileged; vars passed as $1/$2
    if ! tunnel_privileged_run '
            set -e
            h="$1"; t="$2"
            [ ! -L "$h" ] || { echo "ERROR: $h is a symlink — refusing" >&2; exit 91; }
            [ -f "$h" ] || { echo "ERROR: $h is missing" >&2; exit 92; }
            chown root:wheel "$t" 2>/dev/null || true
            chmod 0644 "$t"
            mv -f "$t" "$h"
        ' _ "$hosts" "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: failed to update $hosts (sudo declined or check failed)" >&2
        return 1
    fi

    "$DSCACHEUTIL_CMD" -flushcache 2>/dev/null || true

    if [ "$action" = "add" ]; then
        grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+${hostname}([[:space:]]|\$)" "$hosts" || {
            echo "ERROR: post-write verification failed for $hosts" >&2
            return 1
        }
    else
        if grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+${hostname}([[:space:]]|\$)" "$hosts" 2>/dev/null; then
            echo "ERROR: post-write verification failed (mapping still present)" >&2
            return 1
        fi
    fi
    return 0
}

tunnel_hosts_has_mapping() {
    grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+${1}([[:space:]]|\$)" "$TUNNEL_HOSTS_FILE" 2>/dev/null
}

# Migrate an unmanaged mapping into the managed block (adoption)
tunnel_hosts_adopt_mapping() {
    local hostname="$1"
    local hosts="$TUNNEL_HOSTS_FILE"
    if awk -v h="$hostname" -v begin="$TUNNEL_HOSTS_BEGIN" -v end="$TUNNEL_HOSTS_END" '
        BEGIN { inblock = 0; found = 0 }
        $0 == begin { inblock = 1; next }
        $0 == end   { inblock = 0; next }
        inblock && $0 ~ ("^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+" h "([[:space:]]|$)") { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$hosts" 2>/dev/null; then
        return 0   # already inside the managed block
    fi
    local tmp
    tmp="$("$MKTEMP_CMD" "${hosts}.tailroute.XXXXXX")"
    grep -Ev "^[[:space:]]*127\.0\.0\.1[[:space:]]+${hostname}([[:space:]]|\$)" "$hosts" > "$tmp" || true
    # shellcheck disable=SC2016
    if ! tunnel_privileged_run '
            set -e
            h="$1"; t="$2"
            [ ! -L "$h" ] || exit 91
            [ -f "$h" ] || exit 92
            chown root:wheel "$t" 2>/dev/null || true
            chmod 0644 "$t"
            mv -f "$t" "$h"
        ' _ "$hosts" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    tunnel_hosts_apply add "$hostname"
}

# -----------------------------------------------------------------------------
# Plist generation and launchd lifecycle
# -----------------------------------------------------------------------------
tunnel_generate_plist() {
    local peer="$1" ip="$2" log_path="$3" ssh_alias="$4"
    shift 4
    local esc_label esc_log esc_ssh esc_ip opt pair lport rport
    esc_label="$(tunnel_xml_escape "$(tunnel_label_for_peer "$peer")")"
    esc_log="$(tunnel_xml_escape "$log_path")"
    esc_ssh="$(tunnel_xml_escape "$SSH_CMD")"
    esc_ip="$(tunnel_xml_escape "$ip")"

    local args="        <string>$esc_ssh</string>
        <string>-N</string>"
    for opt in $TUNNEL_SSH_OPTS; do
        args="$args
        <string>$(tunnel_xml_escape "$opt")</string>"
    done
    for pair in "$@"; do
        lport="${pair%%:*}"
        rport="${pair##*:}"
        args="$args
        <string>-L</string>
        <string>127.0.0.1:$(tunnel_xml_escape "$lport"):${esc_ip}:$(tunnel_xml_escape "$rport")</string>"
    done
    args="$args
        <string>proxy-$(tunnel_xml_escape "$ssh_alias")</string>"

    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$esc_label</string>
    <key>ProgramArguments</key>
    <array>
$args
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardErrorPath</key>
    <string>$esc_log</string>
</dict>
</plist>
EOF
}

tunnel_plist_lint() {
    "$PLUTIL_CMD" -lint "$1" >/dev/null 2>&1
}

tunnel_job_is_loaded() {
    "$LAUNCHCTL_CMD" print "gui/$UID/$1" >/dev/null 2>&1
}

tunnel_job_bootstrap() {
    "$LAUNCHCTL_CMD" bootstrap "gui/$UID" "$1" >/dev/null 2>&1
}

tunnel_job_bootout() {
    "$LAUNCHCTL_CMD" bootout "gui/$UID/$1" >/dev/null 2>&1 || true
    local i=0
    while [ "$i" -lt 10 ]; do
        tunnel_job_is_loaded "$1" || return 0
        sleep 0.5
        i=$((i + 1))
    done
    echo "ERROR: launchd job $1 did not unload" >&2
    return 1
}

tunnel_wait_for_port() {
    local i=0
    while [ "$i" -lt 30 ]; do
        "$NC_CMD" -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

tunnel_port_in_use() {
    "$NC_CMD" -z 127.0.0.1 "$1" >/dev/null 2>&1
}

# First free port in [start,end] not already used by a registered tunnel
tunnel_pick_port() {
    local port used
    used="$(tunnel_registry_all 2>/dev/null | "$PYTHON3_CMD" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(" ".join(str(f["localPort"]) for t in data["tunnels"] for f in t.get("forwards", [])))
' 2>/dev/null || true)"
    for port in $(seq "$TUNNEL_PORT_START" "$TUNNEL_PORT_END"); do
        case " $used " in
            *" $port "*) continue ;;
        esac
        if ! tunnel_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    echo "ERROR: no free port in $TUNNEL_PORT_START-$TUNNEL_PORT_END (use --port)" >&2
    return 1
}

# -----------------------------------------------------------------------------
# Adoption — take over the hand-rolled prototype (T-404.4)
# -----------------------------------------------------------------------------
# Parse an existing plist; accept ONLY ssh -N with -L forwards to CGNAT IPs
# and known-safe options. Prints "local:remote local:remote ..." or fails.
tunnel_parse_existing_plist() {
    local plist="$1" json
    [ -f "$plist" ] || return 1
    json="$("$PLUTIL_CMD" -convert json -o - "$plist" 2>/dev/null)" || return 1
    TUNNEL_PLIST_JSON="$json" "$PYTHON3_CMD" <<'PY'
import json, os, re, sys

data = json.loads(os.environ["TUNNEL_PLIST_JSON"])
args = data.get("ProgramArguments") or []
if not args or args[0] != "/usr/bin/ssh" or "-N" not in args:
    sys.stderr.write("reject: not an ssh -N job\n"); sys.exit(1)

SAFE_OPTS = {"ExitOnForwardFailure", "ServerAliveInterval", "ServerAliveCountMax",
             "ControlMaster", "ControlPath", "ControlPersist"}
FORBIDDEN = {"-R", "-D", "-w", "-W", "-b", "-J", "-i", "-F", "-o"}
FORBIDDEN.discard("-o")
CGNAT = re.compile(r"^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.([0-9]{1,3})\.([0-9]{1,3})$")
PORT = re.compile(r"^[0-9]+$")

for a in args:
    if a in FORBIDDEN:
        sys.stderr.write("reject: forbidden ssh flag %s\n" % a); sys.exit(1)

forward_args = []
peer_alias = None
i = 1
while i < len(args):
    a = args[i]
    if a == "-o":
        i += 1
        opt = args[i]
        key = opt.split("=", 1)[0]
        if key not in SAFE_OPTS:
            sys.stderr.write("reject: unsafe ssh option %s\n" % opt); sys.exit(1)
    elif a == "-L":
        i += 1
        forward_args.append(args[i])
    elif not a.startswith("-"):
        peer_alias = a
    i += 1

if not forward_args:
    sys.stderr.write("reject: no forwards\n"); sys.exit(1)

forwards = []
for spec in forward_args:
    parts = spec.split(":")
    if len(parts) == 4:
        bind, lport, host, rport = parts
    elif len(parts) == 3:
        bind, lport, host, rport = "", parts[0], parts[1], parts[2]
    else:
        sys.stderr.write("reject: unparseable -L %s\n" % spec); sys.exit(1)
    if bind not in ("", "127.0.0.1", "localhost", "::1"):
        sys.stderr.write("reject: non-loopback bind in %s\n" % spec); sys.exit(1)
    if not CGNAT.match(host) or not PORT.match(rport) or not PORT.match(lport):
        sys.stderr.write("reject: bad target in %s\n" % spec); sys.exit(1)
    forwards.append((lport, rport))

if peer_alias and peer_alias.startswith("proxy-"):
    peer_alias = peer_alias[len("proxy-"):]
print("\t".join([" ".join("%s:%s" % (l, r) for l, r in forwards), peer_alias or ""]))
PY
}

# -----------------------------------------------------------------------------
# Adaptive SSH wrapper (T-410)
# -----------------------------------------------------------------------------
# Legacy wrapper fingerprint — used for migration detection (T-433)
TUNNEL_LEGACY_WRAPPER_FINGERPRINT='nc -z 127.0.0.1 1055'

tunnel_ssh_wrapper_content() {
    cat <<'EOF'
#!/bin/sh
# tailroute adaptive proxy wrapper — generated by `tailroute proxy-config ssh`
# Probes the SOCKS5 proxy with a handshake to the actual target before use.
# Falls back to direct connection if the proxy is down or cannot reach the target.
PROXY="127.0.0.1:1055"
HOST="$1"
PORT="$2"
# SOCKS5 no-auth greeting (\x05\x01\x00) + CONNECT request to the actual target.
# Read 2 bytes of reply: version + status. Status 0x00 = success.
RESP=$(printf '\x05\x01\x00\x05\x01\x00\x03'"$(printf '%s' "$HOST" | wc -c | tr -d ' ')""$HOST"'\x00'"$(printf '%02x' "$((PORT / 256))")""$(printf '%02x' "$((PORT % 256))")" | \
    /usr/bin/nc -w 3 -q 1 127.0.0.1 1055 2>/dev/null | dd bs=2 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
case "$RESP" in
    0500) exec /usr/bin/nc -X 5 -x "$PROXY" "$@" ;;
esac
exec /usr/bin/nc "$@"
EOF
}

# tunnel_ssh_wrapper_is_legacy — returns 0 if the wrapper uses the old
# port-open probe (nc -z) instead of the SOCKS5 handshake.
tunnel_ssh_wrapper_is_legacy() {
    [ -f "$TUNNEL_SSH_WRAPPER" ] || return 1
    grep -qF "$TUNNEL_LEGACY_WRAPPER_FINGERPRINT" "$TUNNEL_SSH_WRAPPER" 2>/dev/null
}

# Install the wrapper; an existing file with different content is never
# clobbered silently — caller passes replace=yes after prompting.
# Auto-migrates legacy (nc -z) wrappers (T-433).
tunnel_install_ssh_wrapper() {
    local replace="${1:-no}"
    local dir
    dir="$(dirname "$TUNNEL_SSH_WRAPPER")"
    mkdir -p "$dir"
    chmod 0700 "$dir" 2>/dev/null || true
    if [ -f "$TUNNEL_SSH_WRAPPER" ]; then
        if tunnel_ssh_wrapper_content | diff -q - "$TUNNEL_SSH_WRAPPER" >/dev/null 2>&1; then
            return 0
        fi
        # Legacy wrapper detected — migrate automatically (T-433)
        if tunnel_ssh_wrapper_is_legacy; then
            echo "NOTE: migrating legacy proxy wrapper to SOCKS5 handshake probe" >&2
            replace="yes"
        elif [ "$replace" != "yes" ]; then
            echo "NOTE: $TUNNEL_SSH_WRAPPER exists with different content:" >&2
            tunnel_ssh_wrapper_content | diff - "$TUNNEL_SSH_WRAPPER" >&2 || true
            echo "Re-run with --replace-wrapper to overwrite." >&2
            return 1
        fi
    fi
    tunnel_ssh_wrapper_content > "$TUNNEL_SSH_WRAPPER"
    chmod 0755 "$TUNNEL_SSH_WRAPPER"
    echo "Installed adaptive proxy wrapper: $TUNNEL_SSH_WRAPPER"
}

# -----------------------------------------------------------------------------
# Pre-flight (T-402)
# -----------------------------------------------------------------------------
# Consumes TSV from tunnel_lookup_peer. Exit: 0 ok · 1 hard fail · 2 needs ssh config
tunnel_preflight() {
    local peer="$1" lookup="$2" ssh_alias="${3:-$1}"
    local hostname dns ip suffix online
    IFS="$(printf '\t')" read -r hostname dns ip suffix online <<EOF
$lookup
EOF

    tunnel_validate_peer_label "$peer" || { echo "ERROR: invalid peer label '$peer'" >&2; return 1; }
    tunnel_validate_cgnat_ip "$ip" || { echo "ERROR: peer IP $ip outside 100.64.0.0/10" >&2; return 1; }
    local full_hostname="$hostname.$suffix"
    [ -n "$dns" ] && full_hostname="$dns"
    tunnel_validate_hostname "$full_hostname" "$suffix" || {
        echo "ERROR: hostname '$full_hostname' does not match tailnet suffix '$suffix'" >&2
        return 1
    }

    tunnel_validate_peer_label "$ssh_alias" || { echo "ERROR: invalid ssh alias '$ssh_alias'" >&2; return 1; }
    if [ ! -f "$TUNNEL_SSH_CONFIG" ] || ! grep -Eq "^Host[[:space:]]+proxy-${ssh_alias}\$" "$TUNNEL_SSH_CONFIG"; then
        echo "PREFLIGHT_NEED_SSH_CONFIG=$ssh_alias"
        return 2
    fi
    if ! grep -q "tailroute-proxy.sh" "$TUNNEL_SSH_CONFIG" 2>/dev/null; then
        echo "WARN: ssh config does not use the adaptive wrapper — run 'tailroute proxy-config ssh'" >&2
    fi

    if ! "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$ssh_alias" true >/dev/null 2>&1; then
        echo "ERROR: ssh proxy-$ssh_alias failed (auth/host-key). Run: ssh proxy-$ssh_alias true" >&2
        return 1
    fi

    if ! tunnel_port_in_use 1055; then
        echo "WARN: SOCKS5 proxy not running — tunnel will use the direct branch (fine when VPN is off or router-side)" >&2
    fi
    return 0
}

# Remote backend soft check — transport can be up while Serve is down (502)
tunnel_check_remote_backend() {
    local alias="${3:-$1}"
    "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$alias" \
        "/usr/bin/nc -z 127.0.0.1 $2" >/dev/null 2>&1
}

# TLS identity verification (T-430): after the SSH tunnel is up and /etc/hosts
# points 127.0.0.1:<port> to the peer's hostname, verify that the certificate
# presented through the tunnel matches that hostname.
#
# Returns 0 if the certificate hostname matches.
# Returns 1 on mismatch, expired, untrusted, or connection failure.
#
# Uses openssl s_client (macOS built-in) with a short timeout.
# The --allow-unverified-tls flag skips this check.
_tun_tls_verify() { # <hostname> <port>
    local hostname="$1" port="$2"
    local cert_out
    cert_out="$("$OPENSSL_CMD" s_client -connect "127.0.0.1:$port" \
        -servername "$hostname" \
        -showcerts \
        -verify_return_error \
        2>/dev/null </dev/null)" || {
        echo "WARN: TLS handshake failed on 127.0.0.1:$port for $hostname" >&2
        return 1
    }

    # Extract the CN and SAN from the certificate
    local subject san
    # Extract SAN from the certificate (modern certs use this)
    san="$(printf '%s' "$cert_out" | grep -A1 '^ ' | grep 'DNS:' | sed 's/.*DNS:\([^,]*\).*/\1/' | head -1)"
    # Extract CN from subject line as fallback
    cn="$(printf '%s' "$cert_out" | grep '^subject=' | sed 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/' | head -1)"

    # Check SAN first (modern certs), fall back to CN
    local cert_hostname=""
    if [ -n "$san" ]; then
        cert_hostname="$san"
    elif [ -n "$cn" ]; then
        cert_hostname="$cn"
    fi

    if [ -z "$cert_hostname" ]; then
        echo "WARN: no hostname found in TLS certificate on 127.0.0.1:$port" >&2
        return 1
    fi

    # Exact match or wildcard match
    if [ "$cert_hostname" = "$hostname" ]; then
        return 0
    fi
    # Wildcard: *.tailnet.ts.net matches prime.tailnet.ts.net
    case "$cert_hostname" in
        \*.*)
            local wildcard_suffix="${cert_hostname#\*.}"
            case "$hostname" in
                *"$wildcard_suffix") return 0 ;;
            esac ;;
    esac

    echo "WARN: TLS certificate hostname mismatch: expected '$hostname', got '$cert_hostname'" >&2
    return 1
}

tunnel_tls_verify_or_skip() { # <hostname> <port> <allow_unverified>
    if [ "${3:-no}" = "yes" ]; then
        echo "WARN: --allow-unverified-tls: skipping TLS identity verification" >&2
        return 0
    fi
    _tun_tls_verify "$1" "$2"
}

# -----------------------------------------------------------------------------
# Transactional add / remove (T-405.1 / T-405.2)
# -----------------------------------------------------------------------------
tunnel_build_entry_json() { # peer ip hostname suffix forwards("l:r l:r")
    TUNNEL_E_PEER="$1" TUNNEL_E_IP="$2" TUNNEL_E_HOST="$3" \
    TUNNEL_E_SUFFIX="$4" TUNNEL_E_PLIST="$(tunnel_plist_path_for_peer "$1")" \
    TUNNEL_E_ALIAS="${6:-$1}" \
    TUNNEL_E_FORWARDS="$5" "$PYTHON3_CMD" <<'PY'
import datetime, json, os

fwd = []
for pair in os.environ["TUNNEL_E_FORWARDS"].split():
    l, r = pair.split(":", 1)
    fwd.append({"localPort": int(l), "remotePort": int(r)})
print(json.dumps({
    "peer": os.environ["TUNNEL_E_PEER"],
    "tailscaleIP": os.environ["TUNNEL_E_IP"],
    "hostname": os.environ["TUNNEL_E_HOST"],
    "magicDNSSuffix": os.environ["TUNNEL_E_SUFFIX"],
    "sshAlias": os.environ["TUNNEL_E_ALIAS"],
    "forwards": fwd,
    "plistPath": os.environ["TUNNEL_E_PLIST"],
    "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
PY
}

# Bridge to the ssh-config generator defined in tailroute.sh
tailroute_proxy_config_ssh_generate() {
    if declare -f do_proxy_config_ssh >/dev/null 2>&1; then
        do_proxy_config_ssh "127.0.0.1:1055" --peer "$1" --append "$TUNNEL_SSH_CONFIG"
    else
        echo "ERROR: proxy-config unavailable in this context" >&2
        return 1
    fi
}

tunnel_do_add() {
    local peer="" port="" adopt="no" assume_yes="no" raw_remote="" ssh_alias="" r
    local allow_unverified_tls="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --ssh-alias)
                [ -n "${2:-}" ] || { echo "ERROR: --ssh-alias requires a value" >&2; return 2; }
                ssh_alias="$2"; shift 2 ;;
            --port)
                [ -n "${2:-}" ] || { echo "ERROR: --port requires a value" >&2; return 2; }
                port="$2"; shift 2 ;;
            --remote-port)
                [ -n "${2:-}" ] || { echo "ERROR: --remote-port requires a value" >&2; return 2; }
                raw_remote="$raw_remote $2"; shift 2 ;;
            --adopt) adopt="yes"; shift ;;
            --allow-unverified-tls) allow_unverified_tls="yes"; shift ;;
            --yes|-y) assume_yes="yes"; shift ;;
            -*) echo "ERROR: unknown tunnel add flag '$1'" >&2; return 2 ;;
            *)
                [ -z "$peer" ] || { echo "ERROR: unexpected argument '$1'" >&2; return 2; }
                peer="$1"; shift ;;
        esac
    done
    [ -n "$peer" ] || { echo "ERROR: tunnel add requires <peer>" >&2; return 2; }
    peer="$(tunnel_normalize_lower "$peer")"
    tunnel_validate_peer_label "$peer" || { echo "ERROR: invalid peer label '$peer'" >&2; return 2; }
    if [ -n "$ssh_alias" ]; then
        ssh_alias="$(tunnel_normalize_lower "$ssh_alias")"
        tunnel_validate_peer_label "$ssh_alias" || { echo "ERROR: invalid ssh alias '$ssh_alias'" >&2; return 2; }
    fi
    if [ -n "$port" ]; then
        tunnel_validate_port "$port" || { echo "ERROR: invalid port '$port'" >&2; return 2; }
    fi
    for r in $raw_remote; do
        tunnel_validate_port "$r" || { echo "ERROR: invalid remote port '$r'" >&2; return 2; }
    done

    tunnel_registry_check_env || return 1
    tunnel_lock_acquire || return 1

    local lookup rc=0
    lookup="$(tunnel_lookup_peer "$peer")" || { tunnel_lock_release; return 1; }
    tunnel_preflight "$peer" "$lookup" "$ssh_alias" || rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "" >&2
        echo "No 'proxy-$peer' entry in $TUNNEL_SSH_CONFIG." >&2
        local answer="n"
        if [ "$assume_yes" != "yes" ]; then
            printf "Generate now with 'tailroute proxy-config ssh --peer %s --append %s'? [y/N] " "$peer" "$TUNNEL_SSH_CONFIG" >&2
            read -r answer
        fi
        case "$answer" in
            y|Y)
                tailroute_proxy_config_ssh_generate "${ssh_alias:-$peer}" || { tunnel_lock_release; return 1; }
                tunnel_preflight "$peer" "$lookup" "$ssh_alias" || { tunnel_lock_release; return 1; } ;;
            *)
                echo "Aborted. Run: tailroute proxy-config ssh --peer $peer --append $TUNNEL_SSH_CONFIG" >&2
                tunnel_lock_release; return 1 ;;
        esac
    elif [ "$rc" -ne 0 ]; then
        tunnel_lock_release; return 1
    fi

    local hostname ip suffix dnsname full_hostname
    hostname="$(printf '%s\n' "$lookup" | cut -f1)"
    dnsname="$(printf '%s\n' "$lookup" | cut -f2)"
    ip="$(printf '%s\n' "$lookup" | cut -f3)"
    suffix="$(printf '%s\n' "$lookup" | cut -f4)"
    if [ -n "$dnsname" ]; then full_hostname="$dnsname"; else full_hostname="$hostname.$suffix"; fi

    if tunnel_registry_get "$peer" >/dev/null 2>&1; then
        echo "ERROR: tunnel for '$peer' already registered — remove it first: tailroute tunnel remove $peer" >&2
        tunnel_lock_release; return 1
    fi

    # --- Prototype adoption (T-404.4) ---
    local label plist existing_forwards="" forced_forwards=""
    label="$(tunnel_label_for_peer "$peer")"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    if tunnel_job_is_loaded "$label" || [ -f "$plist" ]; then
        local parsed_plist=""
    parsed_plist="$(tunnel_parse_existing_plist "$plist" 2>/dev/null)" || parsed_plist=""
    if [ -n "$parsed_plist" ]; then
        existing_forwards="${parsed_plist%%	*}"
        local adopted_alias
        adopted_alias="$(printf '%s' "$parsed_plist" | cut -f2)"
        if [ -n "$adopted_alias" ] && [ -z "$ssh_alias" ]; then
            ssh_alias="$adopted_alias"
        fi
    else
        existing_forwards=""
    fi
        if [ -n "$existing_forwards" ]; then
            if [ "$adopt" != "yes" ]; then
                echo "Found an existing (prototype) launchd job: $label" >&2
                local adopt_answer="n"
                if [ "$assume_yes" != "yes" ]; then
                    printf "Adopt it into managed tailroute tunnels? [y/N] " >&2
                    read -r adopt_answer
                fi
                if [ "$adopt_answer" != "y" ] && [ "$adopt_answer" != "Y" ]; then
                    echo "Aborted. Re-run with --adopt to take over." >&2
                    tunnel_lock_release; return 1
                fi
                adopt="yes"
            fi
            forced_forwards="$existing_forwards"
        else
            echo "ERROR: existing $plist is not a recognized tunnel job — inspect and remove it manually" >&2
            tunnel_lock_release; return 1
        fi
        if [ "$adopt" = "yes" ]; then
            tunnel_job_bootout "$label" || { tunnel_lock_release; return 1; }
        fi
    fi

    if tunnel_hosts_has_mapping "$full_hostname"; then
        tunnel_hosts_adopt_mapping "$full_hostname" || {
            echo "ERROR: failed to migrate unmanaged hosts line" >&2
            tunnel_lock_release; return 1
        }
    fi

    # --- Port allocation / forward pairs ---
    local forwards="" pair lport rport idx
    if [ -n "$forced_forwards" ]; then
        for pair in $forced_forwards; do
            lport="${pair%%:*}"; rport="${pair##*:}"
            # shellcheck disable=SC2015  # error branch handles either failure
            tunnel_validate_port "$lport" && tunnel_validate_port "$rport" || {
                echo "ERROR: invalid adopted forward '$pair'" >&2; tunnel_lock_release; return 1; }
            if tunnel_port_in_use "$lport"; then
                echo "ERROR: local port $lport (from adopted job) is in use" >&2
                tunnel_lock_release; return 1
            fi
            forwards="$forwards $pair"
        done
        forwards="${forwards# }"
    else
        if [ -z "$port" ]; then
            port="$(tunnel_pick_port)" || { tunnel_lock_release; return 1; }
        elif tunnel_port_in_use "$port"; then
            echo "ERROR: port $port is in use" >&2; tunnel_lock_release; return 1
        fi
        if [ -z "$(printf '%s' "$raw_remote" | tr -d ' ')" ]; then
            raw_remote=" 443"
        fi
        lport="$port"; idx=0
        for rport in $raw_remote; do
            if [ "$idx" -gt 0 ]; then lport=$((port + idx)); fi
            if tunnel_port_in_use "$lport"; then
                echo "ERROR: local port $lport for remote $rport is in use" >&2
                tunnel_lock_release; return 1
            fi
            if [ -z "$forwards" ]; then forwards="$lport:$rport"; else forwards="$forwards $lport:$rport"; fi
            idx=$((idx + 1))
        done
    fi
    pair="${forwards%% *}"
    lport="${pair%%:*}"
    rport="${pair##*:}"

    # sudo up front so a mid-transaction expiry can't strand a rollback
    if [ -n "$TUNNEL_SUDO_CMD" ]; then
        "$TUNNEL_SUDO_CMD" -v || { echo "ERROR: sudo unavailable for /etc/hosts edit" >&2; tunnel_lock_release; return 1; }
    fi

    tunnel_check_remote_backend "$peer" "$rport" "${ssh_alias:-$peer}" || \
        echo "WARN: remote port $rport not accepting on $peer — Serve may not be configured there" >&2
    echo "NOTE: the /etc/hosts mapping is system-wide — it affects every user of this Mac." >&2

    # --- Transaction: registry → hosts → plist (+lint) → bootstrap → verify ---
    local entry rolled_back=""
    entry="$(tunnel_build_entry_json "$peer" "$ip" "$full_hostname" "$suffix" "$forwards" "${ssh_alias:-$peer}")" || {
        tunnel_lock_release; return 1; }

    if ! tunnel_registry_add "$peer" "$entry"; then
        tunnel_lock_release; return 1
    fi
    if ! tunnel_hosts_apply add "$full_hostname"; then
        echo "ROLLED BACK: registry entry" >&2
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        tunnel_lock_release; return 1
    fi

    mkdir -p "$TUNNEL_LOG_DIR"; chmod 0700 "$TUNNEL_LOG_DIR" 2>/dev/null || true
    local log_path="$TUNNEL_LOG_DIR/tunnel-$peer.log"
    # shellcheck disable=SC2086  # $forwards intentionally word-splits into l:r pair args
    if ! tunnel_generate_plist "$peer" "$ip" "$log_path" "${ssh_alias:-$peer}" $forwards > "$plist" || ! tunnel_plist_lint "$plist"; then
        echo "ROLLED BACK: hosts entry, registry entry" >&2
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || rolled_back="hosts"
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        [ -n "$rolled_back" ] && echo "  MANUAL REVERT NEEDED: remove '$full_hostname' from $TUNNEL_HOSTS_FILE (sudo)" >&2
        tunnel_lock_release; return 1
    fi
    chmod 0644 "$plist"
    if ! tunnel_job_bootstrap "$plist"; then
        echo "ROLLED BACK: plist, hosts entry, registry entry" >&2
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || rolled_back="hosts"
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        [ -n "$rolled_back" ] && echo "  MANUAL REVERT NEEDED: remove '$full_hostname' from $TUNNEL_HOSTS_FILE (sudo)" >&2
        tunnel_lock_release; return 1
    fi
    if ! tunnel_wait_for_port "$lport"; then
        echo "WARN: job loaded but 127.0.0.1:$lport is not listening yet — check: tail -f $log_path" >&2
    fi

    # --- TLS identity verification (T-430) ---
    if ! tunnel_tls_verify_or_skip "$full_hostname" "$lport" "$allow_unverified_tls"; then
        echo "ROLLED BACK: TLS identity verification failed — certificate does not match '$full_hostname'" >&2
        tunnel_job_bootout "$(tunnel_label_for_peer "$peer")" || true
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || true
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        tunnel_lock_release; return 1
    fi

    tunnel_lock_release
    echo ""
    echo "Tunnel added: $peer"
    echo "  URL:      https://$full_hostname:$lport"
    [ "$rport" != "443" ] && echo "  (forwards to remote port $rport)"
    echo "  Registry: $TUNNEL_REGISTRY"
    echo "  Log:      $log_path"
    return 0
}

tunnel_do_remove() {
    local peer="${1:-}"
    [ -n "$peer" ] || { echo "ERROR: tunnel remove requires <peer>" >&2; return 2; }
    peer="$(tunnel_normalize_lower "$peer")"
    tunnel_lock_acquire || return 1

    local entry
    entry="$(tunnel_registry_get "$peer" 2>/dev/null)" || {
        echo "ERROR: tunnel for '$peer' not found" >&2
        tunnel_lock_release; return 3
    }
    local hostname label plist failed=""
    hostname="$(tunnel_registry_field "$entry" hostname)"
    label="$(tunnel_label_for_peer "$peer")"
    plist="$(tunnel_plist_path_for_peer "$peer")"

    if [ -n "$TUNNEL_SUDO_CMD" ]; then
        "$TUNNEL_SUDO_CMD" -v >/dev/null 2>&1 || true
    fi

    if tunnel_job_is_loaded "$label"; then
        tunnel_job_bootout "$label" || true
    fi
    [ -f "$plist" ] && rm -f "$plist"
    if ! tunnel_hosts_apply remove "$hostname"; then
        echo "ERROR: could not remove hosts entry — manual revert: remove '$hostname' inside $TUNNEL_HOSTS_FILE markers (sudo)" >&2
        failed="hosts"
    fi
    tunnel_registry_remove "$peer" >/dev/null 2>&1 || true
    tunnel_lock_release
    if [ -n "$failed" ]; then
        return 1
    fi
    echo "Tunnel removed: $peer (hosts entry and launchd job cleaned up)"
    return 0
}

tunnel_do_restart() {
    local peer="${1:-}" entry p label plist rc=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        if [ -n "$peer" ] && [ "$p" != "$peer" ]; then continue; fi
        label="$(tunnel_label_for_peer "$p")"
        plist="$(tunnel_plist_path_for_peer "$p")"
        if [ ! -f "$plist" ]; then
            echo "ERROR: $p: plist missing at $plist" >&2; rc=1; continue
        fi
        if tunnel_job_is_loaded "$label"; then
            tunnel_job_bootout "$label" || true
        fi
        if tunnel_job_bootstrap "$plist"; then
            echo "Restarted: $p"
        else
            echo "ERROR: failed to restart $p" >&2; rc=1
        fi
    done <<EOF
$(tunnel_registry_entries)
EOF
    if [ "$rc" -eq 0 ] && [ -n "$peer" ]; then
        tunnel_registry_get "$peer" >/dev/null 2>&1 || { echo "ERROR: tunnel for '$peer' not found" >&2; return 3; }
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# Status / list (T-405.3 / T-405.4)
# -----------------------------------------------------------------------------
# TSV per tunnel: peer, hostname, localPort, job, port, hosts, remotePort, notes
tunnel_status_rows() {
    local skip_remote="${1:-no}"
    local entry p hostname ip suffix first_fwd lport rport label
    local job port_state hosts_state notes lookup_row online cur_ip cur_suffix
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        hostname="$(tunnel_registry_field "$entry" hostname)"
        ip="$(tunnel_registry_field "$entry" tailscaleIP)"
        suffix="$(tunnel_registry_field "$entry" magicDNSSuffix)"
        ssh_alias="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("sshAlias", ""))')"
        first_fwd="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; f=json.load(sys.stdin)["forwards"][0]; print(str(f["localPort"]) + ":" + str(f["remotePort"]))')"
        lport="${first_fwd%%:*}"
        rport="${first_fwd##*:}"
        label="$(tunnel_label_for_peer "$p")"

        notes=""
        if tunnel_job_is_loaded "$label"; then job="running"; else job="not-running"; fi
        if tunnel_port_in_use "$lport"; then port_state="listening"; else port_state="closed"; fi
        if tunnel_hosts_has_mapping "$hostname"; then hosts_state="present"; else hosts_state="missing"; fi

        if [ "$job" = "running" ] && [ "$port_state" = "closed" ]; then
            notes="may be starting or backend down"
        fi
        if [ "$job" = "not-running" ] && [ "$hosts_state" = "present" ]; then
            notes="${notes:+$notes; }stale hosts entry (browser gets connection refused)"
        fi
        if [ -f "$TUNNEL_LOG_DIR/tunnel-$p.log" ] && tail -20 "$TUNNEL_LOG_DIR/tunnel-$p.log" 2>/dev/null | grep -Eq "Permission denied|Host key verification failed"; then
            notes="${notes:+$notes; }ssh auth failing — key rotated? re-run: tailroute tunnel add $p"
        fi

        lookup_row="$(tunnel_lookup_peer "$p" 2>/dev/null || true)"
        if [ -n "$lookup_row" ]; then
            online="$(printf '%s\n' "$lookup_row" | cut -f5)"
            cur_ip="$(printf '%s\n' "$lookup_row" | cut -f3)"
            cur_suffix="$(printf '%s\n' "$lookup_row" | cut -f4)"
            if [ "$online" = "yes" ] && [ "$cur_ip" != "$ip" ]; then
                notes="${notes:+$notes; }IP drift: registry $ip, current $cur_ip — remove and re-add"
            fi
            if [ "$cur_suffix" != "$suffix" ]; then
                notes="${notes:+$notes; }tailnet suffix drift ($suffix -> $cur_suffix) — remove and re-add"
            fi
        fi

        if [ "$skip_remote" != "yes" ]; then
            if tunnel_check_remote_backend "$p" "$rport" "${ssh_alias:-$p}"; then
                notes="${notes:+$notes; }backend: accepting"
            else
                notes="${notes:+$notes; }backend: not accepting (or unreachable)"
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$hostname" "$lport" "$job" "$port_state" "$hosts_state" "$rport" "$notes"
    done <<EOF
$(tunnel_registry_entries)
EOF
}

tunnel_do_status() {
    local json_mode="no" peer="" skip_remote="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_mode="yes"; shift ;;
            --skip-remote-check) skip_remote="yes"; shift ;;
            -*) echo "ERROR: unknown status flag '$1'" >&2; return 2 ;;
            *) peer="$(tunnel_normalize_lower "$1")"; shift ;;
        esac
    done

    local rows
    rows="$(tunnel_status_rows "$skip_remote")" || {
        echo '{"error":"registry corrupt or unreadable"}'
        return 2
    }
    if [ -n "$peer" ]; then
        rows="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$peer" '$1 == p')"
        if [ -z "$rows" ]; then
            echo "ERROR: tunnel for '$peer' not found" >&2
            return 3
        fi
    fi
    if ! printf '%s\n' "$rows" | grep -q '^.'; then
        if [ "$json_mode" = "yes" ]; then
            echo '{"version":1,"tunnels":[]}'
        else
            echo "No tunnels configured."
            echo "Add one: tailroute tunnel add <peer>"
        fi
        return 0
    fi

    if [ "$json_mode" = "yes" ]; then
        printf '%s\n' "$rows" | "$PYTHON3_CMD" -c '
import json, sys
out = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 8: continue
    p, hostname, lport, job, port_state, hosts_state, rport, notes = parts[:8]
    healthy = job == "running" and port_state == "listening" and hosts_state == "present"
    out.append({"peer": p, "hostname": hostname, "localPort": int(lport), "remotePort": int(rport),
                "job": job, "port": port_state, "hosts": hosts_state,
                "healthy": healthy, "notes": notes})
print(json.dumps({"version": 1, "tunnels": out}))
'
    else
        local worst=0 p hostname lport job port_state hosts_state rport notes
        while IFS="$(printf '\t')" read -r p hostname lport job port_state hosts_state rport notes; do
            [ -n "$p" ] || continue
            echo "$p:"
            echo "  URL:      https://$hostname:$lport"
            echo "  Job:      $job"
            echo "  Port:     $port_state (remote $rport)"
            echo "  Hosts:    $hosts_state"
            [ -n "$notes" ] && echo "  Notes:    $notes" || true
            echo ""
            if [ "$job" != "running" ] || [ "$port_state" != "listening" ] || [ "$hosts_state" != "present" ]; then
                worst=1
            fi
        done <<EOF
$rows
EOF
        return "$worst"
    fi
    # json mode: exit code only (0 healthy / 1 degraded)
    printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r p hostname lport job port_state hosts_state rport notes; do
        if [ "$job" != "running" ] || [ "$port_state" != "listening" ] || [ "$hosts_state" != "present" ]; then
            exit 1
        fi
    done || return 1
    return 0
}

tunnel_do_list() {
    tunnel_registry_entries
}

# Remove every tunnel (used by `tailroute uninstall`); runs per-user
tunnel_remove_all() {
    local entry p failed=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        tunnel_do_remove "$p" || failed=1
    done <<EOF
$(tunnel_registry_entries 2>/dev/null || true)
EOF
    rm -f "$TUNNEL_REGISTRY" "$TUNNEL_REGISTRY.bak" 2>/dev/null || true
    return "$failed"
}
