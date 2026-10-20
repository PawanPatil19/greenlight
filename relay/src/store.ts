import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import {
  byUrgency,
  type Ask,
  type AskInput,
  type AuditEntry,
  type EventInput,
  type Session,
  type Snapshot,
} from "./protocol.js";

export interface Device {
  token: string;
  env: "sandbox" | "production";
  name?: string;
  addedAt: string;
}

export type AnswerResult =
  | { kind: "ok"; ask: Ask; changed: boolean }
  | { kind: "not_found" }
  | { kind: "invalid_option"; ask: Ask }
  | { kind: "conflict"; ask: Ask }
  | { kind: "closed"; ask: Ask };

/** Persisted subset of the store. Pending asks are not saved: their hooks are gone after a restart. */
export interface StoreData {
  sessions: Session[];
  audit: AuditEntry[];
  devices: Device[];
  paused: boolean;
}

const AUDIT_LIMIT = 500;

/** Reserved option id: "answer this at the agent's own prompt instead". */
export const LOCAL_OPTION = "terminal";
const DONE_SESSION_TTL_MS = 12 * 60 * 60 * 1000;

// Events after which a still-pending ask can no longer be the question Claude is waiting on.
const CLOSES_ASKS = new Set(["start", "stop", "failed", "end"]);

/**
 * All relay state. Emits:
 * - "change" after anything visible to the phone changed
 * - "ask" (ask) when a new decision opens
 */
export class Store extends EventEmitter {
  private sessions = new Map<string, Session>();
  private asks = new Map<string, Ask>();
  private audit: AuditEntry[] = [];
  private devices = new Map<string, Device>();
  private paused = false;
  private timers = new Map<string, NodeJS.Timeout>();
  private waiters = new Map<string, Set<() => void>>();

  constructor(private readonly now: () => Date = () => new Date()) {
    super();
  }

  // ---- Sessions -----------------------------------------------------------

  recordEvent(input: EventInput): Session | undefined {
    const at = this.iso();
    const existing = this.sessions.get(input.sessionId);

    if (CLOSES_ASKS.has(input.event)) {
      for (const ask of this.pendingAsksFor(input.sessionId))
        this.close(ask, "cancelled", `session ${input.event}`);
    }

    if (input.event === "end") {
      this.sessions.delete(input.sessionId);
      this.changed();
      return undefined;
    }

    const session: Session = existing ?? {
      id: input.sessionId,
      agent: input.agent,
      title: input.title ?? input.sessionId,
      state: "running",
      startedAt: at,
      updatedAt: at,
    };
    if (input.title) session.title = input.title;
    if (input.host) session.host = input.host;
    session.agent = input.agent;
    session.updatedAt = at;

    switch (input.event) {
      case "start":
        session.state = "running";
        session.step = input.step ?? "Started";
        delete session.summary;
        break;
      case "step":
        // A step never hides a pending question: tools can run in parallel with a prompt.
        if (this.pendingAsksFor(session.id).length === 0) session.state = "running";
        if (input.step) session.step = input.step;
        break;
      case "waiting":
        session.state = "needs_you";
        session.step = input.step ?? "Waiting for your reply";
        break;
      case "stop":
        session.state = "done";
        session.step = "Done";
        if (input.summary) session.summary = input.summary;
        break;
      case "failed":
        session.state = "failed";
        session.step = input.step ?? "Failed";
        if (input.summary) session.summary = input.summary;
        break;
    }

    this.sessions.set(session.id, session);
    this.changed();
    return session;
  }

  // ---- Asks ---------------------------------------------------------------

  openAsk(input: AskInput): Ask {
    const now = this.now();
    const ask: Ask = {
      ...input,
      id: randomUUID(),
      status: "pending",
      createdAt: now.toISOString(),
      expiresAt: new Date(now.getTime() + input.timeoutSec * 1000).toISOString(),
    };
    this.asks.set(ask.id, ask);

    const session = this.sessions.get(input.sessionId) ?? {
      id: input.sessionId,
      agent: "unknown",
      title: input.sessionId,
      state: "running" as const,
      startedAt: ask.createdAt,
      updatedAt: ask.createdAt,
    };
    session.state = "needs_you";
    session.step = input.question;
    session.updatedAt = ask.createdAt;
    this.sessions.set(session.id, session);

    const timer = setTimeout(() => this.expire(ask.id), input.timeoutSec * 1000);
    timer.unref();
    this.timers.set(ask.id, timer);

    this.emit("ask", ask);
    this.changed();
    return ask;
  }

  getAsk(id: string): Ask | undefined {
    return this.asks.get(id);
  }

  answer(id: string, option: string, by?: string): AnswerResult {
    const ask = this.asks.get(id);
    if (!ask) return { kind: "not_found" };
    if (!ask.options.some((o) => o.id === option)) return { kind: "invalid_option", ask };
    if (ask.status === "answered") {
      // Idempotent: a retry or double tap with the same answer is fine.
      return ask.answer === option
        ? { kind: "ok", ask, changed: false }
        : { kind: "conflict", ask };
    }
    if (ask.status !== "pending") return { kind: "closed", ask };

    ask.answer = option;
    ask.answeredAt = this.iso();
    if (by) ask.answeredBy = by;
    this.close(ask, "answered", undefined);
    return { kind: "ok", ask, changed: true };
  }

  /**
   * Withdraws a pending ask. `waitingLocally` says the agent fell back to its own
   * prompt (the user still has to answer at the terminal); otherwise the question
   * was settled there.
   */
  cancel(id: string, reason: string, waitingLocally = false): Ask | undefined {
    const ask = this.asks.get(id);
    if (!ask) return undefined;
    if (ask.status === "pending") this.close(ask, waitingLocally ? "expired" : "cancelled", reason);
    return ask;
  }

  private expire(id: string): void {
    const ask = this.asks.get(id);
    if (ask?.status === "pending") this.close(ask, "expired", "no answer before the timeout");
  }

  private close(
    ask: Ask,
    status: Exclude<Ask["status"], "pending">,
    reason: string | undefined,
  ): void {
    ask.status = status;
    if (reason) ask.closedReason = reason;
    clearTimeout(this.timers.get(ask.id));
    this.timers.delete(ask.id);

    const session = this.sessions.get(ask.sessionId);
    const option = ask.options.find((o) => o.id === ask.answer);
    this.audit.unshift({
      at: this.iso(),
      askId: ask.id,
      sessionId: ask.sessionId,
      sessionTitle: session?.title ?? ask.sessionId,
      question: ask.question,
      detail: ask.detail,
      risk: ask.risk,
      outcome: status === "answered" ? (option?.label ?? ask.answer ?? "answered") : status,
      ...(ask.answeredBy ? { by: ask.answeredBy } : {}),
    });
    if (this.audit.length > AUDIT_LIMIT) this.audit.length = AUDIT_LIMIT;

    if (session && this.pendingAsksFor(session.id).length === 0 && session.state === "needs_you") {
      session.updatedAt = this.iso();
      if (status === "answered" && ask.answer !== LOCAL_OPTION) {
        session.state = "running";
        session.step = `${option?.label ?? ask.answer} from phone`;
      } else if (status === "expired" || status === "answered") {
        // Handed back to the agent's own prompt: still waiting on the user, at the terminal.
        session.step = "Waiting in the terminal";
      } else {
        session.state = "running";
        session.step = "Answered in the terminal";
      }
    }

    for (const wake of this.waiters.get(ask.id) ?? []) wake();
    this.waiters.delete(ask.id);
    // Forget closed asks after a while; the audit log keeps the record.
    setTimeout(() => this.asks.delete(ask.id), 10 * 60 * 1000).unref();
    this.changed();
  }

  /** Resolves when the ask leaves "pending" or after `ms`, whichever comes first. */
  waitForAsk(id: string, ms: number, signal?: AbortSignal): Promise<Ask | undefined> {
    const ask = this.asks.get(id);
    if (!ask || ask.status !== "pending" || ms <= 0) return Promise.resolve(ask);
    return new Promise((resolve) => {
      const set = this.waiters.get(id) ?? new Set();
      this.waiters.set(id, set);
      const done = () => {
        clearTimeout(timer);
        set.delete(done);
        signal?.removeEventListener("abort", done);
        resolve(this.asks.get(id));
      };
      const timer = setTimeout(done, ms);
      set.add(done);
      signal?.addEventListener("abort", done);
    });
  }

  private pendingAsksFor(sessionId: string): Ask[] {
    return [...this.asks.values()].filter(
      (a) => a.sessionId === sessionId && a.status === "pending",
    );
  }

  // ---- Control, audit, devices ---------------------------------------------

  isPaused(): boolean {
    return this.paused;
  }

  setPaused(paused: boolean): void {
    if (this.paused === paused) return;
    this.paused = paused;
    this.audit.unshift({
      at: this.iso(),
      askId: "",
      sessionId: "",
      sessionTitle: "All sessions",
      question: paused ? "Pause all" : "Resume all",
      detail: "",
      risk: "low",
      outcome: paused ? "paused" : "resumed",
    });
    this.changed();
  }

  getAudit(limit = 100): AuditEntry[] {
    return this.audit.slice(0, limit);
  }

  addDevice(device: Omit<Device, "addedAt">): Device {
    const saved = { ...device, addedAt: this.iso() };
    this.devices.set(device.token, saved);
    this.emit("persist");
    return saved;
  }

  removeDevice(token: string): void {
    if (this.devices.delete(token)) this.emit("persist");
  }

  listDevices(): Device[] {
    return [...this.devices.values()];
  }

  // ---- Views ---------------------------------------------------------------

  snapshot(): Snapshot {
    this.pruneOldSessions();
    const pending = [...this.asks.values()].filter((a) => a.status === "pending");
    const sessions = [...this.sessions.values()]
      .map((s) => {
        const view: Session = { ...s };
        const ask = pending.find((a) => a.sessionId === s.id);
        if (ask) view.ask = ask;
        if (this.paused && view.state === "running") view.state = "paused";
        return view;
      })
      .sort(byUrgency);
    return {
      sessions,
      needsYou: sessions.filter((s) => s.state === "needs_you").length,
      paused: this.paused,
      serverTime: this.iso(),
    };
  }

  private pruneOldSessions(): void {
    const cutoff = this.now().getTime() - DONE_SESSION_TTL_MS;
    for (const [id, s] of this.sessions) {
      if (Date.parse(s.updatedAt) < cutoff) this.sessions.delete(id);
    }
  }

  // ---- Persistence ---------------------------------------------------------

  toData(): StoreData {
    return {
      sessions: [...this.sessions.values()],
      audit: this.audit,
      devices: this.listDevices(),
      paused: this.paused,
    };
  }

  load(data: Partial<StoreData>): void {
    for (const s of data.sessions ?? []) {
      // A session that was waiting on an ask lost it in the restart.
      if (s.state === "needs_you") s.step = "Waiting in the terminal";
      this.sessions.set(s.id, s);
    }
    this.audit = (data.audit ?? []).slice(0, AUDIT_LIMIT);
    for (const d of data.devices ?? []) this.devices.set(d.token, d);
    this.paused = data.paused ?? false;
  }

  /** Stops timers so tests and shutdown don't hang. */
  shutdown(): void {
    for (const t of this.timers.values()) clearTimeout(t);
    this.timers.clear();
  }

  private changed(): void {
    this.emit("change");
    this.emit("persist");
  }

  private iso(): string {
    return this.now().toISOString();
  }
}
