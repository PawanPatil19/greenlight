# 2. Relay in TypeScript on Node 22 with no runtime dependencies

- Status: accepted
- Date: 2026-10-20

## Context

The relay is small: a few JSON endpoints, in-memory or small-database state, and APNs pushes. It may run self-hosted or on a serverless platform.

## Decision

Write it in TypeScript targeting Node 22, using only the standard library (`node:http`, `node:test`) to start. Tooling is `typescript` and `prettier`.

## Consequences

- Nothing to audit or upgrade at runtime; easy to move to a serverless runtime later.
- Routing is hand-written. If it grows past a handful of routes, revisit with a small framework in a new ADR.
