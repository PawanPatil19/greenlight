// Pure helpers for the Greenlight hooks: no I/O, so they are easy to test.

const DEFAULT_HIGH_RISK = [
  /\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)/, // rm -rf, rm -r, rm -f
  /\bsudo\b/,
  /\bgit\s+push\b/,
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\s+-[a-zA-Z]*f/,
  /\b(npm|pnpm|yarn)\s+publish\b/,
  /\bcargo\s+publish\b/,
  /\bdeploy\b/i,
  /\bterraform\s+(apply|destroy)\b/,
  /\bkubectl\s+(apply|delete|scale|rollout)\b/,
  /\bdrop\s+(table|database)\b/i,
  /\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b/,
  /\bchmod\s+-R\b/,
  /\bmkfs\b|\bdd\s+if=/,
  /\bgh\s+(pr\s+merge|release\s+create|repo\s+delete)\b/,
];

const EDIT_TOOLS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);
const READ_TOOLS = new Set(["Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch"]);

export function truncate(text, max) {
  const s = String(text ?? "")
    .replace(/\s+/g, " ")
    .trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function shortPath(path, cwd) {
  if (!path) return "a file";
  const p = String(path);
  const root = String(cwd ?? "").replace(/\/+$/, "");
  if (root && p.startsWith(root + "/")) return p.slice(root.length + 1);
  return p;
}

/**
 * What the phone shows for a permission prompt. `question` may appear in push
 * notifications, so it never contains the command or file contents; `detail`
 * is the exact command or path and is only fetched over the authenticated API.
 */
export function describePermission(toolName, input = {}, cwd = "") {
  if (toolName === "Bash") {
    return { question: "Run a shell command?", detail: String(input.command ?? ""), allowLabel: "Run" };
  }
  if (EDIT_TOOLS.has(toolName)) {
    const path = input.file_path ?? input.notebook_path;
    const verb = toolName === "Write" ? "Write" : "Edit";
    return { question: `${verb} a file?`, detail: shortPath(path, cwd), allowLabel: `Allow ${verb.toLowerCase()}` };
  }
  if (toolName === "WebFetch") {
    return { question: "Fetch a web page?", detail: String(input.url ?? ""), allowLabel: "Fetch" };
  }
  if (toolName.startsWith("mcp__")) {
    const [, server, tool] = toolName.split("__");
    return {
      question: `Use ${server ?? "an MCP"} tool?`,
      detail: `${tool ?? toolName} ${JSON.stringify(input)}`,
      allowLabel: "Allow",
    };
  }
  return { question: `Use ${toolName}?`, detail: JSON.stringify(input), allowLabel: "Allow" };
}

/** Risk comes from the tool and its input, never from anything the model says. */
export function classifyRisk(toolName, input = {}, extraHighRisk) {
  const patterns = extraHighRisk ? [...DEFAULT_HIGH_RISK, extraHighRisk] : DEFAULT_HIGH_RISK;
  if (toolName === "Bash") {
    const command = String(input.command ?? "");
    return patterns.some((p) => p.test(command)) ? "high" : "medium";
  }
  if (EDIT_TOOLS.has(toolName)) {
    const path = String(input.file_path ?? input.notebook_path ?? "");
    if (extraHighRisk?.test(path) || /(^|\/)\.(env|git\/|ssh\/)|\.pem$|id_rsa/.test(path)) return "high";
    return "low";
  }
  if (READ_TOOLS.has(toolName)) return "low";
  return "medium";
}

/** One line for the widget about what the session just did. */
export function describeStep(toolName, input = {}, cwd = "") {
  switch (toolName) {
    case "Bash":
      return `Running \`${truncate(input.description || input.command, 60)}\``;
    case "Edit":
    case "MultiEdit":
    case "NotebookEdit":
      return `Editing ${truncate(shortPath(input.file_path ?? input.notebook_path, cwd), 60)}`;
    case "Write":
      return `Writing ${truncate(shortPath(input.file_path, cwd), 60)}`;
    case "Read":
      return `Reading ${truncate(shortPath(input.file_path, cwd), 60)}`;
    case "Grep":
    case "Glob":
      return "Searching the code";
    case "WebFetch":
    case "WebSearch":
      return "Looking something up";
    case "Task":
    case "Agent":
      return `Delegating: ${truncate(input.description, 50)}`;
    case "TodoWrite":
      return "Planning";
    default:
      return toolName.startsWith("mcp__") ? `Using ${toolName.split("__")[1]}` : `Using ${toolName}`;
  }
}

/** First meaningful line of Claude's last message, for the "Done" row. */
export function summarize(message) {
  if (!message) return undefined;
  const line = String(message)
    .split("\n")
    .map((l) => l.replace(/^[#>*\-\s]+/, "").trim())
    .find((l) => l.length > 0);
  return line ? truncate(line, 140) : undefined;
}

export function sessionTitle(repoRoot, branch, cwd) {
  const name = (repoRoot || cwd || "session").split("/").filter(Boolean).pop() ?? "session";
  return branch && branch !== "HEAD" ? `${name} · ${branch}` : name;
}

export function permissionOutput(behavior) {
  const decision =
    behavior === "allow"
      ? { behavior: "allow" }
      : { behavior: "deny", message: "Denied from Greenlight on your phone." };
  return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision } };
}

export function pausedOutput() {
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        "Greenlight: all sessions are paused from the phone. Stop and wait; the user will resume when ready.",
    },
  };
}
