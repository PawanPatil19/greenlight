# 3. Phone approvals through a blocking PermissionRequest hook with terminal fallback

- Status: accepted
- Date: 2026-10-20

## Context

Claude Code runs a `PermissionRequest` hook when it needs permission for a tool. The hook can answer `allow` or `deny`, or print nothing and leave the normal prompt in place. We want the phone to answer, without ever approving something by accident.

## Decision

The hook opens an ask on the relay and long-polls for the answer. It prints a decision only when the phone answered **allow** or **deny**. On a timeout (`GREENLIGHT_ASK_TIMEOUT`, default 120 s), a relay error, the phone's **Terminal** button, or being stopped by Claude Code, it prints nothing, withdraws the ask, and the terminal prompt takes over.

Risk is computed in the plugin from the tool name and input, never from the model's words. The relay stores it; the phone enforces it.

The phone and the plugin share one bearer token for now. The relay writes it to `~/.config/greenlight/token`, where the plugin also reads it, so local setup needs no copying.

## Consequences

- Silence, crashes and outages all fall back to the terminal. Nothing is approved by default.
- While the hook waits, someone at the terminal waits too, up to the timeout. The **Terminal** button and a short default timeout keep that cheap.
- Claude Code in cloud sandboxes refuses command-type `PermissionRequest` hooks, so phone approvals work for local sessions; status reporting works everywhere.
- A shared token means anyone with the plugin's token could answer asks. Separate agent and phone tokens come with QR pairing.
