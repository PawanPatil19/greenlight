#!/usr/bin/env bash
# Entry point for every Greenlight hook. Does nothing (and never fails) unless
# GREENLIGHT_RELAY_URL is set and Node 18+ is installed.
if [ -z "${GREENLIGHT_RELAY_URL:-}" ] || ! command -v node >/dev/null 2>&1; then
  cat >/dev/null
  exit 0
fi
exec node "$(dirname "$0")/greenlight.mjs" "$@"
