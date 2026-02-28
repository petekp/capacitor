# Terminal Activation Manual Testing (Runtime Snapshot)

- Canonical path: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
- UX contract: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`

## Preconditions

1. Build current binaries:
   - `cargo build -p capacitor-core --release`
   - `cargo build -p hud-hook --release`
2. Launch app via `scripts/dev/restart-app.sh`.
3. Ensure at least two real projects are visible in the project list.

## Core Scenarios

1. Reuse existing terminal context:
   - Click project with an already-running terminal/tmux context.
   - Expected: existing context is focused, no new window spawned.
2. No existing context fallback:
   - Click project with no matching running context.
   - Expected: one controlled fallback launch path, no duplicate launches.
3. Rapid clicks latest-intent-wins:
   - Click two projects rapidly (A then B).
   - Expected: final activation targets B only.
4. Project details navigation + activation:
   - Open details view and trigger activation from there.
   - Expected: same routing semantics as project card activation.

## Evidence to Capture

1. AX smoke logs from `artifacts/manual-testing/non-demo-ax-smoke-*.log`.
2. Runtime diagnostics and snapshot context from `~/.capacitor/runtime/`.
3. Any failed scenario with:
   - exact reproduction steps
   - observed vs expected behavior
   - relevant log excerpt

## Fast Regression Command

```bash
bash scripts/ci/non-demo-ax-smoke.sh
```
