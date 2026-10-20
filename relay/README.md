# Relay

Small TypeScript server between agents and the iPhone app. It implements [`docs/protocol.md`](../docs/protocol.md) with Node's standard library only.

```sh
npm ci
npm run dev     # http://localhost:8787 (phone simulator at /)
npm run check   # typecheck + format check + unit and end-to-end tests (what CI runs)
npm run format  # fix formatting
```

## Settings (environment variables)

| Variable                                                     | Default                                          | Meaning                                                                |
| ------------------------------------------------------------ | ------------------------------------------------ | ---------------------------------------------------------------------- |
| `PORT` / `HOST`                                              | `8787` / `0.0.0.0`                               | Where to listen. `0.0.0.0` lets your phone reach it on the same Wi-Fi  |
| `GREENLIGHT_TOKEN`                                           | generated, saved to `~/.config/greenlight/token` | Bearer token for `/v1`                                                 |
| `GREENLIGHT_PUBLIC_URL`                                      | `http://<LAN IP>:<PORT>`                         | Address put in the pairing link                                        |
| `GREENLIGHT_STATE_FILE`                                      | unset (memory only)                              | JSON file to keep sessions, audit log and devices across restarts      |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_TOPIC` | unset (no pushes)                                | APNs token auth: key id, team id, path to the `.p8` key, app bundle id |

## Layout

- `src/protocol.ts`: types and input validation
- `src/store.ts`: sessions, asks, audit log, devices, pause flag
- `src/server.ts`: HTTP routes, long-poll, server-sent events
- `src/apns.ts`: push sender (HTTP/2 + ES256 JWT)
- `public/phone.html`: the phone simulator
- `test/e2e.test.ts`: runs the real plugin hook against the real relay
