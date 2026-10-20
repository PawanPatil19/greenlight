import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { parseAsk, parseEvent, ValidationError } from "./protocol.js";
import { Store } from "./store.js";

export interface RelayOptions {
  /** Bearer token required on /v1 routes. Undefined disables auth (tests and local demos only). */
  token?: string;
  store?: Store;
  /** Longest a long-poll may hold a request open. */
  maxWaitSec?: number;
}

export interface Relay {
  server: Server;
  store: Store;
}

const MAX_BODY = 64 * 1024;
const SSE_HEARTBEAT_MS = 20_000;

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

function loadPhonePage(): string {
  try {
    // dist/src/server.js -> relay/public/phone.html
    return readFileSync(new URL("../../public/phone.html", import.meta.url), "utf8");
  } catch {
    return "<!doctype html><title>Greenlight</title><p>phone.html not found</p>";
  }
}

export function createRelay(options: RelayOptions = {}): Relay {
  const store = options.store ?? new Store();
  const maxWaitSec = options.maxWaitSec ?? 30;
  const expected = options.token ? Buffer.from(options.token) : undefined;
  const phonePage = loadPhonePage();
  const streams = new Set<ServerResponse>();

  store.on("change", () => {
    if (streams.size === 0) return;
    const data = `event: snapshot\ndata: ${JSON.stringify(store.snapshot())}\n\n`;
    for (const res of streams) res.write(data);
  });

  function authorized(req: IncomingMessage): boolean {
    if (!expected) return true;
    const header = req.headers.authorization ?? "";
    const given = Buffer.from(header.startsWith("Bearer ") ? header.slice(7) : "");
    return given.length === expected.length && timingSafeEqual(given, expected);
  }

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://relay");
    const path = url.pathname;
    const method = req.method ?? "GET";

    if (method === "GET" && path === "/healthz") return send(res, 200, { ok: true });
    if (method === "GET" && (path === "/" || path === "/phone")) {
      res.writeHead(200, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
      });
      res.end(phonePage);
      return;
    }

    if (!path.startsWith("/v1/")) throw new HttpError(404, "not_found");
    if (!authorized(req)) throw new HttpError(401, "unauthorized");

    // ---- Agent routes ----
    if (method === "POST" && path === "/v1/events") {
      const session = store.recordEvent(parseEvent(await readJson(req)));
      return send(res, 200, { session: session ?? null, paused: store.isPaused() });
    }

    if (method === "POST" && path === "/v1/asks") {
      return send(res, 201, store.openAsk(parseAsk(await readJson(req))));
    }

    const askMatch = /^\/v1\/asks\/([\w-]+)(\/answer|\/cancel)?$/.exec(path);
    if (askMatch) {
      const id = askMatch[1]!;
      const action = askMatch[2];

      if (method === "GET" && !action) {
        const wait = Math.min(
          maxWaitSec,
          Math.max(0, Number(url.searchParams.get("wait") ?? 0) || 0),
        );
        const abort = new AbortController();
        res.on("close", () => abort.abort());
        const ask = await store.waitForAsk(id, wait * 1000, abort.signal);
        if (!ask) throw new HttpError(404, "not_found", "no such ask");
        if (res.writableEnded || res.destroyed) return;
        return send(res, 200, ask);
      }

      if (method === "POST" && action === "/answer") {
        const body = await readJson(req);
        const option = typeof body.option === "string" ? body.option : "";
        const by = typeof body.device === "string" ? body.device.slice(0, 100) : undefined;
        const result = store.answer(id, option, by);
        switch (result.kind) {
          case "ok":
            return send(res, 200, result.ask);
          case "not_found":
            throw new HttpError(404, "not_found", "no such ask");
          case "invalid_option":
            throw new HttpError(400, "invalid_option", "option is not one of the ask's options");
          case "conflict":
            return send(res, 409, {
              error: "conflict",
              message: "already answered differently",
              ask: result.ask,
            });
          case "closed":
            return send(res, 410, {
              error: "closed",
              message: `ask is ${result.ask.status}`,
              ask: result.ask,
            });
        }
      }

      if (method === "POST" && action === "/cancel") {
        const body = await readJson(req);
        const reason =
          typeof body.reason === "string" ? body.reason.slice(0, 200) : "cancelled by agent";
        const ask = store.cancel(id, reason, body.waitingLocally === true);
        if (!ask) throw new HttpError(404, "not_found", "no such ask");
        return send(res, 200, ask);
      }
    }

    // ---- Phone routes ----
    if (method === "GET" && path === "/v1/sessions") return send(res, 200, store.snapshot());

    if (method === "GET" && path === "/v1/control")
      return send(res, 200, { paused: store.isPaused() });
    if (method === "PUT" && path === "/v1/control") {
      const body = await readJson(req);
      if (typeof body.paused !== "boolean")
        throw new HttpError(400, "invalid", "paused must be a boolean");
      store.setPaused(body.paused);
      return send(res, 200, { paused: store.isPaused() });
    }

    if (method === "GET" && path === "/v1/audit") {
      const limit = Math.min(500, Math.max(1, Number(url.searchParams.get("limit") ?? 100) || 100));
      return send(res, 200, { entries: store.getAudit(limit) });
    }

    if (method === "POST" && path === "/v1/devices") {
      const body = await readJson(req);
      if (typeof body.token !== "string" || !/^[0-9a-fA-F]{32,200}$/.test(body.token)) {
        throw new HttpError(400, "invalid", "token must be a hex APNs device token");
      }
      const env = body.env === "production" ? "production" : "sandbox";
      const name = typeof body.name === "string" ? body.name.slice(0, 100) : undefined;
      const device = store.addDevice({
        token: body.token.toLowerCase(),
        env,
        ...(name ? { name } : {}),
      });
      return send(res, 201, { env: device.env, addedAt: device.addedAt });
    }

    if (method === "GET" && path === "/v1/stream") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
        connection: "keep-alive",
      });
      res.write(`event: snapshot\ndata: ${JSON.stringify(store.snapshot())}\n\n`);
      streams.add(res);
      const heartbeat = setInterval(() => res.write(": ping\n\n"), SSE_HEARTBEAT_MS);
      res.on("close", () => {
        clearInterval(heartbeat);
        streams.delete(res);
      });
      return;
    }

    throw new HttpError(404, "not_found");
  }

  const server = createServer((req, res) => {
    handle(req, res).catch((err: unknown) => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      if (err instanceof HttpError)
        return send(res, err.status, { error: err.code, message: err.message });
      if (err instanceof ValidationError)
        return send(res, 400, { error: "invalid", message: err.message });
      console.error("relay error:", err);
      send(res, 500, { error: "internal" });
    });
  });

  server.on("close", () => {
    for (const res of streams) res.end();
    store.shutdown();
  });

  return { server, store };
}

function send(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new HttpError(413, "too_large");
    chunks.push(chunk as Buffer);
  }
  if (size === 0) return {};
  try {
    const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new HttpError(400, "invalid", "body must be a JSON object");
    }
    return parsed as Record<string, unknown>;
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(400, "invalid_json");
  }
}
