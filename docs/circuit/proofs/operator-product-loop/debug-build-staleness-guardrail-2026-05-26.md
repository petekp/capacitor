# Debug Build Staleness Guardrail - 2026-05-26

## Problem

Manual verification could still drift onto the wrong Capacitor build in two ways:

1. A non-Debug Capacitor process could be running somewhere other than `/Applications/Capacitor.app`, such as `~/Applications/Capacitor.app`, the repo release bundle, or a direct Swift build.
2. The repo Debug app could be the frontmost app but still be stale because Swift or Rust source files changed after the Debug bundle artifacts were built.

## Change

- `scripts/dev/check-terminal-activation-state.sh` now reports and rejects any non-Debug Capacitor process, not just `/Applications/Capacitor.app`.
- `scripts/dev/check-terminal-activation-state.sh` now rejects stale Debug builds when Swift app sources, Rust core sources, or runtime-service sources are newer than the corresponding bundled artifact.
- `scripts/dev/restart-app.sh` now stops and rejects non-Debug Capacitor processes after LaunchServices opens the Debug bundle.
- `AGENTS.md` and `docs/circuit/terminal-activation-state-machine.md` now state that manual testing must stop when the guard reports a non-Debug or stale Debug build.

## Verification

```bash
bats tests/dev-scripts/check-terminal-activation-state.bats tests/dev-scripts/restart-app.bats tests/dev-scripts/restart-alpha-stable.bats
bash -n scripts/dev/check-terminal-activation-state.sh scripts/dev/restart-app.sh scripts/dev/restart-alpha-stable.sh
git diff --check
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
```

Observed:

- Dev-script Bats passed: 23 tests.
- Shell syntax checks passed.
- `git diff --check` passed.
- Live preflight passed with front app path `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.
- Live preflight reported one Debug process and no non-Debug Capacitor processes.

## Expected Behavior

Before manual UI testing, run:

```bash
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
```

If the wrong Capacitor build is open, the guard fails. If the Debug build is stale after source edits, the guard fails. In either case, restart through:

```bash
./scripts/dev/restart-alpha-stable.sh
```
