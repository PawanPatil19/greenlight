import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http2";
import { generateKeyPairSync, verify } from "node:crypto";
import type { AddressInfo } from "node:net";
import { ApnsSender, askAlertPayload, attachPushes, makeJwt } from "../src/apns.js";
import { Store } from "../src/store.js";
import { parseAsk } from "../src/protocol.js";
import { askBody } from "./helpers.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();

test("the JWT is ES256 with the key id and team id, and verifies", () => {
  const jwt = makeJwt("KEY123", "TEAM456", privateKey, 1_700_000_000);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h!, "base64url").toString()), {
    alg: "ES256",
    kid: "KEY123",
  });
  assert.deepEqual(JSON.parse(Buffer.from(c!, "base64url").toString()), {
    iss: "TEAM456",
    iat: 1_700_000_000,
  });
  const ok = verify(
    "sha256",
    Buffer.from(`${h}.${c}`),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    Buffer.from(s!, "base64url"),
  );
  assert.ok(ok);
});

test("the alert payload never carries the command", () => {
  const store = new Store();
  const ask = store.openAsk(parseAsk(askBody("s1", { detail: "rm -rf / --no-preserve-root" })));
  const payload = askAlertPayload(ask, "greenlight · main");
  assert.doesNotMatch(JSON.stringify(payload), /rm -rf/);
  assert.equal(payload.askId, ask.id);
  assert.equal((payload.aps as { category: string }).category, "GREENLIGHT_ASK_HIGH");
  const medium = store.openAsk(parseAsk(askBody("s2", { risk: "medium" })));
  assert.equal(
    (askAlertPayload(medium, "x").aps as { category: string }).category,
    "GREENLIGHT_ASK",
  );
  store.shutdown();
});

test("the sender posts to /3/device/<token> with APNs headers", async () => {
  const seen: Record<string, unknown>[] = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      seen.push({ ...req.headers, body });
      res.writeHead(200);
      res.end();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address() as AddressInfo;
  const sender = new ApnsSender({
    keyId: "K",
    teamId: "T",
    privateKey: pem,
    topic: "dev.greenlight.app",
    origin: `http://127.0.0.1:${port}`,
  });
  try {
    const result = await sender.send(
      { token: "ab".repeat(32), env: "sandbox", addedAt: "" },
      "alert",
      { aps: {} },
    );
    assert.equal(result.status, 200);
    const req = seen[0]!;
    assert.equal(req[":path"], `/3/device/${"ab".repeat(32)}`);
    assert.equal(req["apns-topic"], "dev.greenlight.app");
    assert.equal(req["apns-push-type"], "alert");
    assert.equal(req["apns-priority"], "10");
    assert.match(String(req.authorization), /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  } finally {
    sender.close();
    await new Promise<void>((r) => server.close(() => r()));
  }
});

test("pushes: an alert when an ask opens, and dead tokens are dropped", async () => {
  const store = new Store();
  store.addDevice({ token: "aa".repeat(32), env: "sandbox" });
  store.addDevice({ token: "bb".repeat(32), env: "sandbox" });
  const sent: { token: string; type: string }[] = [];
  const detach = attachPushes(store, {
    send: async (device, type) => {
      sent.push({ token: device.token, type });
      return device.token.startsWith("bb")
        ? { status: 410, reason: "Unregistered" }
        : { status: 200 };
    },
  });
  store.openAsk(parseAsk(askBody()));
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(
    sent.map((s) => s.type),
    ["alert", "alert"],
  );
  assert.deepEqual(
    store.listDevices().map((d) => d.token),
    ["aa".repeat(32)],
  );
  detach();
  store.shutdown();
});
