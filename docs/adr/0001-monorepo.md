# 1. One repository for plugin, relay and iOS app

- Status: accepted
- Date: 2026-10-20

## Context

Greenlight has three parts (Claude Code plugin, relay server, iOS app) that share one protocol. Early on the protocol will change often.

## Decision

Keep all three in one repository, each in its own top-level folder, with CI jobs that only run for the folders a PR touches. `docs/protocol.md` is the shared contract.

## Consequences

- A protocol change and the code on both sides land in one PR.
- CI uses path filters so an iOS change does not run relay tests, and the reverse.
- If a part later needs its own release cadence, it can be split out.
