# Relay protocol (v1)

The contract between agents (today: the Claude Code plugin), the relay and the iPhone app. It is agent-neutral on purpose: nothing here is specific to Claude Code except the `agent` field's value.

All bodies are JSON. Everything under `/v1` needs `Authorization: Bearer <token>`. The token is created by the relay on first start (saved to `~/.config/greenlight/token`) or set with `GREENLIGHT_TOKEN`; the phone gets it from the pairing link `greenlight://pair?relay=<url>&token=<token>`.

## Session

```json
{
  "id": "string, stable per agent session",
  "agent": "claude-code",
  "title": "greenlight · main",
  "state": "running | needs_you | done | failed | paused",
  "step": "Editing src/auth.ts",
  "summary": "first line of the agent's final message (done/failed)",
  "host": "machine name",
  "startedAt": "ISO 8601",
  "updatedAt": "ISO 8601",
  "ask": "the pending Ask, if any (responses only)"
}
```

`paused` is shown for running sessions while Pause all is on.

## Event (agent → relay)

```json
{ "sessionId": "…", "agent": "claude-code", "event": "start | step | waiting | stop | failed | end", "title": "…", "step": "…", "summary": "…", "host": "…" }
```

| Event | Session becomes |
|---|---|
| `start` | `running` (resets summary) |
| `step` | `running`, with the new step (stays `needs_you` while an ask is pending) |
| `waiting` | `needs_you` (the agent waits for a reply that isn't a yes/no) |
| `stop` | `done` |
| `failed` | `failed` |
| `end` | removed |

`start`, `stop`, `failed` and `end` cancel the session's pending asks: the question can't still be open.

## Ask (a decision)

Agent sends:

```json
{
  "sessionId": "string",
  "question": "Run a shell command?",
  "detail": "npm publish --tag next",
  "options": [
    { "id": "allow", "label": "Run", "style": "primary" },
    { "id": "deny", "label": "Deny", "style": "destructive" },
    { "id": "terminal", "label": "Terminal", "style": "neutral" }
  ],
  "risk": "low | medium | high",
  "timeoutSec": 120
}
```

- `question` is short and may appear in push notifications, so it must not contain the command, file contents or secrets.
- `detail` is the exact command or file, never a paraphrase. It is only served over the authenticated API.
- `options`: 2 to 4. Labels say what "yes" does. The id `terminal` is reserved for "answer this at the agent's own prompt instead".
- `risk` is set by the agent-side rules, not by the model. Clients enforce it: low and medium can be answered from the widget (medium needs the phone unlocked); high needs the app's review screen and Face ID.

The relay adds `id`, `status` (`pending | answered | expired | cancelled`), `createdAt`, `expiresAt`, and when closed `answer`, `answeredAt`, `answeredBy`, `closedReason`.

If no answer arrives before `timeoutSec`, the agent falls back to its normal local prompt. Silence never approves anything.

## Endpoints

| Method | Path | Caller | Purpose |
|---|---|---|---|
| `GET` | `/healthz` | anyone | Liveness. `{ "ok": true }` |
| `GET` | `/` | anyone | Phone simulator page (calls the API with the token) |
| `POST` | `/v1/events` | agent | Report an event. Returns `{ session, paused }` |
| `POST` | `/v1/asks` | agent | Open a decision. `201` with the Ask |
| `GET` | `/v1/asks/{id}?wait=25` | agent | Long-poll: returns as soon as the ask closes, or after `wait` seconds (max 30) |
| `POST` | `/v1/asks/{id}/cancel` | agent | Withdraw a pending ask `{ "reason": "…", "waitingLocally": true }`. `waitingLocally` means the agent fell back to its own prompt (status becomes `expired`); otherwise the question was settled there (`cancelled`) |
| `POST` | `/v1/asks/{id}/answer` | app | `{ "option": "allow", "device": "Pawan's iPhone" }`. Same answer again: `200`. Different answer: `409`. Ask no longer pending: `410`. Unknown option: `400` |
| `GET` | `/v1/sessions` | app | `{ sessions, needsYou, paused, serverTime }`, most urgent first |
| `GET` | `/v1/stream` | app | Server-sent events: a `snapshot` event (same body as `/v1/sessions`) now and after every change |
| `GET` / `PUT` | `/v1/control` | both | `{ "paused": true }`. Agents block tool calls while paused |
| `GET` | `/v1/audit?limit=100` | app | `{ entries }`: who answered what, when, from which device |
| `POST` | `/v1/devices` | app | Register for APNs `{ "token": "<hex>", "env": "sandbox | production", "name": "…" }` |

Errors are `{ "error": "code", "message": "…" }`.

## Push payloads

Sent only when the relay has APNs credentials (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_TOPIC`).

- **New ask** (`alert`, category `GREENLIGHT_ASK`): title is the session title, body is the `question`. Custom keys: `askId`, `sessionId`, `risk`. Also `content-available` so the app refreshes its widget.
- **Anything else changed** (`background`, throttled to one per 20 s): `{ "aps": { "content-available": 1 }, "kind": "refresh" }`.

Payloads never carry `detail`, commands, file contents or secrets. The app fetches details from the relay.
