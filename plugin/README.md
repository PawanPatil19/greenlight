# Claude Code plugin

Hooks that tell the relay what a Claude Code session is doing.

| Hook | Event sent |
|---|---|
| `SessionStart` | `start` |
| `Stop` | `stop` |
| `SessionEnd` | `end` |

Permission prompts (`PermissionRequest`) and throttled step updates (`PostToolUse`) come next; see [`docs/design.md`](../docs/design.md#3b-scope-decision-claude-code-sessions-only-for-now).

## Try it locally

```sh
export GREENLIGHT_RELAY_URL=http://localhost:8787
claude --plugin-dir ./plugin
```

Without `GREENLIGHT_RELAY_URL` the hooks do nothing, so the plugin is safe to leave installed.

## Check

```sh
plugin/scripts/validate.sh
```
