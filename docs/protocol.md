# Relay protocol (v1 draft)

The contract between agents (today: the Claude Code plugin), the relay and the iPhone app. It is agent-neutral on purpose: nothing here is specific to Claude Code except the `agent` field's value.

All bodies are JSON. All endpoints are under `/v1`. Agents and the app authenticate with a bearer token issued when the phone is paired (pairing is not specified yet).

## Session

```json
{
  "id": "string, stable per agent session",
  "agent": "claude-code",
  "title": "string, e.g. repo + branch",
  "state": "running | needs_you | done | failed | paused",
  "step": "string, optional, current step in plain words",
  "updatedAt": "ISO 8601 timestamp"
}
```

## Endpoints

| Method | Path | Caller | Purpose |
|---|---|---|---|
| `GET` | `/healthz` | anyone | Liveness check. Returns `{ "ok": true }`. |
| `POST` | `/v1/events` | agent | Report a session event (`start`, `step`, `stop`, `end`). |
| `POST` | `/v1/asks` | agent | Open a decision. Returns `{ "id" }`. |
| `GET` | `/v1/asks/{id}` | agent | Long-poll for the answer until it arrives or the agent's timeout passes. |
| `POST` | `/v1/asks/{id}/answer` | app | Answer a decision with one of its options. Idempotent. |
| `GET` | `/v1/sessions` | app | List sessions, most urgent first. |

## Decision (ask)

```json
{
  "sessionId": "string",
  "question": "Run `npm publish`?",
  "detail": "the exact command or file, never a paraphrase",
  "options": ["allow", "deny"],
  "risk": "low | medium | high",
  "timeoutSec": 120
}
```

If no answer arrives before `timeoutSec`, the agent falls back to its normal local prompt. Silence never approves anything.

## Push payloads

Push payloads carry IDs and state only, never commands, file contents or secrets. The app fetches details from the relay.
