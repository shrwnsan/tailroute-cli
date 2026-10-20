#!/bin/bash
# test-tunnel-e2e.sh — End-to-end check of the live browser tunnel path
#
# Exercises the exact path a browser takes for one tunnel:
#   hosts override → 127.0.0.1 → ssh forward listener → TLS (SNI + chain)
#   → HTTPS request (curl validates the certificate like a browser would).
#
# Read-only by default: does not add/remove tunnels or modify any state.
# Transport vs backend health are reported separately — an HTTP 502 with a
# valid TLS chain means the peer's Serve backend is down, not the tunnel.
#
# --lifecycle <peer> appends an opt-in park/resume round trip for that
# registered peer: stop → status reports stopped (exit 0) → listener gone
# → start → same port listening → check passes. It changes run-state only
# (launchd disable/enable + bootout/bootstrap) and never adds or removes a
# tunnel. It drives the CLI in this checkout (override with TAILROUTE_BIN)
# so it can verify a build before the release that ships these verbs.
#
# Usage: scripts/test-tunnel-e2e.sh [hostname] [local-port] [--lifecycle <peer>]
#        (defaults below match the dev-machine prototype)
# Exit: 0 all pass · 1 any failure · 2 usage

set -u

HOSTNAME_ARG="prime.tailnet.ts.net"
PORT="8443"
LIFECYCLE_PEER=""
pos=0
while [ $# -gt 0 ]; do
    case "$1" in
        --lifecycle)
            LIFECYCLE_PEER="${2:-}"
            [ -n "$LIFECYCLE_PEER" ] || { echo "ERROR: --lifecycle requires <peer>" >&2; exit 2; }
            shift 2 ;;
        *)
            pos=$((pos + 1))
            case "$pos" in
                1) HOSTNAME_ARG="$1" ;;
                2) PORT="$1" ;;
                *) echo "ERROR: unexpected argument '$1'" >&2; exit 2 ;;
            esac
            shift ;;
    esac
done
TAILROUTE_BIN="${TAILROUTE_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/tailroute.sh}"

pass=0
fail=0

ok()   { echo "PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }

echo "E2E browser-path check: $HOSTNAME_ARG:$PORT"
echo ""

# 1. Hosts override resolves the tailnet hostname to loopback
ip="$(/usr/bin/python3 -c "import socket; print(socket.gethostbyname('$HOSTNAME_ARG'))" 2>/dev/null)"
if [ "$ip" = "127.0.0.1" ]; then
    ok "1/5 $HOSTNAME_ARG resolves to 127.0.0.1 (hosts override active)"
else
    bad "1/5 resolved to '${ip:-nothing}' — hosts override missing?"
fi

# 2. Tunnel listener on loopback
if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    ok "2/5 127.0.0.1:$PORT listening (SSH forward up)"
else
    bad "2/5 no listener on 127.0.0.1:$PORT — tunnel job down?"
fi

# 3. TLS handshake with SNI serves the real cert and the chain validates
# (LibreSSL prints "Verify return code" with leading spaces — no anchor)
verify="$(echo | /usr/bin/openssl s_client -connect "127.0.0.1:$PORT" -servername "$HOSTNAME_ARG" 2>/dev/null | grep -m1 'Verify return code')"
subject="$(echo | /usr/bin/openssl s_client -connect "127.0.0.1:$PORT" -servername "$HOSTNAME_ARG" 2>/dev/null | grep -m1 '^ *0 s:')"
echo "     cert: $subject"
case "$verify" in
    *"0 (ok)"*) ok "3/5 TLS chain validates ($verify)" ;;
    *)          bad "3/5 TLS verification: ${verify:-no handshake}" ;;
esac

# 4. Browser-equivalent HTTPS request (curl validates against system roots)
http_code="$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "https://$HOSTNAME_ARG:$PORT/" 2>&1)" && curl_rc=0 || curl_rc=$?
if [ "$curl_rc" -eq 0 ] && [ "$http_code" != "000" ]; then
    ok "4/5 HTTPS round trip (HTTP $http_code, certificate accepted)"
    case "$http_code" in
        502|503|504) echo "     NOTE: transport healthy; backend on the peer reports $http_code (Serve upstream down?)" ;;
    esac
else
    bad "4/5 curl rc=$curl_rc code=$http_code"
fi

# 5. Adaptive branch state (informational)
if /usr/bin/nc -z 127.0.0.1 1055 2>/dev/null; then
    echo "INFO: 5/5 SOCKS5 :1055 up — connections take the proxy branch (VPN-side routing)"
    pass=$((pass + 1))
else
    echo "INFO: 5/5 SOCKS5 :1055 down — connections take the direct branch (VPN off / router-side)"
    pass=$((pass + 1))
fi

# --- Opt-in lifecycle round trip (--lifecycle <peer>) ---------------------
# Parks and resumes the peer's job through the CLI. Run-state only: the
# registry, plist, and hosts mapping are never touched, which is exactly
# what the round trip verifies — the same local port comes back.
if [ -n "$LIFECYCLE_PEER" ]; then
    echo ""
    echo "Lifecycle round trip for '$LIFECYCLE_PEER' via $TAILROUTE_BIN (park → resume; nothing added or removed)"

    # L1. stop parks the tunnel
    if "$TAILROUTE_BIN" tunnel stop "$LIFECYCLE_PEER" >/dev/null 2>&1; then
        ok "L1/6 tunnel stop $LIFECYCLE_PEER"
    else
        bad "L1/6 tunnel stop $LIFECYCLE_PEER failed"
    fi

    # L2. status reports the park as intent, not degradation (exit 0)
    st_out="$("$TAILROUTE_BIN" tunnel status "$LIFECYCLE_PEER" --skip-remote-check 2>&1)"; st_rc=$?
    if [ "$st_rc" -eq 0 ] && printf '%s' "$st_out" | grep -q "stopped (by request)"; then
        ok "L2/6 status reports 'stopped (by request)' and exits 0"
    else
        bad "L2/6 status rc=$st_rc — $(printf '%s' "$st_out" | grep -m1 'Job:' || echo 'no Job line')"
    fi

    # L3. the listener is gone while parked
    if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
        bad "L3/6 127.0.0.1:$PORT still listening after stop"
    else
        ok "L3/6 no listener on 127.0.0.1:$PORT while parked"
    fi

    # L4. start resumes it
    if "$TAILROUTE_BIN" tunnel start "$LIFECYCLE_PEER" >/dev/null 2>&1; then
        ok "L4/6 tunnel start $LIFECYCLE_PEER"
    else
        bad "L4/6 tunnel start $LIFECYCLE_PEER failed"
    fi

    # L5. the SAME local port comes back (ssh needs a moment to connect)
    i=0; up=0
    while [ "$i" -lt 40 ]; do
        if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then up=1; break; fi
        sleep 0.5; i=$((i + 1))
    done
    if [ "$up" -eq 1 ]; then
        ok "L5/6 127.0.0.1:$PORT listening again on the same port"
    else
        bad "L5/6 listener did not return on 127.0.0.1:$PORT within 20s"
    fi

    # L6. the browser path passes end to end
    if "$TAILROUTE_BIN" tunnel check "$LIFECYCLE_PEER" >/dev/null 2>&1; then
        ok "L6/6 tunnel check $LIFECYCLE_PEER passes"
    else
        bad "L6/6 tunnel check $LIFECYCLE_PEER failed — run it by hand to see the layer"
    fi
fi

echo ""
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
