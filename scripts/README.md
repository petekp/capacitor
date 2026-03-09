# Scripts Index

This folder is the operational script surface for Capacitor.

Use the smallest script that matches the task. Do not add new wrappers when an
existing script already owns the workflow.

## Canonical Entry Points

- Local setup:
  `./scripts/dev/setup.sh`
- Default local relaunch:
  `./scripts/dev/restart-alpha-stable.sh`
- Explicit local relaunch:
  `./scripts/dev/restart-app.sh --channel alpha --profile stable`
- Hook binary sync:
  `./scripts/sync-hooks.sh --force`
- Fresh-install / onboarding reset:
  `./scripts/dev/reset-for-testing.sh`
- Full local verification:
  `./scripts/dev/run-tests.sh`
- Release workflow:
  `./scripts/release/release.sh`

## Directory Roles

- `scripts/dev/`:
  local developer and coding-agent workflows
- `scripts/ci/`:
  mechanical CI gates, smoke tests, and wrappers
- `scripts/release/`:
  build, notarization, packaging, and publishing
- `scripts/architecture/`:
  active architecture guardrails
- `scripts/ax/`:
  accessibility automation helpers
- `scripts/utils/`:
  narrow one-off utilities

## Lean-Surface Rule

Delete scripts that only forward to another script without adding meaning,
unless the forwarded name is the canonical human entry point.

If a script changes:

1. update its usage/help text
2. keep comments aligned with the current architecture and file layout
3. update this index if the script is a primary entry point
