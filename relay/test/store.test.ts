import { test } from "node:test";
import assert from "node:assert/strict";
import { Store } from "../src/store.js";
import { askBody } from "./helpers.js";
import { parseAsk } from "../src/protocol.js";

test("an ask puts its session in needs_you and an answer puts it back to running", () => {
  const store = new Store();
  store.recordEvent({
    sessionId: "s1",
    agent: "claude-code",
    event: "start",
    title: "greenlight · main",
  });
  const ask = store.openAsk(parseAsk(askBody()));
  let snap = store.snapshot();
  assert.equal(snap.needsYou, 1);
  assert.equal(snap.sessions[0]?.state, "needs_you");
  assert.equal(snap.sessions[0]?.ask?.id, ask.id);

  const result = store.answer(ask.id, "allow", "test-phone");
  assert.equal(result.kind, "ok");
  snap = store.snapshot();
  assert.equal(snap.needsYou, 0);
  assert.equal(snap.sessions[0]?.state, "running");
  assert.equal(snap.sessions[0]?.step, "Run from phone");
  assert.equal(snap.sessions[0]?.ask, undefined);
  assert.equal(store.getAudit()[0]?.outcome, "Run");
  assert.equal(store.getAudit()[0]?.by, "test-phone");
  store.shutdown();
});

test("answers are idempotent, conflicting answers are refused", () => {
  const store = new Store();
  const ask = store.openAsk(parseAsk(askBody()));
  assert.equal(store.answer(ask.id, "allow").kind, "ok");
  const again = store.answer(ask.id, "allow");
  assert.equal(again.kind, "ok");
  assert.equal(again.kind === "ok" && again.changed, false);
  assert.equal(store.answer(ask.id, "deny").kind, "conflict");
  assert.equal(store.answer(ask.id, "maybe").kind, "invalid_option");
  assert.equal(store.answer("nope", "allow").kind, "not_found");
  assert.equal(store.getAudit().length, 1, "a retry must not log twice");
  store.shutdown();
});

test("a step event does not hide a pending ask, a stop event cancels it", () => {
  const store = new Store();
  const ask = store.openAsk(parseAsk(askBody()));
  store.recordEvent({ sessionId: "s1", agent: "claude-code", event: "step", step: "Reading a.ts" });
  assert.equal(store.snapshot().sessions[0]?.state, "needs_you");
  store.recordEvent({ sessionId: "s1", agent: "claude-code", event: "stop", summary: "All done" });
  assert.equal(store.getAsk(ask.id)?.status, "cancelled");
  assert.equal(store.answer(ask.id, "allow").kind, "closed");
  const s = store.snapshot().sessions[0];
  assert.equal(s?.state, "done");
  assert.equal(s?.summary, "All done");
  store.shutdown();
});

test("an ask expires after its timeout and the session shows it is waiting in the terminal", async () => {
  const store = new Store();
  const ask = store.openAsk({ ...parseAsk(askBody()), timeoutSec: 0.05 });
  const closed = await store.waitForAsk(ask.id, 2000);
  assert.equal(closed?.status, "expired");
  assert.equal(store.snapshot().sessions[0]?.step, "Waiting in the terminal");
  assert.equal(store.snapshot().sessions[0]?.state, "needs_you");
  store.shutdown();
});

test("waitForAsk wakes as soon as the ask is answered", async () => {
  const store = new Store();
  const ask = store.openAsk(parseAsk(askBody()));
  const started = Date.now();
  setTimeout(() => store.answer(ask.id, "deny"), 30);
  const result = await store.waitForAsk(ask.id, 5000);
  assert.equal(result?.answer, "deny");
  assert.ok(Date.now() - started < 1000);
  store.shutdown();
});

test("pause shows running sessions as paused and is logged", () => {
  const store = new Store();
  store.recordEvent({ sessionId: "s1", agent: "claude-code", event: "start" });
  store.setPaused(true);
  assert.equal(store.snapshot().sessions[0]?.state, "paused");
  assert.equal(store.snapshot().paused, true);
  assert.equal(store.getAudit()[0]?.outcome, "paused");
  store.setPaused(false);
  assert.equal(store.snapshot().sessions[0]?.state, "running");
});

test("end removes the session; state survives a save and load", () => {
  const store = new Store();
  store.recordEvent({
    sessionId: "keep",
    agent: "claude-code",
    event: "start",
    title: "repo · main",
  });
  store.recordEvent({ sessionId: "gone", agent: "claude-code", event: "start" });
  store.recordEvent({ sessionId: "gone", agent: "claude-code", event: "end" });
  store.addDevice({ token: "ab".repeat(32), env: "sandbox" });
  store.setPaused(true);

  const copy = new Store();
  copy.load(JSON.parse(JSON.stringify(store.toData())));
  assert.deepEqual(
    copy.snapshot().sessions.map((s) => s.id),
    ["keep"],
  );
  assert.equal(copy.isPaused(), true);
  assert.equal(copy.listDevices().length, 1);
});
