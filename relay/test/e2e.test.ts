// End to end: the real plugin hook script talking to the real relay.
// Only Claude Code (which feeds the hook its JSON) and the phone (HTTP calls) are simulated.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { withRelay, type TestRelay } from "./helpers.js";

const RUN = fileURLToPath(new URL("../../../plugin/scripts/run.sh", import.meta.url));
const REPO = fileURLToPath(new URL("../../../", import.meta.url));
const TOKEN = "e2e-token";

interface Hook {
  child: ChildProcess;
  done: Promise<{ code: number | null; stdout: string }>;
}

function runHook(
  base: string,
  hook: string,
  input: Record<string, unknown>,
  env: Record<string, string> = {},
): Hook {
  const configDir = mkdtempSync(join(tmpdir(), "greenlight-e2e-"));
  writeFileSync(join(configDir, "token"), TOKEN + "\n");
  const child = spawn(RUN, [hook], {
    env: {
      ...process.env,
      GREENLIGHT_RELAY_URL: base,
      GREENLIGHT_CONFIG_DIR: configDir,
      GREENLIGHT_TOKEN: "",
      ...env,
    },
    stdio: ["pipe", "pipe", "inherit"],
  });
  let stdout = "";
  child.stdout!.on("data", (c) => (stdout += c));
  child.stdin!.end(
    JSON.stringify({ hook_event_name: hook, cwd: REPO, transcript_path: "/dev/null", ...input }),
  );
  const done = new Promise<{ code: number | null; stdout: string }>((resolve) =>
    child.on("close", (code) => resolve({ code, stdout })),
  );
  return { child, done };
}

async function until<T>(fn: () => Promise<T | undefined>, ms = 5000): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v !== undefined) return v;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error("timed out waiting");
}

async function pendingAsk(call: TestRelay["call"], sessionId: string): Promise<any> {
  return until(async () => {
    const { body } = await call("GET", "/v1/sessions");
    return body.sessions.find((s: any) => s.id === sessionId)?.ask;
  });
}

const permission = (sessionId: string, command: string) => ({
  session_id: sessionId,
  tool_name: "Bash",
  tool_input: { command, description: "test" },
  permission_suggestions: [],
});

const opts = { token: TOKEN };
const run = Date.now().toString(36);

test("a session's lifecycle shows up on the phone", async () => {
  await withRelay(async ({ base, call }) => {
    const session = async () =>
      (await call("GET", "/v1/sessions")).body.sessions.find((s: any) => s.id === `life-${run}`);

    assert.equal(
      (await runHook(base, "SessionStart", { session_id: `life-${run}`, source: "startup" }).done)
        .stdout,
      "",
    );
    let s = await session();
    assert.equal(s.state, "running");
    assert.match(s.title, /^greenlight( · .+)?$/);
    assert.equal(s.agent, "claude-code");

    await runHook(base, "PostToolUse", {
      session_id: `life-${run}`,
      tool_name: "Edit",
      tool_input: { file_path: join(REPO, "relay/src/server.ts") },
      tool_response: {},
    }).done;
    assert.equal((await session()).step, "Editing relay/src/server.ts");

    await runHook(base, "Notification", {
      session_id: `life-${run}`,
      notification_type: "idle_prompt",
      message: "x",
    }).done;
    assert.equal((await session()).state, "needs_you");

    await runHook(base, "Stop", {
      session_id: `life-${run}`,
      stop_hook_active: false,
      last_assistant_message: "Fixed the login bug.\nMore.",
    }).done;
    s = await session();
    assert.equal(s.state, "done");
    assert.equal(s.summary, "Fixed the login bug.");

    await runHook(base, "SessionEnd", { session_id: `life-${run}`, reason: "exit" }).done;
    assert.equal(await session(), undefined);
  }, opts);
});

for (const [option, expected] of [
  ["allow", { behavior: "allow" }],
  ["deny", { behavior: "deny", message: "Denied from Greenlight on your phone." }],
] as const) {
  test(`tapping ${option} on the phone answers Claude Code's permission prompt`, async () => {
    await withRelay(async ({ base, call }) => {
      const hook = runHook(
        base,
        "PermissionRequest",
        permission("p-" + option, "git push origin main"),
      );
      const ask = await pendingAsk(call, "p-" + option);
      assert.equal(ask.detail, "git push origin main");
      assert.equal(ask.risk, "high");
      assert.deepEqual(
        ask.options.map((o: any) => o.id),
        ["allow", "deny", "terminal"],
      );

      const res = await call("POST", `/v1/asks/${ask.id}/answer`, { option, device: "e2e" });
      assert.equal(res.status, 200);
      const { code, stdout } = await hook.done;
      assert.equal(code, 0);
      assert.deepEqual(JSON.parse(stdout), {
        hookSpecificOutput: { hookEventName: "PermissionRequest", decision: expected },
      });
    }, opts);
  });
}

test("Terminal hands the prompt back: the hook prints nothing", async () => {
  await withRelay(async ({ base, call }) => {
    const hook = runHook(base, "PermissionRequest", permission("p-term", "npm test"));
    const ask = await pendingAsk(call, "p-term");
    assert.equal(ask.risk, "medium");
    await call("POST", `/v1/asks/${ask.id}/answer`, { option: "terminal" });
    assert.deepEqual(await hook.done, { code: 0, stdout: "" });
    assert.equal(
      (await call("GET", "/v1/sessions")).body.sessions[0].step,
      "Waiting in the terminal",
    );
  }, opts);
});

test("no answer in time: the hook prints nothing and withdraws the question", async () => {
  await withRelay(async ({ base, call }) => {
    const hook = runHook(base, "PermissionRequest", permission("p-slow", "npm test"), {
      GREENLIGHT_ASK_TIMEOUT: "2",
    });
    const ask = await pendingAsk(call, "p-slow");
    assert.deepEqual(await hook.done, { code: 0, stdout: "" });
    assert.equal((await call("GET", `/v1/asks/${ask.id}`)).body.status, "expired");
    const waiting = (await call("GET", "/v1/sessions")).body.sessions[0];
    assert.equal(waiting.state, "needs_you");
    assert.equal(waiting.step, "Waiting in the terminal");
    assert.equal(
      (await call("POST", `/v1/asks/${ask.id}/answer`, { option: "allow" })).status,
      410,
    );
  }, opts);
});

test("answered in the terminal: Claude Code kills the hook and the phone question goes away", async () => {
  await withRelay(async ({ base, call }) => {
    const hook = runHook(base, "PermissionRequest", permission("p-kill", "npm test"));
    const ask = await pendingAsk(call, "p-kill");
    hook.child.kill("SIGTERM");
    assert.equal((await hook.done).stdout, "");
    const after = await until(async () => {
      const { body } = await call("GET", `/v1/asks/${ask.id}`);
      return body.status === "pending" ? undefined : body;
    });
    assert.equal(after.status, "cancelled");
    const session = (await call("GET", "/v1/sessions")).body.sessions[0];
    assert.equal(session.state, "running");
    assert.equal(session.step, "Answered in the terminal");
  }, opts);
});

test("Pause all blocks the next tool call; resume lets it through", async () => {
  await withRelay(async ({ base, call }) => {
    const pre = { session_id: "p-pause", tool_name: "Bash", tool_input: { command: "ls" } };
    assert.equal((await runHook(base, "PreToolUse", pre).done).stdout, "");
    await call("PUT", "/v1/control", { paused: true });
    const blocked = JSON.parse((await runHook(base, "PreToolUse", pre).done).stdout);
    assert.equal(blocked.hookSpecificOutput.permissionDecision, "deny");
    await call("PUT", "/v1/control", { paused: false });
    assert.equal((await runHook(base, "PreToolUse", pre).done).stdout, "");
  }, opts);
});

test("a wrong token makes every hook a silent no-op", async () => {
  await withRelay(async ({ base, call }) => {
    const out = await runHook(base, "PermissionRequest", permission("p-auth", "ls"), {
      GREENLIGHT_TOKEN: "wrong",
    }).done;
    assert.deepEqual(out, { code: 0, stdout: "" });
    assert.equal((await call("GET", "/v1/sessions")).body.sessions.length, 0);
  }, opts);
});
