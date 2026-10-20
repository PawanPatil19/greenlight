import type { AddressInfo } from "node:net";
import { createRelay, type RelayOptions } from "../src/server.js";
import type { Store } from "../src/store.js";

export interface TestRelay {
  base: string;
  store: Store;
  call: (
    method: string,
    path: string,
    body?: unknown,
    token?: string,
  ) => Promise<{ status: number; body: any }>;
}

export async function withRelay(
  fn: (relay: TestRelay) => Promise<void>,
  options: RelayOptions = {},
): Promise<void> {
  const { server, store } = createRelay(options);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;
  const call: TestRelay["call"] = async (method, path, body, token = options.token) => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (token) headers.authorization = `Bearer ${token}`;
    const res = await fetch(base + path, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : undefined };
  };
  try {
    await fn({ base, store, call });
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

export const askBody = (sessionId = "s1", extra: Record<string, unknown> = {}) => ({
  sessionId,
  question: "Run a shell command?",
  detail: "npm publish",
  options: [
    { id: "allow", label: "Run", style: "primary" },
    { id: "deny", label: "Deny", style: "destructive" },
  ],
  risk: "high",
  timeoutSec: 60,
  ...extra,
});
