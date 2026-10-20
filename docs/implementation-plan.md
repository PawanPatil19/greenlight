# Implementation plan: first working prototype

- Date: 2026-10-20
- Goal: a Claude Code session can show its progress on a phone-style widget, and a permission prompt can be allowed or denied from that widget with one tap.

The widget is the product. The iOS host app stays small: pairing, settings, and the full-detail screen that high-risk approvals need.

## What "working prototype" means

1. Install the plugin, start the relay, open the phone simulator.
2. Start Claude Code. The session appears on the widget with repo, branch and current step.
3. Claude asks permission to run a command. The widget shows the exact command with **Run** / **Deny** buttons.
4. Tap **Run**: Claude Code continues without anyone touching the terminal. Tap **Deny**: Claude is told no.
5. Nobody answers: the hook gives up before its own timeout and the normal terminal prompt appears. Silence never approves.
6. **Pause all** on the widget blocks every session's next tool call until resumed.

Everything in steps 1 to 6 is tested end to end in CI with the real hook script and the real relay; only the phone is simulated. The SwiftUI app and widget are written against the same protocol and run on a real iPhone after a few Xcode steps (see `ios/README.md`).

## Parts and order of work

### 1. Protocol (`docs/protocol.md`, `relay/src/protocol.ts`)

Firm up the v1 draft. Changes from the draft:

- `options` become objects `{ id, label, style }` so buttons can say what "yes" does (`Run`, `Allow edit`) instead of a generic OK. Nothing consumes the draft yet, so this stays `v1`.
- Asks get a lifecycle: `pending → answered | expired | cancelled`.
- New endpoints: `POST /v1/asks/{id}/cancel`, `GET|PUT /v1/control` (pause all), `GET /v1/audit`, `GET /v1/stream` (server-sent events for live clients), `POST /v1/devices` (APNs registration).
- Events are agent-neutral: `start | step | waiting | stop | failed | end`. The plugin translates Claude Code hooks into these, so the relay never sees Claude Code specifics.

### 2. Relay (`relay/`)

Node 22, standard library only (ADR 0002).

- In-memory store for sessions, asks, audit log, devices and the pause flag, with an optional JSON snapshot file (`GREENLIGHT_STATE_FILE`) so a restart keeps devices and history.
- One bearer token (`GREENLIGHT_TOKEN`). If unset, the relay generates one and prints a pairing link and the simulator URL. Two tokens (agent vs phone) is a later step.
- Long-poll `GET /v1/asks/{id}?wait=25` so hooks don't hammer the relay.
- Answers are idempotent: the same option twice returns 200, a different option returns 409, a closed ask returns 410.
- Staleness: a `start`, `stop`, `failed` or `end` event cancels that session's pending asks, and the hook withdraws its own ask when Claude Code stops waiting for it. A tap on the phone can never apply to a question that was already answered in the terminal. (`step` events don't cancel, because Claude can run other tools while a prompt is open.)
- APNs sender with `node:http2` and an ES256 JWT from `node:crypto`. Enabled only when the APNs env vars are set. Sends an alert push (category `GREENLIGHT_ASK`, IDs only, never the command) when an ask opens, and a silent push on every change so the app reloads the widget.
- Serves the phone simulator at `/`.

### 3. Claude Code plugin (`plugin/`)

One Node script (`scripts/greenlight.mjs`), no dependencies, run through a small shell wrapper that exits quietly if Node or the relay is missing.

| Hook | What it does |
|---|---|
| `SessionStart` | `start` event with repo + branch title and host name |
| `UserPromptSubmit` | `step` "Working on your request" |
| `PreToolUse` | If the relay says paused, deny the call with "Paused from Greenlight". 1 s timeout, fails open |
| `PostToolUse` | `step` like "Editing auth.ts" or "Running `npm test`", throttled to one per 10 s per session |
| `PermissionRequest` | Opens an ask with the exact command / file, risk level and buttons, waits for the answer, prints the allow/deny decision. Gives up after `GREENLIGHT_ASK_TIMEOUT` (default 120 s) and prints nothing, so the terminal prompt shows |
| `Notification` (`idle_prompt`) | `waiting` "Waiting for your reply" |
| `Stop` | `stop` with the first line of Claude's last message as the summary |
| `StopFailure` | `failed` |
| `SessionEnd` | `end` |

Risk rules live in the plugin (the agent never sets its own risk): destructive or outward-facing commands (`rm -rf`, `sudo`, `git push`, `npm publish`, deploys, `curl | sh`, ...) are **high**, other shell commands and MCP tools are **medium**, edits and fetches are **low**. Users can add their own high-risk pattern with `GREENLIGHT_HIGH_RISK`.

### 4. Phone simulator (`relay/public/phone.html`)

A single page served by the relay that looks and behaves like the widget: "N need you" header, rows sorted by urgency with state icon + colour, the pending question with its buttons, staleness ("updated 12 s ago"), a Pause all switch and the audit log. It follows the same risk rules as the real widget: high-risk asks need a confirmation step. Live via `/v1/stream`.

A `simulate-session` script drives the real hook script through a fake Claude Code session so the whole loop can be watched without Claude Code.

### 5. iOS (`ios/`)

- `GreenlightKit` Swift package: protocol models and relay client. Unit tests run in CI on Linux (`swift test` in a Swift container), so the models are checked against the protocol.
- `project.yml` for XcodeGen, so the Xcode project is generated instead of hand-edited.
- Widget extension: medium and small Home Screen widgets, Lock Screen count. Allow / Deny are `Button(intent:)` App Intents (iOS 17+). Medium-risk intents require the phone to be unlocked; high-risk asks show "Open to review" and deep-link into the app, which asks for Face ID.
- Host app: pairing (paste or tap the `greenlight://pair` link), the review screen, push registration, actionable notifications with Allow / Deny, and reloading widget timelines on silent pushes.

The app and widget targets need Xcode, a signing team and an App Group, so they are not built in CI.

## Not in this prototype

Live Activities, QR pairing, separate agent and phone tokens, "approve + remember" rules, the `ask_user` MCP tool for open questions, Apple Watch, hosted deployment. They are next, roughly in that order.

## How it ships

Two PRs from the thread's working branch, each reviewed by Claude and squash-merged when CI is green (per the project's standing rule):

1. `feat: working prototype of relay, plugin and phone simulator` (parts 1 to 4, with this plan).
2. `feat(ios): widget, host app and GreenlightKit` (part 5).

## Review of this plan

Checked against `docs/design.md` and the Claude Code hook schema in the installed CLI (2.1.x):

- **PermissionRequest output shape.** Confirmed: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, or `"deny"` with a `message`. Printing nothing leaves the normal prompt in place, which is what makes the timeout fallback safe.
- **Answered in the terminal while the phone still shows the ask.** Claude Code stops the hook, and the hook withdraws the ask on its way out. As backups, the session's next `stop`/`end` event cancels it and the relay expires it at its deadline.
- **Parallel tool calls.** Claude can run read-only tools while a permission prompt is open, so their step reports must not cancel the open question. Found while reviewing the first draft of the staleness rule, which cancelled on any event.
- **Hook timeouts.** Claude Code kills a hook at its configured `timeout`. The plugin sets `timeout: 600` on `PermissionRequest` and stops waiting at `GREENLIGHT_ASK_TIMEOUT` (capped below that), so it always exits on its own and the terminal prompt is never lost.
- **Latency on every tool call.** `PreToolUse` and `PostToolUse` run for every tool. Both do nothing without a relay configured, use short timeouts, and fail open. Step reports are throttled.
- **Secrets in pushes.** Push payloads carry only ask and session IDs plus the risk level; the command text is fetched by the app over the authenticated API.
- **Cloud sessions.** Claude Code in cloud sandboxes refuses command-type `PermissionRequest` hooks, so phone approvals are for local terminal sessions. That matches the design's focus. The other hooks still report status.
- **Risk from the agent.** The plugin computes risk from the tool and input, not from anything Claude says, per the design's "don't let the agent decide its own risk level".
- **Change made after review:** added the third button, **Terminal**, which hands the prompt back to the terminal at once, for when you're at your desk and don't want to wait out the timeout.
