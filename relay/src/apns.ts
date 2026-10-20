// Apple Push Notification service sender, standard library only.
// Token-based auth: an ES256 JWT signed with the .p8 key from the Apple developer account.
import { connect, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import type { Ask } from "./protocol.js";
import type { Device, Store } from "./store.js";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** PEM contents of the AuthKey_XXXX.p8 file. */
  privateKey: string;
  /** The app's bundle id. */
  topic: string;
  /** Override for tests. Defaults to Apple's servers for the device's environment. */
  origin?: string;
}

export type PushType = "alert" | "background";

const ORIGINS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

const JWT_TTL_MS = 50 * 60 * 1000; // Apple rejects tokens older than an hour.

export function apnsConfigFromEnv(
  env: NodeJS.ProcessEnv,
  readFile: (path: string) => string,
): ApnsConfig | undefined {
  const { APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_PATH, APNS_TOPIC } = env;
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_KEY_PATH || !APNS_TOPIC) return undefined;
  return {
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    privateKey: readFile(APNS_KEY_PATH),
    topic: APNS_TOPIC,
  };
}

function base64url(input: string | Buffer): string {
  return Buffer.from(input).toString("base64url");
}

export function makeJwt(keyId: string, teamId: string, key: KeyObject, nowSec: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: nowSec }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${claims}.${base64url(signature)}`;
}

/** Alert for a new decision. Carries IDs and the short question only, never the command or file. */
export function askAlertPayload(ask: Ask, sessionTitle: string): Record<string, unknown> {
  return {
    aps: {
      alert: { title: sessionTitle, body: ask.question },
      sound: "default",
      // High-risk asks get a category without an Allow action: they must be reviewed in the app.
      category: ask.risk === "high" ? "GREENLIGHT_ASK_HIGH" : "GREENLIGHT_ASK",
      "thread-id": ask.sessionId,
      "interruption-level": "time-sensitive",
      "content-available": 1,
    },
    askId: ask.id,
    sessionId: ask.sessionId,
    risk: ask.risk,
  };
}

export function refreshPayload(): Record<string, unknown> {
  return { aps: { "content-available": 1 }, kind: "refresh" };
}

export interface PushResult {
  status: number;
  reason?: string;
}

export class ApnsSender {
  private key: KeyObject;
  private jwt?: { token: string; at: number };
  private sessions = new Map<string, ClientHttp2Session>();

  constructor(
    private readonly config: ApnsConfig,
    private readonly now: () => number = Date.now,
  ) {
    this.key = createPrivateKey(config.privateKey);
  }

  private token(): string {
    const now = this.now();
    if (!this.jwt || now - this.jwt.at > JWT_TTL_MS) {
      this.jwt = {
        token: makeJwt(this.config.keyId, this.config.teamId, this.key, Math.floor(now / 1000)),
        at: now,
      };
    }
    return this.jwt.token;
  }

  private session(origin: string): ClientHttp2Session {
    const existing = this.sessions.get(origin);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = connect(origin);
    session.on("error", () => this.sessions.delete(origin));
    session.on("close", () => this.sessions.delete(origin));
    session.unref();
    this.sessions.set(origin, session);
    return session;
  }

  send(device: Device, type: PushType, payload: Record<string, unknown>): Promise<PushResult> {
    const origin = this.config.origin ?? ORIGINS[device.env];
    return new Promise((resolve, reject) => {
      const req = this.session(origin).request({
        ":method": "POST",
        ":path": `/3/device/${device.token}`,
        authorization: `bearer ${this.token()}`,
        "apns-topic": this.config.topic,
        "apns-push-type": type,
        "apns-priority": type === "alert" ? "10" : "5",
        "content-type": "application/json",
      });
      let status = 0;
      let body = "";
      req.setEncoding("utf8");
      req.on("response", (headers) => (status = Number(headers[":status"])));
      req.on("data", (chunk: string) => (body += chunk));
      req.on("end", () => {
        let reason: string | undefined;
        try {
          reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
        } catch {
          reason = body;
        }
        resolve(reason ? { status, reason } : { status });
      });
      req.on("error", reject);
      req.setTimeout(10_000, () => req.close());
      req.end(JSON.stringify(payload));
    });
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}

/**
 * Wires a sender to the store: an alert when a decision opens, and a throttled
 * silent push on other changes so the app can reload its widgets.
 */
export function attachPushes(
  store: Store,
  sender: Pick<ApnsSender, "send">,
  refreshEveryMs = 20_000,
): () => void {
  let lastRefresh = 0;
  let pending: NodeJS.Timeout | undefined;

  const deliver = async (type: PushType, payload: Record<string, unknown>) => {
    for (const device of store.listDevices()) {
      try {
        const result = await sender.send(device, type, payload);
        // 410 Unregistered or 400 BadDeviceToken: the app was removed or the token rotated.
        if (result.status === 410 || result.reason === "BadDeviceToken")
          store.removeDevice(device.token);
        else if (result.status !== 200)
          console.warn(`apns ${type} push failed: ${result.status} ${result.reason ?? ""}`);
      } catch (err) {
        console.warn(`apns ${type} push error:`, (err as Error).message);
      }
    }
  };

  const refresh = () => {
    pending = undefined;
    lastRefresh = Date.now();
    void deliver("background", refreshPayload());
  };

  const onAsk = (ask: Ask) => {
    const title =
      store.snapshot().sessions.find((s) => s.id === ask.sessionId)?.title ?? "Claude Code";
    void deliver("alert", askAlertPayload(ask, title));
    lastRefresh = Date.now(); // The alert also wakes the app (content-available).
  };

  const onChange = () => {
    if (pending) return;
    const wait = Math.max(0, lastRefresh + refreshEveryMs - Date.now());
    pending = setTimeout(refresh, wait);
    pending.unref();
  };

  store.on("ask", onAsk);
  store.on("change", onChange);
  return () => {
    store.off("ask", onAsk);
    store.off("change", onChange);
    clearTimeout(pending);
  };
}
