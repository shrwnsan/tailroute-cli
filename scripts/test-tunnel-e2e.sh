#!/bin/bash
# test-tunnel-e2e.sh — End-to-end check of the live browser tunnel path
#
# Exercises the exact path a browser takes for one tunnel:
#   hosts override → 127.0.0.1 → ssh forward listener → TLS (SNI + chain)
#   → HTTPS request (curl validates the certificate like a browser would).
#
# Read-only: does not add/remove tunnels or modify any state.
# Transport vs backend health are reported separately — an HTTP 502 with a
# valid TLS chain means the peer's Serve backend is down, not the tunnel.
#
# Usage: scripts/test-tunnel-e2e.sh [hostname] [local-port]
#        (defaults below match the dev-machine prototype)
# Exit: 0 all pass · 1 any failure

set -u

HOSTNAME_ARG="${1:-oci-prime.tailea9a52.ts.net}"
PORT="${2:-8443}"

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

echo ""
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
