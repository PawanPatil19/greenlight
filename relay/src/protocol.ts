// Types and validation for the relay protocol. Keep in sync with docs/protocol.md.

export type SessionState = "running" | "needs_you" | "done" | "failed" | "paused";

export type EventKind = "start" | "step" | "waiting" | "stop" | "failed" | "end";
export const EVENT_KINDS: readonly EventKind[] = [
  "start",
  "step",
  "waiting",
  "stop",
  "failed",
  "end",
];

export type Risk = "low" | "medium" | "high";
export const RISKS: readonly Risk[] = ["low", "medium", "high"];

export type AskStatus = "pending" | "answered" | "expired" | "cancelled";

export type OptionStyle = "primary" | "destructive" | "neutral";

export interface AskOption {
  id: string;
  label: string;
  style?: OptionStyle;
}

export interface Session {
  id: string;
  agent: string;
  title: string;
  state: SessionState;
  step?: string;
  summary?: string;
  host?: string;
  startedAt: string;
  updatedAt: string;
  /** The pending ask for this session, if any. Only set in API responses. */
  ask?: Ask;
}

/** What an agent sends to open a decision. */
export interface AskInput {
  sessionId: string;
  question: string;
  detail: string;
  options: AskOption[];
  risk: Risk;
  timeoutSec: number;
}

export interface Ask extends AskInput {
  id: string;
  status: AskStatus;
  createdAt: string;
  expiresAt: string;
  answer?: string;
  answeredAt?: string;
  answeredBy?: string;
  closedReason?: string;
}

/** What an agent sends to report progress. */
export interface EventInput {
  sessionId: string;
  agent: string;
  event: EventKind;
  title?: string;
  step?: string;
  summary?: string;
  host?: string;
}

export interface AuditEntry {
  at: string;
  askId: string;
  sessionId: string;
  sessionTitle: string;
  question: string;
  detail: string;
  risk: Risk;
  outcome: string;
  by?: string;
}

export interface Snapshot {
  sessions: Session[];
  needsYou: number;
  paused: boolean;
  serverTime: string;
}

// Order used to sort sessions for the widget: what needs the user comes first.
export const URGENCY: Record<SessionState, number> = {
  needs_you: 0,
  failed: 1,
  running: 2,
  paused: 3,
  done: 4,
};

export function byUrgency(a: Session, b: Session): number {
  return URGENCY[a.state] - URGENCY[b.state] || b.updatedAt.localeCompare(a.updatedAt);
}

// ---- Validation -----------------------------------------------------------

export const LIMITS = {
  id: 200,
  title: 200,
  step: 300,
  question: 300,
  detail: 4000,
  optionLabel: 40,
  maxOptions: 4,
  minTimeoutSec: 5,
  maxTimeoutSec: 3600,
} as const;

export class ValidationError extends Error {}

type Json = Record<string, unknown>;

function isObject(v: unknown): v is Json {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function str(body: Json, key: string, max: number, required: true): string;
function str(body: Json, key: string, max: number, required: false): string | undefined;
function str(body: Json, key: string, max: number, required: boolean): string | undefined {
  const v = body[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new ValidationError(`${key} is required`);
    return undefined;
  }
  if (typeof v !== "string") throw new ValidationError(`${key} must be a string`);
  // Trim long text instead of rejecting it: a hook should never fail on a long command.
  return v.length > max ? v.slice(0, max - 1) + "…" : v;
}

export function parseEvent(body: unknown): EventInput {
  if (!isObject(body)) throw new ValidationError("body must be a JSON object");
  const event = str(body, "event", 20, true) as EventKind;
  if (!EVENT_KINDS.includes(event))
    throw new ValidationError(`event must be one of ${EVENT_KINDS.join(", ")}`);
  const input: EventInput = {
    sessionId: str(body, "sessionId", LIMITS.id, true),
    agent: str(body, "agent", 50, false) ?? "unknown",
    event,
  };
  const title = str(body, "title", LIMITS.title, false);
  const step = str(body, "step", LIMITS.step, false);
  const summary = str(body, "summary", LIMITS.step, false);
  const host = str(body, "host", 100, false);
  if (title) input.title = title;
  if (step) input.step = step;
  if (summary) input.summary = summary;
  if (host) input.host = host;
  return input;
}

export function parseAsk(body: unknown): AskInput {
  if (!isObject(body)) throw new ValidationError("body must be a JSON object");
  const risk = (str(body, "risk", 10, false) ?? "medium") as Risk;
  if (!RISKS.includes(risk)) throw new ValidationError(`risk must be one of ${RISKS.join(", ")}`);

  const rawOptions = body.options;
  if (
    !Array.isArray(rawOptions) ||
    rawOptions.length < 2 ||
    rawOptions.length > LIMITS.maxOptions
  ) {
    throw new ValidationError(`options must be an array of 2 to ${LIMITS.maxOptions} items`);
  }
  const options: AskOption[] = rawOptions.map((o) => {
    if (!isObject(o)) throw new ValidationError("each option must be an object { id, label }");
    const option: AskOption = {
      id: str(o, "id", 40, true),
      label: str(o, "label", LIMITS.optionLabel, true),
    };
    const style = str(o, "style", 20, false);
    if (style) {
      if (!["primary", "destructive", "neutral"].includes(style))
        throw new ValidationError("invalid option style");
      option.style = style as OptionStyle;
    }
    return option;
  });
  if (new Set(options.map((o) => o.id)).size !== options.length) {
    throw new ValidationError("option ids must be unique");
  }

  const timeout = body.timeoutSec ?? 120;
  if (typeof timeout !== "number" || !Number.isFinite(timeout))
    throw new ValidationError("timeoutSec must be a number");

  return {
    sessionId: str(body, "sessionId", LIMITS.id, true),
    question: str(body, "question", LIMITS.question, true),
    detail: str(body, "detail", LIMITS.detail, false) ?? "",
    options,
    risk,
    timeoutSec: Math.round(Math.min(LIMITS.maxTimeoutSec, Math.max(LIMITS.minTimeoutSec, timeout))),
  };
}
