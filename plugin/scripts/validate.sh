#!/usr/bin/env bash
# Checks the plugin is well formed and its unit tests pass. Run from anywhere; CI runs this.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in .claude-plugin/plugin.json hooks/hooks.json; do
  node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" || { echo "invalid JSON: $f"; exit 1; }
  echo "ok  $f"
done

# Every hook command must point at a script that exists.
node -e "
const h = require('./hooks/hooks.json').hooks;
for (const [event, groups] of Object.entries(h)) for (const g of groups) for (const x of g.hooks) {
  const script = x.command.replace('\${CLAUDE_PLUGIN_ROOT}/', '').split(' ')[0];
  if (!require('fs').existsSync(script)) { console.error('missing script for ' + event + ': ' + script); process.exit(1); }
}"
echo "ok  hook commands point at real scripts"

for f in scripts/*.sh; do
  bash -n "$f" || { echo "syntax error: $f"; exit 1; }
  [ -x "$f" ] || { echo "not executable: $f"; exit 1; }
  echo "ok  $f"
done
for f in scripts/*.mjs; do
  node --check "$f" || { echo "syntax error: $f"; exit 1; }
  echo "ok  $f"
done

# Without a relay configured every hook must exit 0 and print nothing.
for hook in SessionStart PreToolUse PermissionRequest Stop; do
  out=$(echo '{"session_id":"x"}' | env -u GREENLIGHT_RELAY_URL scripts/run.sh "$hook")
  [ -z "$out" ] || { echo "run.sh $hook printed output without a relay"; exit 1; }
done
echo "ok  hooks are silent without a relay"

# With a relay that is down, hooks must still exit 0 and print nothing.
out=$(echo '{"session_id":"x","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | GREENLIGHT_RELAY_URL=http://127.0.0.1:9 scripts/run.sh PermissionRequest)
[ -z "$out" ] || { echo "PermissionRequest printed output with the relay down"; exit 1; }
echo "ok  hooks fail open when the relay is down"

node --test test/*.test.mjs
