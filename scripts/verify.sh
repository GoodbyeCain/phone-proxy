#!/usr/bin/env bash
# Proves that Mac traffic for a given host exits through an attached iPhone.
# Usage: PORT=1088 TARGET=example.com ./scripts/verify.sh
set -uo pipefail

PORT="${PORT:-1088}"
TARGET="${TARGET:-baidu.com}"
PROXY_HTTP="http://127.0.0.1:${PORT}"
PROXY_SOCKS="socks5h://127.0.0.1:${PORT}"

probe() {
    local label="$1"
    shift
    echo "== ${label}"
    curl "$@" -sS -o /dev/null -w '   code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' --max-time 30 "https://${TARGET}"
}

echo "== direct egress IP (Mac)"
curl -sS --max-time 15 https://myip.ipip.net || echo "   (failed)"
echo

probe "${TARGET} via phone HTTP CONNECT" -x "${PROXY_HTTP}"
probe "${TARGET} via phone SOCKS5h" -x "${PROXY_SOCKS}"

echo "== egress IP via phone (HTTP CONNECT)"
curl -x "${PROXY_HTTP}" -sS --max-time 25 https://myip.ipip.net || echo "   (failed)"
echo
