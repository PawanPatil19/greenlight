#!/usr/bin/env node
// Drives the real Greenlight hook through a pretend Claude Code session, so you can
// watch the widget (phone simulator) without running Claude Code.
// Usage: GREENLIGHT_RELAY_URL=http://localhost:8787 node plugin/scripts/simulate-session.mjs
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

const run = join(dirname(fileURLToPath(import.meta.url)), "run.sh");
const sessionId = process.env.SIM_SESSION_ID ?? `sim-${randomUUID().slice(0, 8)}`;
const cwd = process.cwd();
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

if (!process.env.GREENLIGHT_RELAY_URL) {
  console.error("Set GREENLIGHT_RELAY_URL first, e.g. http://localhost:8787");
  process.exit(1);
}

function hook(name, input) {
  return new Promise((resolve) => {
    const child = spawn(run, [name], { stdio: ["pipe", "pipe", "inherit"], env: process.env });
    let out = "";
    child.stdout.on("data", (c) => (out += c));
    child.on("close", () => resolve(out.trim()));
    child.stdin.end(JSON.stringify({ session_id: sessionId, cwd, hook_event_name: name, ...input }));
  });
}

function decision(out) {
  if (!out) return "no answer → Claude Code would show the terminal prompt";
  const d = JSON.parse(out).hookSpecificOutput.decision;
  return d.behavior === "allow" ? "ALLOWED from phone → Claude Code runs it" : `DENIED from phone: ${d.message}`;
}

async function tool(name, input) {
  const pre = await hook("PreToolUse", { tool_name: name, tool_input: input });
  if (pre) {
    console.log(`  ${name}: blocked, sessions are paused`);
    return false;
  }
  await hook("PostToolUse", { tool_name: name, tool_input: input, tool_response: {} });
  console.log(`  ${name} ${input.command ?? input.file_path ?? ""}`);
  return true;
}

async function ask(command) {
  console.log(`\nClaude wants to run: ${command}\n  → open the phone simulator and answer (or wait for the timeout)`);
  const result = decision(await hook("PermissionRequest", { tool_name: "Bash", tool_input: { command } }));
  console.log(`  ${result}`);
  return result.startsWith("ALLOWED");
}

console.log(`Simulated session ${sessionId} in ${cwd}`);
await hook("SessionStart", { source: "startup" });
await hook("UserPromptSubmit", { prompt: "Fix the flaky login test and ship it" });
await pause(1500);
await tool("Read", { file_path: join(cwd, "src/auth.ts") });
await pause(1500);
process.env.GREENLIGHT_STEP_INTERVAL = "0";
await tool("Edit", { file_path: join(cwd, "src/auth.ts") });
await pause(1000);
if (await ask("npm test -- auth")) await tool("Bash", { command: "npm test -- auth" });
await pause(1000);
if (await ask("git push origin fix/flaky-login")) await tool("Bash", { command: "git push origin fix/flaky-login" });
await hook("Stop", { stop_hook_active: false, last_assistant_message: "Fixed the flaky login test and pushed the branch." });
console.log("\nSession done. It stays on the widget as Done until it ends.");
