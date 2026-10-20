import { test } from "node:test";
import assert from "node:assert/strict";
import { askBody, withRelay } from "./helpers.js";

test("GET /healthz returns ok without a token", async () => {
  await withRelay(
    async ({ call }) => {
      const res = await call("GET", "/healthz", undefined, "");
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { ok: true });
    },
    { token: "secret" },
  );
});

test("the phone simulator page is served at /", async () => {
  await withRelay(async ({ base }) => {
    const res = await fetch(base + "/");
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /text\/html/);
    assert.match(await res.text(), /Greenlight/);
  });
});

test("/v1 routes need the bearer token", async () => {
  await withRelay(
    async ({ call }) => {
      assert.equal((await call("GET", "/v1/sessions", undefined, "")).status, 401);
      assert.equal((await call("GET", "/v1/sessions", undefined, "wrong")).status, 401);
      assert.equal((await call("GET", "/v1/sessions")).status, 200);
    },
    { token: "secret" },
  );
});

test("unknown routes return 404 and bad bodies return 400", async () => {
  await withRelay(async ({ call, base }) => {
    assert.equal((await call("GET", "/nope")).status, 404);
    assert.equal((await call("GET", "/v1/nope")).status, 404);
    assert.equal((await call("POST", "/v1/events", { event: "start" })).status, 400);
    const res = await fetch(base + "/v1/events", { method: "POST", body: "{not json" });
    assert.equal(res.status, 400);
  });
});

test("full ask flow: open, long-poll, answer, idempotent retry, conflict", async () => {
  await withRelay(async ({ call }) => {
    await call("POST", "/v1/events", {
      sessionId: "s1",
      agent: "claude-code",
      event: "start",
      title: "greenlight · main",
    });
    const opened = await call("POST", "/v1/asks", askBody());
    assert.equal(opened.status, 201);
    const id = opened.body.id as string;

    const sessions = await call("GET", "/v1/sessions");
    assert.equal(sessions.body.needsYou, 1);
    assert.equal(sessions.body.sessions[0].ask.detail, "npm publish");

    const poll = call("GET", `/v1/asks/${id}?wait=5`);
    await new Promise((r) => setTimeout(r, 50));
    const answered = await call("POST", `/v1/asks/${id}/answer`, {
      option: "allow",
      device: "test",
    });
    assert.equal(answered.status, 200);
    const polled = await poll;
    assert.equal(polled.body.status, "answered");
    assert.equal(polled.body.answer, "allow");

    assert.equal((await call("POST", `/v1/asks/${id}/answer`, { option: "allow" })).status, 200);
    assert.equal((await call("POST", `/v1/asks/${id}/answer`, { option: "deny" })).status, 409);
    assert.equal((await call("POST", `/v1/asks/${id}/answer`, { option: "bogus" })).status, 400);
    assert.equal((await call("POST", `/v1/asks/missing/answer`, { option: "allow" })).status, 404);

    const audit = await call("GET", "/v1/audit");
    assert.equal(audit.body.entries[0].outcome, "Run");
  });
});

test("a cancelled ask cannot be answered", async () => {
  await withRelay(async ({ call }) => {
    const { body } = await call("POST", "/v1/asks", askBody());
    const cancelled = await call("POST", `/v1/asks/${body.id}/cancel`, {
      reason: "answered in terminal",
    });
    assert.equal(cancelled.body.status, "cancelled");
    const res = await call("POST", `/v1/asks/${body.id}/answer`, { option: "allow" });
    assert.equal(res.status, 410);
  });
});

test("long-poll returns the pending ask after the wait", async () => {
  await withRelay(
    async ({ call }) => {
      const { body } = await call("POST", "/v1/asks", askBody());
      const started = Date.now();
      const res = await call("GET", `/v1/asks/${body.id}?wait=10`);
      assert.equal(res.body.status, "pending");
      assert.ok(Date.now() - started >= 900, "held the request open");
    },
    { maxWaitSec: 1 },
  );
});

test("pause control round-trips and is reported to agents", async () => {
  await withRelay(async ({ call }) => {
    assert.deepEqual((await call("GET", "/v1/control")).body, { paused: false });
    assert.equal((await call("PUT", "/v1/control", { paused: "yes" })).status, 400);
    assert.deepEqual((await call("PUT", "/v1/control", { paused: true })).body, { paused: true });
    const ev = await call("POST", "/v1/events", { sessionId: "s", event: "step", step: "x" });
    assert.equal(ev.body.paused, true);
  });
});

test("device registration validates the token", async () => {
  await withRelay(async ({ call, store }) => {
    assert.equal((await call("POST", "/v1/devices", { token: "not-hex" })).status, 400);
    const res = await call("POST", "/v1/devices", {
      token: "AB".repeat(32),
      env: "production",
      name: "iPhone",
    });
    assert.equal(res.status, 201);
    assert.equal(store.listDevices()[0]?.token, "ab".repeat(32));
  });
});

test("the stream sends a snapshot now and on every change", async () => {
  await withRelay(async ({ base, call }) => {
    const abort = new AbortController();
    const res = await fetch(base + "/v1/stream", { signal: abort.signal });
    assert.match(res.headers.get("content-type") ?? "", /text\/event-stream/);
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let text = "";
    const readUntil = async (n: number) => {
      while ((text.match(/event: snapshot/g) ?? []).length < n) {
        const { value, done } = await reader.read();
        if (done) break;
        text += decoder.decode(value);
      }
    };
    await readUntil(1);
    await call("POST", "/v1/events", { sessionId: "s1", event: "start", title: "live" });
    await readUntil(2);
    abort.abort();
    assert.match(text, /"title":"live"/);
  });
});
