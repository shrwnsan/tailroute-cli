#!/usr/bin/env bash
# Integration test for tailroute-proxy (requires TS_AUTHKEY and a reachable peer)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROXY_BIN="$PROJECT_ROOT/proxy/build/tailroute-proxy"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:1055}"
PEER_HOST="${TAILROUTE_PROXY_PEER:-}"
PEER_PORT="${TAILROUTE_PROXY_PORT:-22}"
STATE_DIR="${TAILROUTE_PROXY_STATE_DIR:-$HOME/.tailroute/proxy-state}"
LOG_FILE="${TAILROUTE_PROXY_LOG:-/tmp/tailroute-proxy-test.log}"

if [[ ! -x "$PROXY_BIN" ]]; then
    echo "ERROR: tailroute-proxy not built. Run: cd proxy && ./build.sh" >&2
    exit 1
fi

if [[ -z "${TS_AUTHKEY:-}" ]]; then
    echo "ERROR: TS_AUTHKEY is required for this test." >&2
    echo "Set TS_AUTHKEY to a short-lived auth key and re-run." >&2
    exit 1
fi

if [[ -z "$PEER_HOST" ]]; then
    echo "ERROR: TAILROUTE_PROXY_PEER is required (peer hostname or 100.x.x.x)." >&2
    echo "Example: TAILROUTE_PROXY_PEER=nanoclaw.ts.net" >&2
    exit 1
fi

SOCKS_HOST="${SOCKS_ADDR%:*}"
SOCKS_PORT="${SOCKS_ADDR##*:}"

cleanup() {
    if [[ -n "${proxy_pid:-}" ]]; then
        kill -TERM "$proxy_pid" >/dev/null 2>&1 || true
        wait "$proxy_pid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "Starting tailroute-proxy..."
"$PROXY_BIN" --socks-addr "$SOCKS_ADDR" --auth-key "$TS_AUTHKEY" --state-dir "$STATE_DIR" --ephemeral=true >"$LOG_FILE" 2>&1 &
proxy_pid=$!

echo "Waiting for SOCKS5 proxy on $SOCKS_ADDR..."
ready="false"
for _ in $(seq 1 30); do
    if nc -z "$SOCKS_HOST" "$SOCKS_PORT" >/dev/null 2>&1; then
        ready="true"
        break
    fi
    sleep 1
done

if [[ "$ready" != "true" ]]; then
    echo "ERROR: SOCKS5 proxy did not start. Logs:" >&2
    tail -n 50 "$LOG_FILE" >&2 || true
    exit 1
fi

echo "Testing SOCKS5 connectivity to ${PEER_HOST}:${PEER_PORT}..."
if nc -w 5 -X 5 -x "$SOCKS_ADDR" "$PEER_HOST" "$PEER_PORT"; then
    echo "SUCCESS: proxy connection established"
else
    echo "ERROR: proxy connection failed. Logs:" >&2
    tail -n 50 "$LOG_FILE" >&2 || true
    exit 1
fi
