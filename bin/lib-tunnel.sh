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

TUNNEL_REGISTRY_VERSION=2
TUNNEL_PORT_START="${TUNNEL_PORT_START:-8443}"
OPENSSL_CMD="${OPENSSL_CMD:-/usr/bin/openssl}"
TUNNEL_TLS_VERIFY_TIMEOUT="${TUNNEL_TLS_VERIFY_TIMEOUT:-5}"
OPEN_CMD="${OPEN_CMD:-open}"
TUNNEL_PORT_END="${TUNNEL_PORT_END:-8499}"
# How long to poll for a freshly bound listener before warning (tries x 0.5s).
# Tests set 1 so exhausted waits stay instant.
TUNNEL_WAIT_TRIES="${TUNNEL_WAIT_TRIES:-30}"
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
TUNNEL_SSH_OPTS="-o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=no -o ControlPath=none -o ControlPersist=no -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes"

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
# Write-ahead journal (T-431) — durable crash recovery
# -----------------------------------------------------------------------------
# The journal records the intended operation and each completed step.
# On crash, status/add/remove detect an incomplete journal and can
# resume or roll back.  The journal file lives next to the registry
# and uses the same atomic-write pattern (same-dir tmp + fsync + rename).
#
# Journal format (JSON lines, one per step):
#   {"op":"add|remove","peer":"...","steps":["registry","hosts","plist","bootstrap"],
#    "completed":["registry"],"pid":12345,"ts":"..."}
#
# Overridable for tests: TUNNEL_JOURNAL_PATH

TUNNEL_JOURNAL_PATH="${TUNNEL_JOURNAL_PATH:-$TUNNEL_CONFIG_DIR/tunnels.journal}"

# _tun_journal_write <op> <peer> <steps-json> <completed-json>
# Writes or updates the journal entry atomically.
_tun_journal_write() {
    local op="$1" peer="$2" steps="$3" completed="$4"
    local journal_dir journal_tmp
    journal_dir="$(dirname "$TUNNEL_JOURNAL_PATH")"
    mkdir -p "$journal_dir" 2>/dev/null || true
    chmod 0700 "$journal_dir" 2>/dev/null || true
    journal_tmp="$("$MKTEMP_CMD" "${TUNNEL_JOURNAL_PATH}.XXXXXX")" || return 1
    printf '{"op":"%s","peer":"%s","steps":%s,"completed":%s,"pid":%s,"ts":"%s"}\n' \
        "$op" "$peer" "$steps" "$completed" "$$" \
        "$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')" > "$journal_tmp"
    chmod 0600 "$journal_tmp"
    # Atomic rename (no fsync needed for journal — it's recovered, not trusted)
    mv -f "$journal_tmp" "$TUNNEL_JOURNAL_PATH"
}

# _tun_journal_read — prints the journal JSON on stdout, empty string if absent
_tun_journal_read() {
    if [ -f "$TUNNEL_JOURNAL_PATH" ]; then
        cat "$TUNNEL_JOURNAL_PATH"
    fi
}

# _tun_journal_clear — removes the journal file
_tun_journal_clear() {
    rm -f "$TUNNEL_JOURNAL_PATH" 2>/dev/null || true
}

# _tun_journal_has_incomplete — returns 0 if there's an incomplete journal entry
_tun_journal_has_incomplete() {
    local journal
    journal="$(_tun_journal_read)"
    [ -z "$journal" ] && return 1
    # Check if completed != steps using python3 (bash 3.2 has no deep compare)
    printf '%s' "$journal" | "$PYTHON3_CMD" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("completed", []) != d.get("steps", []):
        sys.exit(0)  # incomplete
    sys.exit(1)  # complete or empty
except Exception:
    sys.exit(1)
'
}

# _tun_journal_peer — prints the peer name from the journal, empty if absent
_tun_journal_peer() {
    local journal
    journal="$(_tun_journal_read)"
    [ -z "$journal" ] && return 0
    printf '%s' "$journal" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("peer",""))' 2>/dev/null || true
}

# _tun_journal_op — prints the operation type (add/remove), empty if absent
_tun_journal_op() {
    local journal
    journal="$(_tun_journal_read)"
    [ -z "$journal" ] && return 0
    printf '%s' "$journal" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("op",""))' 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Machine-wide hosts lock (T-431) — serializes /etc/hosts across users
# -----------------------------------------------------------------------------
# This is a root-owned mkdir-based lock at a system path.  It serializes
# /etc/hosts edits from different users on the same Mac.  The per-user lock
# (above) serializes registry + port allocation within one user.
#
# Lock ordering: acquire per-user FIRST, then machine-wide.
# Release in REVERSE: machine-wide first, then per-user.
#
# Overridable for tests: TUNNEL_HOSTS_LOCK_DIR

TUNNEL_HOSTS_LOCK_DIR="${TUNNEL_HOSTS_LOCK_DIR:-/var/db/tailroute/hosts.lock}"
# Contention retries before declaring the hosts lock busy (overridable for tests)
TUNNEL_HOSTS_LOCK_TRIES="${TUNNEL_HOSTS_LOCK_TRIES:-10}"

tunnel_hosts_lock_acquire() {
    local lock_dir="$1"
    local waited=0 lock_pid
    local acquired fallback_tried=0
    while true; do
        acquired=0
        if mkdir "$lock_dir" 2>/dev/null; then
            acquired=1
        elif [ "$fallback_tried" -eq 0 ]; then
            # v0.7.4: the lock may live under a root-owned parent (e.g. /var/db/tailroute);
            # use the cached sudo (do_add runs `sudo -v` up front) to create it and hand it
            # to the acquiring user - once per acquire call.
            fallback_tried=1
            if tunnel_privileged_run "mkdir -p '$lock_dir' && chown '$(id -un)' '$lock_dir' && chmod 0755 '$lock_dir'" 2>/dev/null; then
                acquired=1
            fi
        fi
        if [ "$acquired" -eq 1 ]; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            chmod 0755 "$lock_dir" 2>/dev/null || true
            return 0
        fi
        lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            # Stale lock — but only root (or test mode) can remove it
            if [ -n "$TUNNEL_SUDO_CMD" ]; then
                "$TUNNEL_SUDO_CMD" rm -rf "$lock_dir" 2>/dev/null || true
            else
                rm -rf "$lock_dir" 2>/dev/null || true
            fi
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -ge "$TUNNEL_HOSTS_LOCK_TRIES" ]; then
            echo "ERROR: another tailroute operation is modifying $TUNNEL_HOSTS_FILE ($lock_dir)" >&2
            return 1
        fi
        sleep 1
    done
}

tunnel_hosts_lock_release() {
    local lock_dir="$1"
    if [ -n "$TUNNEL_SUDO_CMD" ]; then
        "$TUNNEL_SUDO_CMD" rm -rf "$lock_dir" 2>/dev/null || true
    else
        rm -rf "$lock_dir" 2>/dev/null || true
    fi
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
# modes: all | get <peer> | add <peer> <entry> | update <peer> <entry>
#        | remove <peer> | update-ip <peer> <ip>
# Exit: 0 ok · 2 invalid data · 4 already registered · 5 not found · 6 registry corrupt/version
tunnel_registry_op() {
    TUNNEL_REGISTRY_PATH="$TUNNEL_REGISTRY" \
    TUNNEL_REG_VERSION="$TUNNEL_REGISTRY_VERSION" \
    TUNNEL_REG_SOURCE="${TUNNEL_REG_SOURCE:-cli}" \
    TUNNEL_REG_MODE="$1" \
    TUNNEL_REG_PEER="${2:-}" \
    TUNNEL_REG_ENTRY="${3:-}" \
    "$PYTHON3_CMD" <<'PY'
import datetime, json, os, re, sys, tempfile, uuid

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

# T-438: per-entry audit trail.  Appended only here — the single mutation
# point — and capped at the last 20 records.  Never read for recovery; the
# journal is the recovery mechanism.
TUNNEL_REG_TX_CAP = 20
TUNNEL_REG_SOURCE = os.environ.get("TUNNEL_REG_SOURCE") or "cli"

def append_tx(entry, op, before, after):
    txs = entry.get("transactions")
    if not isinstance(txs, list):
        txs = []
    txs.append({
        "op": op,
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "forwards-before": before,
        "forwards-after": after,
        "source": TUNNEL_REG_SOURCE,
    })
    entry["transactions"] = txs[-TUNNEL_REG_TX_CAP:]

def migrate_v1_to_v2(data):
    for t in data["tunnels"]:
        if "peerID" not in t:
            t["peerID"] = t["peer"] + "." + uuid.uuid4().hex[:8]
        if "jobID" not in t:
            t["jobID"] = t.get("plistPath", "").split("/")[-1].replace(".plist", "") or ("job-" + uuid.uuid4().hex[:8])
        if "allowUnverifiedTLS" not in t:
            t["allowUnverifiedTLS"] = False
        if "transactions" not in t:
            t["transactions"] = []
    data["version"] = expected_version
    return data

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
        if got == 1:
            data = migrate_v1_to_v2(data)
        elif got != expected_version:
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
    append_tx(entry, "add", [], list(entry.get("forwards") or []))
    tunnels.append(entry)
    save(data)
elif mode == "update":
    # T-436/T-438: replace one peer's entry in a single atomic save (the
    # update path used to be remove + add, a two-save window where a crash
    # lost the entry outright) and record what changed.
    try:
        entry = json.loads(entry_raw)
    except Exception:
        die(2, "ERROR: invalid entry JSON")
    validate_entry(entry)
    stored = None
    for t in tunnels:
        if t["peer"] == peer:
            stored = t
            break
    if stored is None:
        die(5, "ERROR: tunnel for '%s' not found" % peer)
    # Identity and history are the registry's, not the caller's JSON — a
    # caller holding a stale entry must not clobber records written since.
    for k in ("peerID", "jobID", "createdAt"):
        if k not in entry and k in stored:
            entry[k] = stored[k]
    entry["transactions"] = stored.get("transactions", [])
    append_tx(entry, "update",
              list(stored.get("forwards") or []),
              list(entry.get("forwards") or []))
    for i, t in enumerate(tunnels):
        if t is stored:
            tunnels[i] = entry
            break
    save(data)
elif mode == "remove":
    victim = None
    for t in tunnels:
        if t["peer"] == peer:
            victim = t
            break
    if victim is None:
        die(5, "ERROR: tunnel for '%s' not found" % peer)
    append_tx(victim, "remove", list(victim.get("forwards") or []), [])
    # Evidence write first: the tombstone record lands in the live registry,
    # so the mutation write below displaces that state into .bak and the
    # removed entry's final transaction stays auditable.
    save(data)
    data["tunnels"] = [t for t in tunnels if t["peer"] != peer]
    save(data)
elif mode == "update-ip":
    # Deliberately not recorded in transactions[]: IP refreshes would flood
    # the 20-record cap and evict the add/update evidence it exists to keep.
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
tunnel_registry_update(){ tunnel_registry_op update "$1" "$2"; }
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
    tmp="$("$MKTEMP_CMD")"
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
    tmp="$("$MKTEMP_CMD")"
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
    while [ "$i" -lt "$TUNNEL_WAIT_TRIES" ]; do
        "$NC_CMD" -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

tunnel_port_in_use() {
    "$NC_CMD" -z 127.0.0.1 "$1" >/dev/null 2>&1
}

# First free port in [start,end] not already used by a registered tunnel.
# Ports to also treat as used (e.g. allocated earlier in the same
# transaction, before the registry reflects them) may be passed as args.
tunnel_pick_port() { # [excluded-port...]
    local port used
    used="$(tunnel_registry_all 2>/dev/null | "$PYTHON3_CMD" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(" ".join(str(f["localPort"]) for t in data["tunnels"] for f in t.get("forwards", [])))
' 2>/dev/null || true) $*"
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
# -----------------------------------------------------------------------------

# Adaptive SSH wrapper (T-410 / T-433)

# -----------------------------------------------------------------------------

# Legacy wrapper fingerprint - used for migration detection (T-433)

TUNNEL_LEGACY_WRAPPER_FINGERPRINT='nc -z 127.0.0.1 1055'



tunnel_ssh_wrapper_content() {
    cat <<'EOF'
#!/bin/sh
# tailroute adaptive proxy wrapper -- generated by `tailroute proxy-config ssh`
# Probes the SOCKS5 proxy with a real handshake to the actual target before use.
# Falls back to direct connection if the proxy is down, not SOCKS5, or cannot
# reach the target.  Timeout: 3 seconds (T-433).
PROXY_ADDR="127.0.0.1"
PROXY_PORT=1055
TIMEOUT=3
HOST="$1"
PORT="$2"

# --- SOCKS5 target-aware probe ---
# Send greeting + CONNECT in one shot.  Read 4 bytes of reply:
#   bytes 1-2 = greeting reply (VER + chosen method)
#   bytes 3-4 = CONNECT reply (VER + reply status)
# CONNECT success = status 0x00, so we expect 05000500.
# Uses shell-builtin printf for \x escapes (macOS /usr/bin/printf lacks them).
dlen=$(printf '%s' "$HOST" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
hi=$(printf '%02x' "$((PORT / 256))")
lo=$(printf '%02x' "$((PORT % 256))")
dlen_byte=$(printf "\x$(printf '%02x' "$dlen")")
RESP=$(printf '\x05\x01\x00\x05\x01\x00\x03%s%s%s' "$dlen_byte" "$HOST" "$hi$lo" | \\
    /usr/bin/nc -w "$TIMEOUT" -q 1 "$PROXY_ADDR" "$PROXY_PORT" 2>/dev/null | \\
    /usr/bin/dd bs=4 count=1 2>/dev/null | /usr/bin/od -A n -t x1 | /usr/bin/tr -d ' \n')
case "$RESP" in
    05000500) exec /usr/bin/nc -X 5 -x "${PROXY_ADDR}:${PROXY_PORT}" "$@" ;;
esac
exec /usr/bin/nc "$@"
EOF
}


# tunnel_ssh_wrapper_is_legacy - returns 0 if the wrapper uses the old

# port-open probe (nc -z) instead of the SOCKS5 handshake.

tunnel_ssh_wrapper_is_legacy() {

    [ -f "$TUNNEL_SSH_WRAPPER" ] || return 1

    grep -qF "$TUNNEL_LEGACY_WRAPPER_FINGERPRINT" "$TUNNEL_SSH_WRAPPER" 2>/dev/null

}



# tunnel_migrate_legacy_wrapper - if the installed wrapper uses the old

# port-open probe (nc -z), regenerate it with the target-aware SOCKS5

# handshake.  Logs the migration.  Returns 0 (success or nothing to do).

tunnel_migrate_legacy_wrapper() {

    if ! tunnel_ssh_wrapper_is_legacy; then

        return 0

    fi

    echo "Migrating legacy proxy wrapper: $TUNNEL_SSH_WRAPPER" >&2

    tunnel_install_ssh_wrapper yes || {

        echo "WARNING: legacy wrapper migration failed" >&2

        return 1

    }

    echo "Legacy wrapper migrated to target-aware SOCKS5 probe" >&2

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

    local pf_err
    pf_err="$("$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$ssh_alias" true 2>&1 >/dev/null)"
    if ! "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$ssh_alias" true >/dev/null 2>&1; then
        echo "ERROR: ssh proxy-$ssh_alias failed (auth or host-key not trusted)." >&2
        [ -n "$pf_err" ] && echo "  ssh said: $pf_err" >&2
        case "$pf_err" in
            *"tailnet policy"*)
                echo "  Hint: the peer has Tailscale SSH enabled; tailnet policy denies this node." >&2
                echo "        Fix on the peer (sudo tailscale set --ssh=false) or grant an ssh rule in the tailnet ACL." >&2 ;;
            *"Permission denied"*)
                echo "  Hint: key authentication failed - is the key loaded (ssh-add) and authorized on the peer?" >&2 ;;
            *"Host key verification"*)
                echo "  Hint: host key not trusted yet - run: ssh proxy-$ssh_alias true" >&2 ;;
        esac
        echo "  Establish trust first:  ssh proxy-$ssh_alias true" >&2
        if [ -n "$ssh_alias" ] && [ "$ssh_alias" != "$peer" ]; then
            echo "  Then re-run:         tailroute tunnel add $peer --ssh-alias $ssh_alias" >&2
        else
            echo "  Then re-run:         tailroute tunnel add $peer" >&2
        fi
        return 1
    fi

    # v0.7.5: launchd jobs run without SSH_AUTH_SOCK. Auth that only works
    # through the agent (passphrase-protected key, no keychain entry) passes
    # here but kills the tunnel job later - warn with the fix up front.
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        if ! env -u SSH_AUTH_SOCK "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$ssh_alias" true >/dev/null 2>&1; then
            echo "WARN: auth for proxy-$ssh_alias depends on the ssh-agent (SSH_AUTH_SOCK)," >&2
            echo "      but the launchd tunnel job runs without it and will fail to connect." >&2
            echo "      Fix: run 'ssh-add --apple-use-keychain' and add 'UseKeychain yes'" >&2
            echo "           to the Host proxy-$ssh_alias block in ~/.ssh/config," >&2
            echo "      or use a passphrase-less key." >&2
        fi
    fi

    if ! tunnel_port_in_use 1055; then
        echo "WARN: SOCKS5 proxy not running — tunnel will use the direct branch (fine when VPN is off or router-side)" >&2
    fi
    return 0
}

# Remote backend soft check — transport can be up while Serve is down (502).
# Probe from the peer against its tailscale IP, not its loopback: Serve
# listeners bind the tailscale interface only, and the launchd forward targets
# <peer-ip>:<port>, so a loopback probe reads every healthy target as down.
tunnel_check_remote_backend() { # <peer> <port> <ssh-alias> <peer-ts-ip>
    local alias="${3:-$1}"
    "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$alias" \
        "/usr/bin/nc -z $4 $2" >/dev/null 2>&1
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
    # v0.7.5: LibreSSL's s_client (macOS /usr/bin/openssl) exits non-zero after
    # a SUCCESSFUL verified handshake — it reports the server's post-handshake
    # close as failure — so gate on the verification output, not the exit
    # status. Found by the first real brew-install tunnel add.
    cert_out="$("$OPENSSL_CMD" s_client -connect "127.0.0.1:$port" \
        -servername "$hostname" \
        -showcerts \
        -verify_return_error \
        2>/dev/null </dev/null)" || true

    if ! printf '%s' "$cert_out" | grep -q '^-----BEGIN CERTIFICATE-----$'; then
        echo "WARN: TLS handshake failed on 127.0.0.1:$port for $hostname" >&2
        return 1
    fi
    if ! printf '%s' "$cert_out" | grep -q 'Verify return code: 0 (ok)'; then
        echo "WARN: TLS verification failed on 127.0.0.1:$port for $hostname (untrusted or expired certificate)" >&2
        return 1
    fi

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
tunnel_build_entry_json() { # peer ip hostname suffix forwards("l:r l:r") [allow_unverified_tls]
    local allow_tls="${7:-no}"
    TUNNEL_E_PEER="$1" TUNNEL_E_IP="$2" TUNNEL_E_HOST="$3" \
    TUNNEL_E_SUFFIX="$4" TUNNEL_E_PLIST="$(tunnel_plist_path_for_peer "$1")" \
    TUNNEL_E_ALIAS="${6:-$1}" TUNNEL_E_TLS="$allow_tls" \
    TUNNEL_E_FORWARDS="$5" "$PYTHON3_CMD" <<'PY'
import datetime, json, os, uuid

fwd = []
for pair in os.environ["TUNNEL_E_FORWARDS"].split():
    l, r = pair.split(":", 1)
    fwd.append({"localPort": int(l), "remotePort": int(r)})
peer = os.environ["TUNNEL_E_PEER"]
peer_id = peer + "." + uuid.uuid4().hex[:8]
job_id = os.environ["TUNNEL_E_PLIST"].split("/")[-1].replace(".plist", "") or ("job-" + uuid.uuid4().hex[:8])
print(json.dumps({
    "peer": peer,
    "peerID": peer_id,
    "jobID": job_id,
    "tailscaleIP": os.environ["TUNNEL_E_IP"],
    "hostname": os.environ["TUNNEL_E_HOST"],
    "magicDNSSuffix": os.environ["TUNNEL_E_SUFFIX"],
    "sshAlias": os.environ["TUNNEL_E_ALIAS"],
    "forwards": fwd,
    "plistPath": os.environ["TUNNEL_E_PLIST"],
    "allowUnverifiedTLS": os.environ["TUNNEL_E_TLS"] == "yes",
    "transactions": [],
    "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, sort_keys=True))
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

# T-413: best-effort autodetect of the peer's tailscale serve LISTEN ports
# (never backend ports — forwards must hit Serve so the browser gets valid
# TLS). Prints space-separated ports; prints nothing when the peer is
# locked down or serves nothing, which callers treat as silent fallback.
tunnel_detect_serve_ports() { # <alias>
    local out
    out="$("$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$1" \
        "tailscale serve status" 2>/dev/null </dev/null)" || return 0
    [ -n "$out" ] || return 0
    printf '%s' "$out" | "$PYTHON3_CMD" -c '
import json, re, sys
raw = sys.stdin.read()
ports = []
def add(p):
    if p and p not in ports:
        ports.append(p)
try:
    d = json.loads(raw)
except Exception:
    d = None
if isinstance(d, dict):
    for u in d.get("Web", {}).keys():
        m = re.search(r":(\d+)", str(u))
        if m:
            add(m.group(1))
    for k in d.get("TCP", {}).keys():
        add(str(k))
else:
    for m in re.finditer(r"https?://[^\s\"]+:(\d+)", raw):
        add(m.group(1))
print(" ".join(ports))
'
}

# -----------------------------------------------------------------------------
# Serve-config drift advisor (T-439) — strictly read-only
# -----------------------------------------------------------------------------
# `tunnel drift <peer>` compares what a peer's `tailscale serve` config claims
# (queried over ssh) with the local tunnel registry and prints the difference.
# It writes nothing — no registry, no hosts, no plists, no journal, and not even
# a lock dir (acquiring the transaction lock would itself create a directory).
# It never touches the peer. There is no apply path and none may grow: every
# suggestion is a full command the human runs themselves, and removal stays
# manual by policy.

# Probe the peer's serve status. Deliberately NOT tunnel_detect_serve_ports,
# whose contract folds every failure into "no ports": here the outcome is
# explicit, because a peer that cannot be queried is not a peer that serves
# nothing.
#   rc 0 + claims on stdout  peer reported a parseable serve config. Claims are
#                            TSV `listen-port<TAB>backend`; an EMPTY stdout is a
#                            verdict too — the peer reports no serve config.
#   rc 3                     probe FAILED (ssh could not run the command) — no verdict
#   rc 4                     the peer replied, but the output is unrecognizable — no verdict
tunnel_probe_serve_config() { # <alias>
    local alias="$1" raw
    raw="$("$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=5 "proxy-$alias" \
        "tailscale serve status" 2>/dev/null </dev/null)" || return 3
    TUNNEL_PROBE_SERVE_RAW="$raw" "$PYTHON3_CMD" <<'PY' || return 4
import json, os, re, sys

raw = os.environ["TUNNEL_PROBE_SERVE_RAW"]
stripped = raw.strip()

def port_of(url):
    # https://host.ts.net without an explicit port is serve's default 443.
    m = re.search(r":(\d+)", url)
    if m:
        return m.group(1)
    return "443" if url.lower().startswith("https://") else "80"

def collect(rows):
    # One HTTPS endpoint shows up in both Web and TCP; keep one claim per port
    # and let a later report fill in a backend the earlier one lacked.
    by_port = {}
    for port, backend in rows:
        if port in by_port and by_port[port]:
            continue
        by_port[port] = backend
    return list(by_port.items())

def emit(rows):
    for port, backend in collect(rows):
        print("%s\t%s" % (port, backend))
    sys.exit(0)

# Nothing on the wire — or tailscale's own "no serve config" wording — is a
# parseable empty report: the peer answered and serves nothing.
if stripped == "" or "no serve config" in stripped.lower():
    emit([])

rows = []
try:
    data = json.loads(stripped)
except Exception:
    data = None
if isinstance(data, dict):
    web = data.get("Web") or {}
    for url in web.keys():
        backend = ""
        for handler in ((web[url] or {}).get("Handlers") or {}).values():
            candidate = (handler or {}).get("Backend") or ""
            if candidate and not backend:
                backend = candidate
        rows.append((port_of(str(url)), backend))
    for listen, spec in (data.get("TCP") or {}).items():
        # A hostile or odd key is dropped rather than reported or turned into a port.
        if re.match(r"^[0-9]+$", str(listen)):
            rows.append((str(listen), (spec or {}).get("Backend") or ""))
    emit(rows)

# Older builds print human-readable status: a listen URL on its own line, with
# the backend on a "|-" continuation line under it.
last = None
for line in stripped.splitlines():
    bare = line.strip()
    if bare.startswith("|"):
        if last is not None and not rows[last][1]:
            m = re.search(r"https?://[^\s\"']+", bare)
            if m:
                rows[last] = (rows[last][0], m.group(0))
        continue
    m = re.search(r"https?://[^\s\"']+", bare)
    if not m:
        continue
    rows.append((port_of(m.group(0)), ""))
    last = len(rows) - 1
if rows:
    emit(rows)

sys.exit(4)   # the peer replied, but nothing recognizable — no verdict
PY
}

# Read-only registry snapshot for the advisor. Deliberately does NOT go through
# tunnel_registry_check_env: that helper mkdir/chmods the config dir, and drift
# must write nothing — including on a machine that never created a registry.
# Prints two lines: the peer's entry JSON ("" when the peer is unregistered) and
# every registered local port, space-separated (forward-cap arithmetic).
# rc: 0 ok · 6 registry unreadable (corrupt or unsupported version)
tunnel_drift_registry_state() { # <peer>
    if [[ -L "$TUNNEL_REGISTRY" ]]; then
        echo "ERROR: $TUNNEL_REGISTRY is a symlink — refusing to read" >&2
        return 6
    fi
    if [ ! -f "$TUNNEL_REGISTRY" ]; then
        printf '\n\n'
        return 0
    fi
    TUNNEL_DRIFT_PEER="$1" TUNNEL_DRIFT_VERSION="$TUNNEL_REGISTRY_VERSION" \
    TUNNEL_DRIFT_REGISTRY="$TUNNEL_REGISTRY" "$PYTHON3_CMD" <<'PY'
import json, os, sys

peer = os.environ["TUNNEL_DRIFT_PEER"]
try:
    # Opened by path, not stdin: the heredoc below owns this process's stdin.
    with open(os.environ["TUNNEL_DRIFT_REGISTRY"], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.stderr.write("ERROR: cannot read the tunnel registry\n")
    sys.exit(6)
if (not isinstance(data, dict)
        or data.get("version") != int(os.environ["TUNNEL_DRIFT_VERSION"])
        or not isinstance(data.get("tunnels"), list)):
    sys.stderr.write("ERROR: tunnel registry version unsupported or corrupt\n")
    sys.exit(6)

entry = ""
ports = []
for t in data["tunnels"]:
    if not isinstance(t, dict):
        continue
    if entry == "" and t.get("peer") == peer:
        entry = json.dumps(t, sort_keys=True)
    for f in t.get("forwards") or []:
        if isinstance(f, dict) and isinstance(f.get("localPort"), int):
            ports.append(str(f["localPort"]))
print(entry)
print(" ".join(ports))
PY
}

# Render the report. Peer-derived strings are semi-untrusted: they are printed,
# never executed, and backends are reduced to inert characters before printing.
tunnel_drift_render() { # <peer> <entry-json-or-""> <claims-tsv> <cap>
    TUNNEL_DRIFT_PEER="$1" TUNNEL_DRIFT_ENTRY="$2" TUNNEL_DRIFT_CLAIMS="$3" \
    TUNNEL_DRIFT_CAP="$4" TUNNEL_DRIFT_PORT_START="$TUNNEL_PORT_START" \
    TUNNEL_DRIFT_PORT_END="$TUNNEL_PORT_END" "$PYTHON3_CMD" <<'PY'
import json, os, re, sys

peer = os.environ["TUNNEL_DRIFT_PEER"]
cap = int(os.environ["TUNNEL_DRIFT_CAP"])
start = os.environ["TUNNEL_DRIFT_PORT_START"]
end = os.environ["TUNNEL_DRIFT_PORT_END"]

claims = []
for line in os.environ["TUNNEL_DRIFT_CLAIMS"].splitlines():
    parts = line.split("\t")
    port = parts[0] if parts else ""
    if not re.match(r"^[0-9]+$", port):
        continue
    backend = parts[1] if len(parts) > 1 else ""
    if not re.match(r"^[A-Za-z0-9._:/?#[\]()*-]*$", backend):
        backend = "(unrecognized backend)"
    claims.append((port, backend))

entry_raw = os.environ["TUNNEL_DRIFT_ENTRY"]
registered = entry_raw != ""
hostname = ""
forwards = []
if registered:
    entry = json.loads(entry_raw)
    hostname = entry.get("hostname", "")
    for f in entry.get("forwards") or []:
        forwards.append((str(f.get("localPort")), str(f.get("remotePort"))))

reg_remote = [r for _, r in forwards]
claim_ports = [p for p, _ in claims]
missing = [c for c in claims if c[0] not in reg_remote]
stale = [f for f in forwards if f[1] not in claim_ports]

if not registered:
    if claims:
        n = len(claims)
        print("%s: peer reports %d serve endpoint%s — not registered"
              % (peer, n, "" if n == 1 else "s"))
    else:
        print("%s: peer reports no serve config — not registered" % peer)
elif missing or stale:
    print("%s: drift between the registry and the peer's serve config" % peer)
else:
    print("%s: no drift — registry matches the peer's serve config" % peer)

print("  Registry forwards:")
if registered:
    for local, remote in forwards:
        print("    127.0.0.1:%s -> remote %s   https://%s:%s" % (local, remote, hostname, local))
else:
    print("    (none — this peer is not registered)")

print("  Peer reports (queried over ssh; read-only):")
if claims:
    for port, backend in claims:
        print("    %s (backend %s)" % (port, backend or "unreported"))
else:
    print("    (none — the peer reports no serve config)")

if missing and registered:
    print("  Reported but not forwarded:")
    for port, _ in missing:
        print("    %s" % port)
        print("    Run it yourself: tailroute tunnel add %s --remote-port %s" % (peer, port))
if stale:
    print("  Forwarded but not reported (the peer no longer serves these):")
    for local, remote in stale:
        print("    remote %s (local %s)   https://%s:%s" % (remote, local, hostname, local))
        print("    Run it yourself: tailroute tunnel remove %s && tailroute tunnel add %s"
              % (peer, peer))

if len(claims) > cap:
    print("  Cap: the peer reports %d serve endpoints; the local port range %s-%s has %d"
          " free ports, so not all of them can be forwarded" % (len(claims), start, end, cap))

if not registered:
    if claims and len(claims) <= cap:
        print("  Equivalent: tailroute tunnel add %s --remote-port %s"
              % (peer, ",".join(p for p, _ in claims)))
    else:
        print("  Equivalent: tailroute tunnel add %s" % peer)

print("  Policy: drift applies nothing — it cannot change the registry, hosts,")
print("  launchd jobs, or the peer's serve config. Every command above is yours to run.")
PY
}

# `tunnel drift <peer>` (T-439) — read-only serve-config advisor.
# Exit: 0 a verdict was produced (including "the peer serves nothing")
#       1 no verdict (probe failed, output unparseable, registry unreadable)
#       2 usage error (missing/invalid peer, or any flag — drift takes none)
tunnel_do_drift() {
    [ $# -gt 0 ] || { echo "ERROR: tunnel drift requires <peer>" >&2; return 2; }
    local peer="$1"
    shift
    [ $# -eq 0 ] || {
        echo "ERROR: tunnel drift takes no flags or extra arguments — it is read-only advice (got '$1')" >&2
        return 2
    }
    peer="$(tunnel_normalize_lower "$peer")"
    tunnel_validate_peer_label "$peer" || { echo "ERROR: invalid peer label '$peer'" >&2; return 2; }

    local state entry="" reg_ports=""
    state="$(tunnel_drift_registry_state "$peer")" || {
        echo "$peer: registry unreadable — no verdict; inspect with: tailroute tunnel status"
        return 1
    }
    entry="$(printf '%s\n' "$state" | sed -n '1p')"
    reg_ports="$(printf '%s\n' "$state" | sed -n '2p')"

    # A registered peer is queried through the alias it was added with
    # (same rule add/update apply); an unregistered peer falls back to proxy-<peer>.
    local alias="$peer"
    if [ -n "$entry" ]; then
        alias="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; e=json.load(sys.stdin); print(e.get("sshAlias") or e["peer"])' 2>/dev/null)" || alias="$peer"
    fi

    local claims="" prc=0
    claims="$(tunnel_probe_serve_config "$alias")" || prc=$?
    if [ "$prc" -eq 3 ]; then
        echo "$peer: probe FAILED — no verdict"
        echo "  'tailscale serve status' over ssh to proxy-$alias did not succeed. Nothing was changed."
        echo "  Trust the host first:  ssh proxy-$alias true"
        echo "  Missing ssh config?  tailroute proxy-config ssh --peer $peer"
        return 1
    fi
    if [ "$prc" -eq 4 ]; then
        echo "$peer: serve status unparseable — no verdict"
        echo "  proxy-$alias replied, but the output is not a recognizable serve config. Nothing was changed."
        echo "  Inspect it yourself:  ssh proxy-$alias 'tailscale serve status'"
        return 1
    fi

    # Forward cap: free local ports in the allocation range (T-404.1) — i.e. how
    # many of the peer's reported endpoints could actually be forwarded.
    local cap=0 p
    # shellcheck disable=SC2086  # seq output is a plain port list
    for p in $(seq "$TUNNEL_PORT_START" "$TUNNEL_PORT_END"); do
        case " $reg_ports " in *" $p "*) continue ;; esac
        cap=$((cap + 1))
    done

    tunnel_drift_render "$peer" "$entry" "$claims" "$cap"
    return 0
}

# T-436: append one or more forwards to an existing peer's job, replacing the
# launchd job transactionally (restore the previous healthy job on failure).
# Per-user lock must already be held. Local ports come from tunnel_pick_port,
# which skips every registered local port and every port allocated earlier in
# this call, so (peer, localPort, remotePort) identities stay unique.
tunnel_update_add_forward() { # <peer> <remote-port>...
    local peer="$1"; shift
    local entry new_fwd lport rport
    entry="$(tunnel_registry_get "$peer")" || {
        echo "ERROR: no registry entry for '$peer'" >&2; return 1; }

    local ip hostname alias allow_tls pairs lport
    ip="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin)["tailscaleIP"])')"
    hostname="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin)["hostname"])')"
    alias="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("sshAlias", ""))')"
    allow_tls="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print("yes" if json.load(sys.stdin).get("allowUnverifiedTLS") else "no")')"
    pairs="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"

    new_fwd="$entry"
    local added_lports="" added_pairs=""
    for rport in "$@"; do
        # Forward identity is (peer, localPort, remotePort); local ports are
        # freshly allocated, so a duplicate reduces to a repeated remote port.
        if ! printf '%s' "$new_fwd" | "$PYTHON3_CMD" -c '
import json, sys
e = json.load(sys.stdin)
sys.exit(1 if any(f["remotePort"] == int(sys.argv[1]) for f in e["forwards"]) else 0)
' "$rport"; then
            echo "ERROR: remote port $rport is already forwarded for '$peer'" >&2
            return 1
        fi
        # shellcheck disable=SC2086  # $added_lports intentionally word-splits
        lport="$(tunnel_pick_port $added_lports)" || return 1
        new_fwd="$(printf '%s' "$new_fwd" | "$PYTHON3_CMD" -c '
import json, sys
e = json.load(sys.stdin)
e["forwards"].append({"localPort": int(sys.argv[1]), "remotePort": int(sys.argv[2])})
print(json.dumps(e, sort_keys=True))
' "$lport" "$rport")" || {
            echo "ERROR: failed to build updated entry for '$peer'" >&2; return 1; }
        added_lports="$added_lports $lport"
        added_pairs="$added_pairs $lport:$rport"
        pairs="$pairs $lport:$rport"
    done
    added_lports="${added_lports# }"
    added_pairs="${added_pairs# }"
    pairs="${pairs# }"

    local label plist log_path
    label="$(tunnel_label_for_peer "$peer")"
    plist="$(tunnel_plist_path_for_peer "$peer")"
    log_path="$TUNNEL_LOG_DIR/tunnel-$peer.log"

    # T-437b: the snapshot IS the rollback (old plist bytes).  Take it before
    # any mutation — a silent `cp || true` left every rollback branch below
    # restoring nothing, so a failed copy now aborts a consistent update.
    if [ ! -f "$plist" ]; then
        echo "ERROR: cannot snapshot $plist (missing) — aborting update before any mutation; run 'tailroute tunnel status' to repair" >&2
        return 1
    fi
    if ! cp "$plist" "$plist.prev"; then
        rm -f "$plist.prev"
        echo "ERROR: cannot snapshot $plist — aborting update before any mutation; run 'tailroute tunnel status' to repair" >&2
        return 1
    fi

    # T-437a: write-ahead.  Journal the intended update BEFORE any registry
    # mutation — the add path already does this.  A crash past this point
    # leaves recoverable state; a failed journal write aborts instead of
    # mutating a registry no journal could vouch for.
    local update_steps='["registry","plist","bootstrap","tls"]'
    if ! _tun_journal_write update "$peer" "$update_steps" '[]'; then
        rm -f "$plist.prev"
        echo "ERROR: cannot write the recovery journal $TUNNEL_JOURNAL_PATH — aborting update before any mutation" >&2
        return 1
    fi

    tunnel_registry_update "$peer" "$new_fwd" || {
        rm -f "$plist.prev"; _tun_journal_clear; return 1; }
    tunnel_job_bootout "$label" >/dev/null 2>&1 || true

    # shellcheck disable=SC2086  # $pairs intentionally word-splits into l:r pair args
    if ! tunnel_generate_plist "$peer" "$ip" "$log_path" "${alias:-$peer}" $pairs > "$plist" \
        || ! tunnel_plist_lint "$plist"; then
        echo "ROLLED BACK: could not regenerate job — previous job restored" >&2
        if [ -f "$plist.prev" ]; then mv "$plist.prev" "$plist"; else rm -f "$plist"; fi
        [ -f "$plist" ] && tunnel_job_bootstrap "$plist" >/dev/null 2>&1 || true
        tunnel_registry_update "$peer" "$entry" >/dev/null 2>&1 || true
        _tun_journal_clear
        return 1
    fi
    chmod 0644 "$plist"
    _tun_journal_write update "$peer" "$update_steps" '["registry","plist"]' || true

    if ! tunnel_job_bootstrap "$plist"; then
        echo "ROLLED BACK: job bootstrap failed — previous job restored" >&2
        if [ -f "$plist.prev" ]; then mv "$plist.prev" "$plist"; else rm -f "$plist"; fi
        [ -f "$plist" ] && tunnel_job_bootstrap "$plist" >/dev/null 2>&1 || true
        tunnel_registry_update "$peer" "$entry" >/dev/null 2>&1 || true
        _tun_journal_clear
        return 1
    fi
    _tun_journal_write update "$peer" "$update_steps" '["registry","plist","bootstrap"]' || true

    # TLS identity verification on every newly bound local port (T-430 rule)
    local lp
    for lp in $added_lports; do
        tunnel_wait_for_port "$lp" || \
            echo "WARN: job loaded but 127.0.0.1:$lp is not listening yet — check: tail -f $log_path" >&2
        if ! tunnel_tls_verify_or_skip "$hostname" "$lp" "$allow_tls"; then
            echo "ROLLED BACK: TLS identity verification failed on 127.0.0.1:$lp — previous job restored" >&2
            tunnel_job_bootout "$label" >/dev/null 2>&1 || true
            if [ -f "$plist.prev" ]; then mv "$plist.prev" "$plist"; fi
            [ -f "$plist" ] && tunnel_job_bootstrap "$plist" >/dev/null 2>&1 || true
            tunnel_registry_update "$peer" "$entry" >/dev/null 2>&1 || true
            _tun_journal_clear
            return 1
        fi
    done

    rm -f "$plist.prev"
    _tun_journal_write update "$peer" "$update_steps" '["registry","plist","bootstrap","tls"]' || true
    _tun_journal_clear
    local ap
    for ap in $added_pairs; do
        lport="${ap%%:*}"; rport="${ap##*:}"
        echo "  URL: https://$hostname:$lport (forwards to remote port $rport)"
    done
    echo "Forward added: $peer"
    return 0
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
                # Commas are list separators: --remote-port 8000,8765,10254 is
                # shorthand for repeating the flag; all forwards still land in
                # ONE incremental transaction (single job restart).
                raw_remote="$raw_remote ${2//,/ }"; shift 2 ;;
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

    # v0.7.7: a registered peer's ssh alias is already stored in its registry
    # entry — an incremental add without --ssh-alias must adopt it instead of
    # demanding a new 'proxy-<peer>' config entry. An explicit --ssh-alias
    # still wins.
    if [ -z "$ssh_alias" ] && tunnel_registry_get "$peer" >/dev/null 2>&1; then
        local stored_alias
        stored_alias="$(tunnel_registry_get "$peer" 2>/dev/null | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("sshAlias", ""))' 2>/dev/null || true)"
        [ -n "$stored_alias" ] && ssh_alias="$stored_alias"
    fi

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
        if [ -n "$(printf '%s' "$raw_remote" | tr -d ' ')" ]; then
            # T-436: incremental forward onto the existing job. Unlike add,
            # update is not idempotent (the crashed attempt may have already
            # appended the forward), so any incomplete journal gates it.
            if _tun_journal_has_incomplete; then
                echo "ERROR: incomplete journal for '$(_tun_journal_peer)' ($(_tun_journal_op)) — recover with 'tailroute tunnel journal clear' (state: 'tailroute tunnel status')" >&2
                tunnel_lock_release; return 1
            fi
            tunnel_update_add_forward "$peer" $raw_remote || { tunnel_lock_release; return 1; }
            tunnel_lock_release
            # tunnel_update_add_forward already printed the URL list and the
            # confirmation — printing it here duplicated both lines (v0.7.8).
            return 0
        fi
        echo "ERROR: tunnel for '$peer' already registered — remove it first: tailroute tunnel remove $peer" >&2
        tunnel_lock_release; return 1
    fi

    # sudo up front so a mid-transaction expiry can't strand a rollback -
    # and before any hosts work (v0.7.4: hosts-adopt precedes the transaction
    # and needs cached sudo for its privileged steps).
    if [ -n "$TUNNEL_SUDO_CMD" ]; then
        "$TUNNEL_SUDO_CMD" -v || { echo "ERROR: sudo unavailable for /etc/hosts edit" >&2; tunnel_lock_release; return 1; }
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
            raw_remote="$(tunnel_detect_serve_ports "${ssh_alias:-$peer}")"
            if [ -z "$raw_remote" ]; then
                raw_remote=" 443"
            fi
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

    tunnel_check_remote_backend "$peer" "$rport" "${ssh_alias:-$peer}" "$ip" || \
        echo "WARN: remote port $rport not accepting on $peer — Serve may not be configured there" >&2
    echo "NOTE: the /etc/hosts mapping is system-wide — it affects every user of this Mac." >&2

    # --- Transaction: registry → hosts → plist (+lint) → bootstrap → TLS verify ---
    # Lock ordering: per-user (already held) → machine-wide hosts lock
    # Release in reverse: hosts lock → per-user

    # Check for incomplete journal from a previous crash
    if _tun_journal_has_incomplete; then
        local jpeer jop
        jpeer="$(_tun_journal_peer)"
        jop="$(_tun_journal_op)"
        if [ "$jpeer" = "$peer" ] && [ "$jop" = "add" ]; then
            echo "NOTE: recovering incomplete add for '$peer' from previous run" >&2
        else
            echo "ERROR: incomplete journal for '$jpeer' ($jop) — recover with 'tailroute tunnel journal clear' (state: 'tailroute tunnel status')" >&2
            tunnel_lock_release; return 1
        fi
    fi

    local add_steps='["registry","hosts","plist","bootstrap","tls"]'
    local entry rolled_back=""
    entry="$(tunnel_build_entry_json "$peer" "$ip" "$full_hostname" "$suffix" "$forwards" "${ssh_alias:-$peer}" "$allow_unverified_tls")" || {
        tunnel_lock_release; return 1; }

    # Step 1: registry
    _tun_journal_write add "$peer" "$add_steps" '[]' || true
    if ! tunnel_registry_add "$peer" "$entry"; then
        _tun_journal_clear
        tunnel_lock_release; return 1
    fi
    _tun_journal_write add "$peer" "$add_steps" '["registry"]' || true

    # Step 2: hosts (under machine-wide lock)
    tunnel_hosts_lock_acquire "$TUNNEL_HOSTS_LOCK_DIR" || {
        echo "ROLLED BACK: registry entry (hosts lock busy)" >&2
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        _tun_journal_clear
        tunnel_lock_release; return 1
    }
    if ! tunnel_hosts_apply add "$full_hostname"; then
        echo "ROLLED BACK: registry entry" >&2
        tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        _tun_journal_clear
        tunnel_lock_release; return 1
    fi
    _tun_journal_write add "$peer" "$add_steps" '["registry","hosts"]' || true

    # Step 3: plist
    mkdir -p "$TUNNEL_LOG_DIR"; chmod 0700 "$TUNNEL_LOG_DIR" 2>/dev/null || true
    local log_path="$TUNNEL_LOG_DIR/tunnel-$peer.log"
    # shellcheck disable=SC2086  # $forwards intentionally word-splits into l:r pair args
    if ! tunnel_generate_plist "$peer" "$ip" "$log_path" "${ssh_alias:-$peer}" $forwards > "$plist" || ! tunnel_plist_lint "$plist"; then
        echo "ROLLED BACK: hosts entry, registry entry" >&2
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || rolled_back="hosts"
        tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        [ -n "$rolled_back" ] && echo "  MANUAL REVERT NEEDED: remove '$full_hostname' from $TUNNEL_HOSTS_FILE (sudo)" >&2
        _tun_journal_clear
        tunnel_lock_release; return 1
    fi
    chmod 0644 "$plist"
    _tun_journal_write add "$peer" "$add_steps" '["registry","hosts","plist"]' || true

    # Step 4: bootstrap
    if ! tunnel_job_bootstrap "$plist"; then
        echo "ROLLED BACK: plist, hosts entry, registry entry" >&2
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || rolled_back="hosts"
        tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        [ -n "$rolled_back" ] && echo "  MANUAL REVERT NEEDED: remove '$full_hostname' from $TUNNEL_HOSTS_FILE (sudo)" >&2
        _tun_journal_clear
        tunnel_lock_release; return 1
    fi
    _tun_journal_write add "$peer" "$add_steps" '["registry","hosts","plist","bootstrap"]' || true

    # Release hosts lock — no more /etc/hosts mutations in add
    tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"

    if ! tunnel_wait_for_port "$lport"; then
        echo "WARN: job loaded but 127.0.0.1:$lport is not listening yet — check: tail -f $log_path" >&2
    fi

    # Step 5: TLS identity verification (T-430)
    if ! tunnel_tls_verify_or_skip "$full_hostname" "$lport" "$allow_unverified_tls"; then
        echo "ROLLED BACK: TLS identity verification failed — certificate does not match '$full_hostname'" >&2
        tunnel_job_bootout "$(tunnel_label_for_peer "$peer")" || true
        rm -f "$plist"
        tunnel_hosts_apply remove "$full_hostname" >/dev/null 2>&1 || true
        tunnel_registry_remove "$peer" >/dev/null 2>&1
        _tun_journal_clear
        tunnel_lock_release; return 1
    fi

    # Transaction complete — clear journal
    _tun_journal_write add "$peer" "$add_steps" '["registry","hosts","plist","bootstrap","tls"]' || true
    _tun_journal_clear

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

    # Check for incomplete journal from a previous crash
    if _tun_journal_has_incomplete; then
        local jpeer jop
        jpeer="$(_tun_journal_peer)"
        jop="$(_tun_journal_op)"
        if [ "$jpeer" = "$peer" ] && [ "$jop" = "remove" ]; then
            echo "NOTE: recovering incomplete remove for '$peer' from previous run" >&2
        else
            echo "ERROR: incomplete journal for '$jpeer' ($jop) — recover with 'tailroute tunnel journal clear' (state: 'tailroute tunnel status')" >&2
            tunnel_lock_release; return 1
        fi
    fi

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

    local remove_steps='["bootout","plist","hosts","registry"]'

    # Step 1: bootout
    _tun_journal_write remove "$peer" "$remove_steps" '[]' || true
    if tunnel_job_is_loaded "$label"; then
        tunnel_job_bootout "$label" || true
    fi
    _tun_journal_write remove "$peer" "$remove_steps" '["bootout"]' || true

    # Step 2: plist
    [ -f "$plist" ] && rm -f "$plist"
    _tun_journal_write remove "$peer" "$remove_steps" '["bootout","plist"]' || true

    # Step 3: hosts (under machine-wide lock)
    tunnel_hosts_lock_acquire "$TUNNEL_HOSTS_LOCK_DIR" || {
        echo "WARN: hosts lock busy — skipping hosts removal; remove '$hostname' manually from $TUNNEL_HOSTS_FILE (sudo)" >&2
        failed="hosts"
    }
    if [ -z "$failed" ]; then
        if ! tunnel_hosts_apply remove "$hostname"; then
            echo "ERROR: could not remove hosts entry — manual revert: remove '$hostname' inside $TUNNEL_HOSTS_FILE markers (sudo)" >&2
            failed="hosts"
        fi
        tunnel_hosts_lock_release "$TUNNEL_HOSTS_LOCK_DIR"
    fi
    _tun_journal_write remove "$peer" "$remove_steps" '["bootout","plist","hosts"]' || true

    # Step 4: registry + log cleanup
    tunnel_registry_remove "$peer" >/dev/null 2>&1 || true
    local log_file="$TUNNEL_LOG_DIR/tunnel-$peer.log"
    [ -f "$log_file" ] && rm -f "$log_file"

    _tun_journal_clear
    tunnel_lock_release
    if [ -n "$failed" ]; then
        return 1
    fi
    echo "Tunnel removed: $peer (hosts entry and launchd job cleaned up)"
    return 0
}

# -----------------------------------------------------------------------------
# T-437: `tunnel journal clear` — first-class recovery for a stranded journal
# -----------------------------------------------------------------------------
# Recovery is a command, not magic.  Per-op rules for an INCOMPLETE entry:
#   add    → refused without --force: an interrupted add may hold a live
#            /etc/hosts mapping or a half-built job that clearing would orphan
#   update → allowed: with write-ahead ordering, a re-run either appends
#            cleanly or hits the shipped duplicate-refusal; remedy is printed
#   remove → allowed (removal is idempotent)
# A complete entry (completed == steps) holds no stranded state and always
# clears.  Duplicate-refusal on re-run is unchanged — this command is the one
# remedy for every half-state.
tunnel_do_journal_clear() {
    local force="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f) force="yes" ;;
            -*) echo "ERROR: unknown tunnel journal clear flag '$1'" >&2; return 2 ;;
            *) echo "ERROR: unexpected argument '$1'" >&2; return 2 ;;
        esac
        shift
    done

    if [ ! -f "$TUNNEL_JOURNAL_PATH" ]; then
        echo "No incomplete journal — nothing to clear."
        return 0
    fi

    local jop jpeer
    jop="$(_tun_journal_op)"
    jpeer="$(_tun_journal_peer)"
    echo "Journal at $TUNNEL_JOURNAL_PATH:"
    cat "$TUNNEL_JOURNAL_PATH"

    if ! _tun_journal_has_incomplete; then
        echo "Journal entry is complete — no stranded state; clearing it."
        _tun_journal_clear
        return 0
    fi

    case "$jop" in
        add)
            if [ "$force" != "yes" ]; then
                echo "ERROR: interrupted 'add' for '$jpeer' — it may hold a live /etc/hosts mapping or a half-built job" >&2
                echo "Inspect first:   tailroute tunnel status" >&2
                echo "Explicit clear:  tailroute tunnel journal clear --force" >&2
                return 1
            fi
            echo "Cleared interrupted 'add' for '$jpeer' (--force) — leftovers, if any, are reported by:"
            echo "  tailroute tunnel status"
            ;;
        update)
            echo "Interrupted 'update' for '$jpeer'. Remedy:"
            echo "  tailroute tunnel remove $jpeer && tailroute tunnel add $jpeer"
            echo "Journal cleared."
            ;;
        remove)
            echo "Interrupted 'remove' for '$jpeer' — removal is idempotent; re-run if anything remains:"
            echo "  tailroute tunnel remove $jpeer"
            echo "Journal cleared."
            ;;
        *)
            if [ "$force" != "yes" ]; then
                echo "ERROR: unrecognized stranded op '$jop' for '$jpeer' — refusing without --force" >&2
                return 1
            fi
            echo "Cleared unrecognized journal op '$jop' for '$jpeer' (--force)."
            ;;
    esac
    _tun_journal_clear
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
    local entry p hostname ip suffix label ssh_alias
    local job hosts_state notes lookup_row online cur_ip cur_suffix
    local fwd_pairs allow_tls pair lport rport listener backend
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        hostname="$(tunnel_registry_field "$entry" hostname)"
        ip="$(tunnel_registry_field "$entry" tailscaleIP)"
        suffix="$(tunnel_registry_field "$entry" magicDNSSuffix)"
        ssh_alias="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin).get("sshAlias", ""))')"
        fwd_pairs="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(" ".join(str(f["localPort"]) + ":" + str(f["remotePort"]) for f in json.load(sys.stdin)["forwards"]))')"
        allow_tls="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print("unverified" if json.load(sys.stdin).get("allowUnverifiedTLS") else "verified")')"
        label="$(tunnel_label_for_peer "$p")"

        notes=""
        if tunnel_job_is_loaded "$label"; then job="running"; else job="not-running"; fi
        if tunnel_hosts_has_mapping "$hostname"; then hosts_state="present"; else hosts_state="missing"; fi

        if [ "$job" = "not-running" ] && [ "$hosts_state" = "present" ]; then
            notes="stale hosts entry (browser gets connection refused)"
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

        # T-435: registry says this tunnel exists — its plist must too
        local plist_state
        if [ -f "$(tunnel_plist_path_for_peer "$p")" ]; then
            plist_state="present"
        else
            plist_state="missing"
            notes="${notes:+$notes; }plist missing — repair: tailroute tunnel remove $p && tailroute tunnel add $p"
        fi

        # One row per forward (T-436): identity is (peer, localPort, remotePort)
        for pair in $fwd_pairs; do
            lport="${pair%%:*}"; rport="${pair##*:}"
            if tunnel_port_in_use "$lport"; then listener="listening"; else listener="closed"; fi
            if [ "$skip_remote" = "yes" ]; then
                backend="n/a"
            elif tunnel_check_remote_backend "$p" "$rport" "${ssh_alias:-$p}" "$ip"; then
                backend="accepting"
            else
                backend="not accepting"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$p" "$hostname" "$lport" "$rport" "$listener" "$backend" "$allow_tls" "$job" "$hosts_state" "$notes" "$plist_state"
        done
    done <<EOF
$(tunnel_registry_entries)
EOF
}

# T-435: recognized orphan state — managed hosts lines and launchd jobs with
# no registry entry. Emits kind<TAB>detail<TAB>repair rows.
tunnel_status_orphans() {
    local entry p h reg_peers=" " reg_hosts=" " oh label pl
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        h="$(tunnel_registry_field "$entry" hostname)"
        reg_peers="$reg_peers$p "
        reg_hosts="$reg_hosts$h "
    done <<EOF
$(tunnel_registry_entries 2>/dev/null || true)
EOF
    if [ -f "$TUNNEL_HOSTS_FILE" ]; then
        while IFS= read -r oh; do
            [ -n "$oh" ] || continue
            case " $reg_hosts " in *" $oh "*) continue ;; esac
            printf 'hosts\t%s\tremove the "%s" line inside the managed %s markers (sudo)\n' "$oh" "$oh" "$TUNNEL_HOSTS_FILE"
        done <<EOF
$(awk -F'\t' '/^# BEGIN tailroute-tunnel$/{inblk=1;next} /^# END tailroute-tunnel$/{inblk=0;next} inblk && NF==2 {print $2}' "$TUNNEL_HOSTS_FILE" 2>/dev/null || true)
EOF
    fi
    if [ -d "$TUNNEL_LAUNCHAGENTS_DIR" ]; then
        for pl in "$TUNNEL_LAUNCHAGENTS_DIR"/$TUNNEL_LABEL_PREFIX.*.plist; do
            [ -f "$pl" ] || continue
            label="$(basename "$pl" .plist)"
            p="${label#$TUNNEL_LABEL_PREFIX.}"
            case " $reg_peers " in *" $p "*) continue ;; esac
            printf 'job\t%s\tlaunchctl bootout gui/$UID/%s 2>/dev/null; rm %s\n' "$label" "$label" "$pl"
        done
    fi
    return 0
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

    # Crash recovery: detect incomplete journal
    if _tun_journal_has_incomplete; then
        local jpeer jop journal_txt
        jpeer="$(_tun_journal_peer)"
        jop="$(_tun_journal_op)"
        journal_txt="$(_tun_journal_read)"
        if [ "$json_mode" = "yes" ]; then
            local raw_escaped
            raw_escaped="$(printf '%s' "$journal_txt" | "$PYTHON3_CMD" -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
            printf '{"journal":{"peer":"%s","op":"%s","incomplete":true,"raw":%s}}\n' \
                "$jpeer" "$jop" "$raw_escaped"
        else
            echo "INCOMPLETE JOURNAL: $jop for '$jpeer' — a previous operation did not finish."
            echo "  Journal: $TUNNEL_JOURNAL_PATH"
            echo "  To recover: re-run the same command, or inspect the journal."
            echo "  To discard: tailroute tunnel journal clear [--force]"
        fi
        return 1
    fi

    local rows
    rows="$(tunnel_status_rows "$skip_remote")" || {
        echo '{"error":"registry corrupt or unreadable"}'
        return 2
    }
    # T-435: adaptive path + orphan state, reported in both modes
    local adaptive="direct"
    tunnel_port_in_use 1055 && adaptive="socks5"
    local orphans
    orphans="$(tunnel_status_orphans)"

    if [ -n "$peer" ]; then
        rows="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$peer" '$1 == p')"
        if [ -z "$rows" ]; then
            echo "ERROR: tunnel for '$peer' not found" >&2
            return 3
        fi
    fi

    if [ "$json_mode" = "yes" ]; then
        printf '%s\n' "$rows" | T435_ORPHANS="$orphans" T435_ADAPTIVE="$adaptive" "$PYTHON3_CMD" -c '
import json, os, sys
tunnels = {}
order = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 11: continue
    p, hostname, lport, rport, listener, backend, tls, job, hosts, notes, plist = parts[:11]
    if p not in tunnels:
        order.append(p)
        tunnels[p] = {"peer": p, "hostname": hostname, "localPort": int(lport), "remotePort": int(rport),
                      "job": job, "hosts": hosts, "plist": plist, "notes": notes, "forwards": []}
    fwd = {"localPort": int(lport), "remotePort": int(rport), "listener": listener,
           "backend": backend, "tls": tls}
    # backend n/a (--skip-remote-check) is unknown, not unhealthy
    fwd["healthy"] = listener == "listening" and backend != "not accepting"
    tunnels[p]["forwards"].append(fwd)
out = []
for p in order:
    t = tunnels[p]
    t["healthy"] = (t["job"] == "running" and t["hosts"] == "present"
                    and t["plist"] == "present"
                    and all(f["listener"] == "listening" for f in t["forwards"]))
    out.append(t)
orphans = []
for line in os.environ.get("T435_ORPHANS", "").splitlines():
    parts = line.split("\t")
    if len(parts) >= 3:
        orphans.append({"kind": parts[0], "detail": parts[1], "repair": parts[2]})
print(json.dumps({"version": 2, "adaptivePath": os.environ.get("T435_ADAPTIVE", "direct"),
                  "tunnels": out, "orphans": orphans}))
'
        printf '%s\n' "$rows" | T435_ORPHANS="$orphans" "$PYTHON3_CMD" -c '
import os, sys
degraded = bool(os.environ.get("T435_ORPHANS", "").strip())
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 11: continue
    listener, job, hosts, plist = parts[4], parts[7], parts[8], parts[10]
    if job != "running" or hosts != "present" or listener != "listening" or plist != "present":
        degraded = True
sys.exit(1 if degraded else 0)
' || return 1
        return 0
    fi

    echo "Adaptive path: $adaptive"
    echo ""
    local worst=0 p hostname lport rport listener backend tls job hosts_state notes plist_state prev_peer=""
    if printf '%s\n' "$rows" | grep -q '^.'; then
        while IFS="$(printf '\t')" read -r p hostname lport rport listener backend tls job hosts_state notes plist_state; do
            [ -n "$p" ] || continue
            if [ "$p" != "$prev_peer" ]; then
                [ -n "$prev_peer" ] && echo ""
                echo "$p:"
                echo "  URL:      https://$hostname:$lport"
                echo "  Job:      $job"
                echo "  Hosts:    $hosts_state"
                echo "  Forwards:"
                [ -n "$notes" ] && echo "  Notes:    $notes"
                prev_peer="$p"
            fi
            echo "    127.0.0.1:$lport -> remote $rport  $listener, $tls, backend $backend"
            if [ "$job" != "running" ] || [ "$hosts_state" != "present" ] || [ "$listener" != "listening" ]; then
                worst=1
            fi
        done <<EOF
$rows
EOF
    else
        echo "No tunnels configured."
        echo "Add one: tailroute tunnel add <peer>"
    fi
    if [ -n "$orphans" ]; then
        echo "Orphans:"
        local okind odetail orepair
        while IFS="$(printf '\t')" read -r okind odetail orepair; do
            [ -n "$okind" ] || continue
            echo "  $okind: $odetail"
            echo "    repair: $orepair"
        done <<EOF
$orphans
EOF
        worst=1
    fi
    return "$worst"
}

tunnel_do_list() {
    tunnel_registry_entries
}

# T-420: open the tunnel's bookmarkable URL in the default browser.
tunnel_do_open() { # <peer>
    local peer="${1:-}"
    [ -n "$peer" ] || { echo "ERROR: tunnel open requires <peer>" >&2; return 2; }
    peer="$(tunnel_normalize_lower "$peer")"
    local entry hostname lport url
    entry="$(tunnel_registry_get "$peer" 2>/dev/null)" || {
        echo "ERROR: tunnel for '$peer' not found" >&2; return 3; }
    hostname="$(tunnel_registry_field "$entry" hostname)"
    lport="$(printf '%s' "$entry" | "$PYTHON3_CMD" -c 'import json,sys; print(json.load(sys.stdin)["forwards"][0]["localPort"])')"
    url="https://$hostname:$lport"
    if ! "$OPEN_CMD" "$url"; then
        echo "ERROR: could not open $url in a browser" >&2
        return 1
    fi
    echo "Opened $url"
    return 0
}

# Remove every tunnel (used by `tailroute uninstall`); runs per-user
tunnel_remove_all() {
    # Clear any stale journal before bulk remove
    _tun_journal_clear
    local entry p failed=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        p="$(tunnel_registry_field "$entry" peer)"
        tunnel_do_remove "$p" || failed=1
    done <<EOF
$(tunnel_registry_entries 2>/dev/null || true)
EOF
    rm -f "$TUNNEL_REGISTRY" "$TUNNEL_REGISTRY.bak" 2>/dev/null || true
    [ -d "$TUNNEL_LOG_DIR" ] && rm -f "$TUNNEL_LOG_DIR"/tunnel-*.log 2>/dev/null || true
    _tun_journal_clear
    return "$failed"
}
