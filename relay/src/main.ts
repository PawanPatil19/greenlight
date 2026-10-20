import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { networkInterfaces, homedir } from "node:os";
import { dirname, join } from "node:path";
import { createRelay } from "./server.js";
import { Store } from "./store.js";
import { ApnsSender, apnsConfigFromEnv, attachPushes } from "./apns.js";

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? "0.0.0.0";
const configDir = process.env.GREENLIGHT_CONFIG_DIR ?? join(homedir(), ".config", "greenlight");

// The token is shared by the plugin (which reads the same file) and the phone (via the pairing link).
function loadToken(): string {
  if (process.env.GREENLIGHT_TOKEN) return process.env.GREENLIGHT_TOKEN;
  const file = join(configDir, "token");
  if (existsSync(file)) return readFileSync(file, "utf8").trim();
  mkdirSync(configDir, { recursive: true });
  const token = randomBytes(24).toString("base64url");
  writeFileSync(file, token + "\n", { mode: 0o600 });
  chmodSync(file, 0o600);
  return token;
}

function lanAddress(): string | undefined {
  for (const list of Object.values(networkInterfaces())) {
    for (const a of list ?? []) if (a.family === "IPv4" && !a.internal) return a.address;
  }
  return undefined;
}

const token = loadToken();
const store = new Store();

const stateFile = process.env.GREENLIGHT_STATE_FILE;
if (stateFile) {
  if (existsSync(stateFile)) store.load(JSON.parse(readFileSync(stateFile, "utf8")));
  let timer: NodeJS.Timeout | undefined;
  store.on("persist", () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      mkdirSync(dirname(stateFile), { recursive: true });
      writeFileSync(stateFile, JSON.stringify(store.toData()), { mode: 0o600 });
    }, 500);
  });
}

const apns = apnsConfigFromEnv(process.env, (p) => readFileSync(p, "utf8"));
if (apns) attachPushes(store, new ApnsSender(apns));

const { server } = createRelay({ token, store });
server.listen(port, host, () => {
  const publicUrl =
    process.env.GREENLIGHT_PUBLIC_URL ?? `http://${lanAddress() ?? "localhost"}:${port}`;
  const pair = `greenlight://pair?relay=${encodeURIComponent(publicUrl)}&token=${encodeURIComponent(token)}`;
  console.log(`greenlight relay listening on http://${host}:${port}`);
  console.log(`  phone simulator: http://localhost:${port}/#token=${token}`);
  console.log(`  pair your iPhone: ${pair}`);
  console.log(`  pushes: ${apns ? `APNs on (${apns.topic})` : "off (set APNS_* to enable)"}`);
  console.log(`  plugin: export GREENLIGHT_RELAY_URL=http://localhost:${port}`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
