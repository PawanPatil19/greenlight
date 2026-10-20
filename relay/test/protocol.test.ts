import { test } from "node:test";
import assert from "node:assert/strict";
import { byUrgency, type Session } from "../src/protocol.js";

const session = (id: string, state: Session["state"], updatedAt: string): Session => ({
  id,
  agent: "claude-code",
  title: id,
  state,
  updatedAt,
});

test("sessions that need the user sort first, then newest", () => {
  const sorted = [
    session("done", "done", "2026-10-20T03:00:00Z"),
    session("running-old", "running", "2026-10-20T01:00:00Z"),
    session("needs", "needs_you", "2026-10-20T00:00:00Z"),
    session("running-new", "running", "2026-10-20T02:00:00Z"),
  ].sort(byUrgency);
  assert.deepEqual(
    sorted.map((s) => s.id),
    ["needs", "running-new", "running-old", "done"],
  );
});
