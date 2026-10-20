#!/usr/bin/env bash
# Send one session event to the Greenlight relay.
# Usage: report.sh <event>   (hook input JSON arrives on stdin)
#
# Never blocks or fails the Claude Code session: if the relay is not
# configured or unreachable, it exits 0 quietly.
set -u

event="${1:-unknown}"
relay="${GREENLIGHT_RELAY_URL:-}"
input="$(cat)"

[ -z "$relay" ] && exit 0
command -v curl >/dev/null 2>&1 || exit 0

payload=$(printf '{"event":"%s","agent":"claude-code","hook":%s}' "$event" "${input:-null}")

curl --silent --show-error --max-time 3 \
  -H "content-type: application/json" \
  ${GREENLIGHT_TOKEN:+-H "authorization: Bearer $GREENLIGHT_TOKEN"} \
  -d "$payload" \
  "$relay/v1/events" >/dev/null 2>&1 || true

exit 0
