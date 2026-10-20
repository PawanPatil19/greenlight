# Greenlight

See what your Claude Code sessions are doing from your iPhone, and approve their permission prompts with one tap.

Greenlight has three parts:

| Part | Folder | What it does |
|---|---|---|
| Claude Code plugin | [`plugin/`](plugin/) | Hooks that report session status and forward permission prompts to the relay. |
| Relay server | [`relay/`](relay/) | Small TypeScript server that stores session state, holds pending decisions and pushes to the phone. |
| iOS app | [`ios/`](ios/) | App, Home/Lock Screen widgets, Live Activities and actionable notifications. |

```
Claude Code session ──hooks──▶ relay ──APNs──▶ iPhone (widget, Live Activity, notification)
        ▲                                         │
        └──────────── allow / deny ◀──────────────┘
```

The scope for now is Claude Code sessions only. The relay protocol is kept agent-neutral so other agents can report in later. See [`docs/design.md`](docs/design.md) for the full design and [`docs/protocol.md`](docs/protocol.md) for the wire format.

## Getting started

Requirements: Node 22 (see `.nvmrc`). The iOS app needs Xcode 16+ on a Mac.

```sh
cd relay
npm ci
npm run check   # typecheck, format check, tests
npm run dev     # starts the relay on http://localhost:8787
```

To try the plugin locally, see [`plugin/README.md`](plugin/README.md).

## Contributing

All changes go through pull requests to `main`. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the branch, commit and review rules.
