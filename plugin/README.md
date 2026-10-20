# Claude Code plugin

Hooks that show a Claude Code session on the Greenlight widget and let you answer its permission prompts from your phone.

| Hook | What it does |
|---|---|
| `SessionStart` | Adds the session (title: repo · branch) |
| `UserPromptSubmit` | Step: "Working on your request" |
| `PreToolUse` | If **Pause all** is on, blocks the tool call |
| `PostToolUse` | Step: "Editing src/auth.ts", "Running \`npm test\`" (at most one per 10 s) |
| `PermissionRequest` | Sends the exact command or file to the phone and waits for **Run / Deny / Terminal** |
| `Notification` | "Waiting for your reply" when Claude is idle |
| `Stop` / `StopFailure` | Done with a one-line summary / Failed |
| `SessionEnd` | Removes the session |

## Try it locally

```sh
cd relay && npm run dev                      # in one terminal
export GREENLIGHT_RELAY_URL=http://localhost:8787
claude --plugin-dir ./plugin                 # in another
```

The relay writes its token to `~/.config/greenlight/token` and the plugin reads it from there, so on the same machine there is nothing else to set. Without `GREENLIGHT_RELAY_URL` every hook does nothing, so the plugin is safe to leave installed.

No Claude Code handy? `node plugin/scripts/simulate-session.mjs` drives the same hook through a pretend session.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `GREENLIGHT_RELAY_URL` | unset (plugin off) | Relay address |
| `GREENLIGHT_TOKEN` | read from `~/.config/greenlight/token` | Relay token, for a relay on another machine |
| `GREENLIGHT_ASK_TIMEOUT` | `120` | Seconds to wait for the phone before showing the terminal prompt (max 570) |
| `GREENLIGHT_HIGH_RISK` | unset | Extra regex for commands or paths that count as high risk |
| `GREENLIGHT_STEP_INTERVAL` | `10` | Minimum seconds between step updates |
| `GREENLIGHT_DEBUG` | unset | Print hook errors to stderr |

## Safety rules

- The hook prints an allow/deny decision only when you tapped one on the phone. A timeout, an error, the relay being down or the **Terminal** button all print nothing, which leaves Claude Code's own prompt in place.
- Your existing permission settings still apply: anything already allowed never reaches the phone.
- Risk is decided here, from the tool and its input: destructive or outward-facing commands (`rm -rf`, `sudo`, `git push`, `npm publish`, deploys, `curl | sh`, …) and edits to `.env` / keys are **high** and need the full review screen on the phone; other shell commands and MCP tools are **medium**; edits and fetches are **low**.
- Phone approvals work for local sessions. Claude Code in cloud sandboxes doesn't run command hooks for permission prompts, so there the plugin only reports status.

## Check

```sh
plugin/scripts/validate.sh
```
