import { test } from "node:test";
import assert from "node:assert/strict";
import { byUrgency, parseAsk, parseEvent, ValidationError, type Session } from "../src/protocol.js";

const session = (id: string, state: Session["state"], updatedAt: string): Session => ({
  id,
  agent: "claude-code",
  title: id,
  state,
  startedAt: updatedAt,
  updatedAt,
});

test("sessions that need the user sort first, then newest", () => {
  const sorted = [
    session("done", "done", "2026-10-20T03:00:00Z"),
    session("running-old", "running", "2026-10-20T01:00:00Z"),
    session("needs", "needs_you", "2026-10-20T00:00:00Z"),
    session("failed", "failed", "2026-10-20T00:00:00Z"),
    session("running-new", "running", "2026-10-20T02:00:00Z"),
  ].sort(byUrgency);
  assert.deepEqual(
    sorted.map((s) => s.id),
    ["needs", "failed", "running-new", "running-old", "done"],
  );
});

test("parseEvent accepts a minimal event and rejects unknown kinds", () => {
  assert.deepEqual(parseEvent({ sessionId: "a", event: "start" }), {
    sessionId: "a",
    agent: "unknown",
    event: "start",
  });
  assert.throws(() => parseEvent({ sessionId: "a", event: "explode" }), ValidationError);
  assert.throws(() => parseEvent({ event: "start" }), /sessionId is required/);
  assert.throws(() => parseEvent([]), ValidationError);
});

test("parseAsk clamps the timeout and trims long detail instead of failing", () => {
  const ask = parseAsk({
    sessionId: "a",
    question: "Run?",
    detail: "x".repeat(10_000),
    options: [
      { id: "allow", label: "Run" },
      { id: "deny", label: "Deny" },
    ],
    timeoutSec: 999_999,
  });
  assert.equal(ask.timeoutSec, 3600);
  assert.equal(ask.risk, "medium");
  assert.equal(ask.detail.length, 4000);
  assert.ok(ask.detail.endsWith("…"));
});

test("parseAsk rejects bad options", () => {
  const base = { sessionId: "a", question: "Run?" };
  assert.throws(
    () => parseAsk({ ...base, options: [{ id: "allow", label: "Run" }] }),
    /options must be/,
  );
  assert.throws(
    () =>
      parseAsk({
        ...base,
        options: [
          { id: "a", label: "A" },
          { id: "a", label: "B" },
        ],
      }),
    /unique/,
  );
  assert.throws(() => parseAsk({ ...base, options: ["allow", "deny"] }), /each option/);
  assert.throws(
    () =>
      parseAsk({
        ...base,
        risk: "extreme",
        options: [
          { id: "a", label: "A" },
          { id: "b", label: "B" },
        ],
      }),
    /risk/,
  );
});
