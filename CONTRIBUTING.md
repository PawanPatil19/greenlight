# Contributing

## The flow

1. **Start from an issue.** Every change links to an issue (bug, feature or chore). Small fixes can skip this.
2. **Branch from `main`.** Name it `<type>/<short-description>`, for example `feat/relay-ask-endpoint` or `fix/plugin-timeout`.
3. **Commit with Conventional Commits.** `feat(relay): add /v1/ask endpoint`, `fix(plugin): fall back to terminal on timeout`. Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`. Scopes: `relay`, `plugin`, `ios`, `docs`, `repo`.
4. **Open a pull request early.** Use a draft PR while the work is in progress. Fill in the PR template.
5. **CI must be green.** The `CI` workflow runs the checks for every part the PR touches.
6. **Review.** The code owner reviews every PR before merging. While this is a one-person repo, GitHub can't count an approval on your own PRs (PRs Claude opens are authored under your account), so review is required by habit, not by a setting. Raise the required approvals to 1 once a second person joins.
7. **Squash and merge.** The PR title becomes the commit message on `main`, so it must follow Conventional Commits too. The branch is deleted after merge.

`main` is always releasable. Nobody pushes to it directly.

## Repository settings

These are set once in GitHub (Settings → Rules → Rulesets, or Settings → Branches) for `main`:

- Require a pull request before merging (0 required approvals for now, see step 6 above).
- Require the `required` status check (from the CI workflow) to pass, and the branch to be up to date.
- Require conversation resolution before merging.
- Require linear history.
- Block force pushes and deletions.

Under Settings → General → Pull Requests: allow **squash merging only**, default the commit message to "Pull request title", and turn on "Automatically delete head branches".

## Layout

```
plugin/   Claude Code plugin (hooks + scripts)
relay/    Relay server (TypeScript, Node 22)
ios/      iOS app, widgets and Live Activities (Swift, SwiftUI)
docs/     Design doc, protocol spec, architecture decisions (docs/adr/)
.github/  CI workflows, PR and issue templates, CODEOWNERS
```

## Per-part checks

| Part | Command | Run in CI when |
|---|---|---|
| relay | `cd relay && npm run check` | `relay/**` changes |
| plugin | `plugin/scripts/validate.sh` | `plugin/**` changes |
| ios | `xcodebuild test` (once the Xcode project exists) | `ios/**` changes |

## Decisions

Significant choices (a new dependency, a protocol change, hosting) get a short Architecture Decision Record in `docs/adr/`. Copy the format of `0001-monorepo.md`, number it next, and include it in the PR that makes the change.

## Protocol changes

`docs/protocol.md` is the contract between the plugin, relay and app. Any change to it must be backward compatible within a version (`/v1/...`), or bump the version.

## Secrets

Never commit secrets, APNs keys or device tokens. Use `.env` files locally (they are git-ignored) and GitHub Actions secrets in CI.
