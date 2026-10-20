# Relay

Small TypeScript server between agents and the iPhone app. It implements [`docs/protocol.md`](../docs/protocol.md).

```sh
npm ci
npm run dev     # http://localhost:8787/healthz
npm run check   # typecheck + format check + tests (what CI runs)
npm run format  # fix formatting
```

Current state: health check and protocol types only. Endpoints from the protocol doc land in follow-up PRs.
