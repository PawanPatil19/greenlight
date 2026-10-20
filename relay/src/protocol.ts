// Types for the relay protocol. Keep in sync with docs/protocol.md.

export type SessionState = "running" | "needs_you" | "done" | "failed" | "paused";

export interface Session {
  id: string;
  agent: string;
  title: string;
  state: SessionState;
  step?: string;
  updatedAt: string;
}

export type Risk = "low" | "medium" | "high";

export interface Ask {
  sessionId: string;
  question: string;
  detail: string;
  options: string[];
  risk: Risk;
  timeoutSec: number;
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
