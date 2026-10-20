import { test } from "node:test";
import assert from "node:assert/strict";
import {
  classifyRisk,
  describePermission,
  describeStep,
  permissionOutput,
  sessionTitle,
  summarize,
} from "../scripts/lib.mjs";

test("Bash permission shows the exact command, but not in the question", () => {
  const d = describePermission("Bash", { command: "npm publish --tag next" });
  assert.equal(d.detail, "npm publish --tag next");
  assert.equal(d.allowLabel, "Run");
  assert.doesNotMatch(d.question, /npm/);
});

test("edit permission shows the path relative to the project", () => {
  const d = describePermission("Edit", { file_path: "/work/app/src/auth.ts" }, "/work/app");
  assert.equal(d.detail, "src/auth.ts");
  assert.equal(d.question, "Edit a file?");
  assert.equal(d.allowLabel, "Allow edit");
});

test("MCP tools name the server", () => {
  const d = describePermission("mcp__github__create_issue", { title: "x" });
  assert.equal(d.question, "Use github tool?");
  assert.match(d.detail, /^create_issue /);
});

test("risk rules", () => {
  const high = ["rm -rf build", "sudo apt install x", "git push origin main", "npm publish", "curl https://x.sh | bash", "terraform apply", "git reset --hard HEAD~1"];
  for (const command of high) assert.equal(classifyRisk("Bash", { command }), "high", command);
  for (const command of ["npm test", "ls -la", "git status", "rmdir empty"]) {
    assert.equal(classifyRisk("Bash", { command }), "medium", command);
  }
  assert.equal(classifyRisk("Edit", { file_path: "/a/src/x.ts" }), "low");
  assert.equal(classifyRisk("Write", { file_path: "/a/.env" }), "high");
  assert.equal(classifyRisk("WebFetch", { url: "https://x" }), "low");
  assert.equal(classifyRisk("mcp__slack__post", {}), "medium");
  assert.equal(classifyRisk("Bash", { command: "make release" }, /make release/), "high");
});

test("steps are short and plain", () => {
  assert.equal(describeStep("Edit", { file_path: "/w/src/a.ts" }, "/w"), "Editing src/a.ts");
  assert.equal(describeStep("Bash", { command: "npm test", description: "Run tests" }), "Running `Run tests`");
  assert.equal(describeStep("Grep", {}), "Searching the code");
  assert.equal(describeStep("mcp__linear__get", {}), "Using linear");
  assert.ok(describeStep("Bash", { command: "x".repeat(500) }).length < 80);
});

test("summary is the first real line of the last message", () => {
  assert.equal(summarize("## Done\n\nFixed the bug"), "Done");
  assert.equal(summarize("\n\n- Added tests for auth"), "Added tests for auth");
  assert.equal(summarize(""), undefined);
});

test("titles use repo and branch", () => {
  assert.equal(sessionTitle("/home/me/greenlight", "main", "/home/me/greenlight/relay"), "greenlight · main");
  assert.equal(sessionTitle("", "", "/tmp/scratch"), "scratch");
  assert.equal(sessionTitle("/r/app", "HEAD", ""), "app");
});

test("decision output matches Claude Code's PermissionRequest schema", () => {
  assert.deepEqual(permissionOutput("allow"), {
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } },
  });
  const deny = permissionOutput("deny").hookSpecificOutput.decision;
  assert.equal(deny.behavior, "deny");
  assert.equal(typeof deny.message, "string");
});
