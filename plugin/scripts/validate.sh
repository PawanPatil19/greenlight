#!/usr/bin/env bash
# Checks the plugin is well formed. Run from anywhere; CI runs this.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in .claude-plugin/plugin.json hooks/hooks.json; do
  node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" || { echo "invalid JSON: $f"; exit 1; }
  echo "ok  $f"
done

for f in scripts/*.sh; do
  bash -n "$f" || { echo "syntax error: $f"; exit 1; }
  [ -x "$f" ] || { echo "not executable: $f"; exit 1; }
  echo "ok  $f"
done

# Without a relay configured the hook must exit 0 and print nothing.
out=$(echo '{}' | env -u GREENLIGHT_RELAY_URL scripts/report.sh start)
[ -z "$out" ] || { echo "report.sh printed output without a relay"; exit 1; }
echo "ok  report.sh is silent without a relay"
