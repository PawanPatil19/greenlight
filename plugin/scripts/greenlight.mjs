#!/usr/bin/env node
// Greenlight hook for Claude Code. Usage: greenlight.mjs <HookEventName>, hook input JSON on stdin.
//
// Rules this script never breaks:
// - It never fails or blocks the session: any error exits 0 with no output.
// - It prints a decision only when the user answered on the phone. Printing
//   nothing leaves Claude Code's normal behaviour (the terminal prompt) in place,
//   so silence never approves anything.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, hostname, tmpdir } from "node:os";
import { join } from "node:path";
import {
  classifyRisk,
  describePermission,
  describeStep,
  pausedOutput,
  permissionOutput,
  sessionTitle,
  summarize,
  truncate,
} from "./lib.mjs";

const env = process.env;
const RELAY = (env.GREENLIGHT_RELAY_URL ?? "").replace(/\/+$/, "");
// Claude Code kills the hook at its configured timeout (600 s in hooks.json); stay well below it.
const ASK_TIMEOUT_SEC = Math.min(570, Math.max(2, Number(env.GREENLIGHT_ASK_TIMEOUT) || 120));
const STEP_INTERVAL_MS = (Number(env.GREENLIGHT_STEP_INTERVAL) || 10) * 1000;
const AGENT = "claude-code";

function token() {
  if (env.GREENLIGHT_TOKEN) return env.GREENLIGHT_TOKEN;
  try {
    const dir = env.GREENLIGHT_CONFIG_DIR ?? join(homedir(), ".config", "greenlight");
    return readFileSync(join(dir, "token"), "utf8").trim();
  } catch {
    return "";
  }
}

async function api(method, path, body, timeoutMs = 3000) {
  const headers = { "content-type": "application/json" };
  const t = token();
  if (t) headers.authorization = `Bearer ${t}`;
  const res = await fetch(RELAY + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${json.error ?? ""}`);
  return json;
}

// ---- Per-session scratch state (throttling, cached title) ----

const stateDir = join(tmpdir(), `greenlight-${process.getuid?.() ?? "user"}`);
function statePath(sessionId) {
  return join(stateDir, `${String(sessionId).replace(/[^\w.-]/g, "_")}.json`);
}
function readState(sessionId) {
  try {
    return JSON.parse(readFileSync(statePath(sessionId), "utf8"));
  } catch {
    return {};
  }
}
function writeState(sessionId, state) {
  try {
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    writeFileSync(statePath(sessionId), JSON.stringify(state), { mode: 0o600 });
  } catch {
    // Throttling is best effort.
  }
}

function computeTitle(cwd) {
  try {
    const out = execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], {
      encoding: "utf8",
      timeout: 1500,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const [root, branch] = out.trim().split("\n");
    return sessionTitle(root, branch, cwd);
  } catch {
    return sessionTitle("", "", cwd);
  }
}

function title(input, refresh = false) {
  const state = readState(input.session_id);
  if (!refresh && state.title) return state.title;
  const t = computeTitle(input.cwd || process.cwd());
  writeState(input.session_id, { ...state, title: t });
  return t;
}

async function sendEvent(input, event, fields = {}) {
  return api("POST", "/v1/events", {
    sessionId: input.session_id,
    agent: AGENT,
    event,
    title: title(input, event === "start"),
    host: hostname(),
    ...fields,
  });
}

// ---- Hooks ----

async function onPermissionRequest(input) {
  const { question, detail, allowLabel } = describePermission(input.tool_name, input.tool_input, input.cwd);
  let extra;
  try {
    extra = env.GREENLIGHT_HIGH_RISK ? new RegExp(env.GREENLIGHT_HIGH_RISK, "i") : undefined;
  } catch {
    extra = undefined;
  }
  // Make sure the session row exists with a proper title before the question shows.
  await sendEvent(input, "step", { step: question }).catch(() => {});

  const ask = await api("POST", "/v1/asks", {
    sessionId: input.session_id,
    question,
    detail,
    risk: classifyRisk(input.tool_name, input.tool_input, extra),
    timeoutSec: ASK_TIMEOUT_SEC + 5, // the hook gives up first and cancels explicitly
    options: [
      { id: "allow", label: allowLabel, style: "primary" },
      { id: "deny", label: "Deny", style: "destructive" },
      { id: "terminal", label: "Terminal", style: "neutral" },
    ],
  });

  // If Claude Code stops waiting (the user answered in the terminal), withdraw the question.
  let finished = false;
  const giveUp = async (reason, waitingLocally) => {
    if (finished) return;
    finished = true;
    await api("POST", `/v1/asks/${ask.id}/cancel`, { reason, waitingLocally }, 1500).catch(() => {});
  };
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(signal, () => giveUp("answered in the terminal", false).finally(() => process.exit(0)));
  }

  const deadline = Date.now() + ASK_TIMEOUT_SEC * 1000;
  while (Date.now() < deadline) {
    const waitSec = Math.max(1, Math.min(25, Math.floor((deadline - Date.now()) / 1000)));
    let current;
    try {
      current = await api("GET", `/v1/asks/${ask.id}?wait=${waitSec}`, undefined, (waitSec + 10) * 1000);
    } catch {
      await new Promise((r) => setTimeout(r, 1000)); // relay blip: keep trying until the deadline
      continue;
    }
    if (current.status === "pending") continue;
    finished = true;
    if (current.status === "answered" && (current.answer === "allow" || current.answer === "deny")) {
      return permissionOutput(current.answer);
    }
    return undefined; // "terminal", expired or cancelled: hand back to the terminal prompt
  }
  await giveUp("no answer in time, back to the terminal", true);
  return undefined;
}

async function onPreToolUse() {
  const control = await api("GET", "/v1/control", undefined, 1000);
  return control.paused ? pausedOutput() : undefined;
}

async function onPostToolUse(input) {
  const state = readState(input.session_id);
  const now = Date.now();
  if (state.lastStepAt && now - state.lastStepAt < STEP_INTERVAL_MS) return;
  writeState(input.session_id, { ...state, lastStepAt: now });
  await sendEvent(input, "step", { step: describeStep(input.tool_name, input.tool_input, input.cwd) });
}

const handlers = {
  SessionStart: (input) => {
    writeState(input.session_id, {}); // fresh throttle and title
    return sendEvent(input, "start", { step: input.source === "resume" ? "Resumed" : "Started" });
  },
  UserPromptSubmit: (input) => {
    writeState(input.session_id, { ...readState(input.session_id), lastStepAt: Date.now() });
    return sendEvent(input, "step", { step: "Working on your request" });
  },
  PreToolUse: onPreToolUse,
  PostToolUse: onPostToolUse,
  PermissionRequest: onPermissionRequest,
  Notification: (input) =>
    input.notification_type === "idle_prompt"
      ? sendEvent(input, "waiting", { step: "Waiting for your reply" })
      : undefined,
  Stop: (input) => sendEvent(input, "stop", { summary: summarize(input.last_assistant_message) }),
  StopFailure: (input) =>
    sendEvent(input, "failed", { step: truncate(input.error_details || input.error || "Failed", 120) }),
  SessionEnd: (input) => sendEvent(input, "end"),
};

async function main() {
  if (!RELAY) return;
  const raw = readFileSync(0, "utf8");
  const input = raw ? JSON.parse(raw) : {};
  const hook = process.argv[2] || input.hook_event_name;
  const handler = handlers[hook];
  if (!handler || !input.session_id) return;
  const output = await handler(input);
  // Only the two decision hooks ever print, and only an object they built.
  if (output && (hook === "PermissionRequest" || hook === "PreToolUse")) {
    // Wait for the write to flush: stdout to a pipe is asynchronous on macOS.
    await new Promise((resolve) => process.stdout.write(JSON.stringify(output) + "\n", resolve));
  }
}

main()
  .catch((err) => {
    if (env.GREENLIGHT_DEBUG) process.stderr.write(`greenlight: ${err?.stack ?? err}\n`);
  })
  .finally(() => process.exit(0));
