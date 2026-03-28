# AX Automation Runbook

> Doc role: `task-runbook`
> Status: AX verification workflow only. For architecture, start at `.claude/docs/architecture-primer.md`.

Use this guide when you need to verify the project-card/details UI through macOS Accessibility automation.

## Default Entry Point

The canonical AX interface is:

```bash
bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details
```

Use the verifier first. It is the stable contract for agents because it:

- runs the repo-owned non-demo smoke flow
- captures timestamped artifacts
- classifies failures into deterministic reasons
- can enforce `[WindowAX]` lifecycle health
- seeds and restores the runtime projects file when the environment has no usable `~/.capacitor/projects.json`

## Which Command To Use

### Fast smoke

```bash
bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details
```

Use this for the normal “did I break project-card AX?” check.

### Full repeated verification

```bash
bash scripts/ci/ax-automation-verify.sh --runs 3 --require-log-health
```

Use this when debugging relaunch flakes or when a change touched AX window visibility, project cards, details navigation, or setup/launch flow.

### Non-blocking trust probe

```bash
bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details --allow-untrusted
```

Use this on machines where Accessibility trust may be unavailable. This should label missing trust as `skipped_untrusted` instead of failing the whole check.

### Runtime suite wrapper

```bash
bash scripts/ci/runtime-reliability.sh ci
```

This is the pre-merge operational wrapper. It already includes the AX verifier lane.

## Interface Layers

Think of the AX stack as three layers:

1. `scripts/ci/ax-automation-verify.sh`
   This is the public verification contract agents should prefer.
2. `scripts/ci/non-demo-ax-smoke.sh`
   This is the smoke-phase runner. It relaunches the debug app and drives repo-owned scenarios.
3. `scripts/ax/ax_runner.swift`
   This is the raw low-level AX runner. Use it only for scenario surgery or debugging a specific AX traversal/action issue.

## CI And Fresh-Machine Behavior

The verifier has a few CI-oriented setup behaviors on purpose:

- If the environment does not already have two distinct pinned projects, it creates a temporary projects file and installs it at the runtime path the app actually reads: `~/.capacitor/projects.json`. Both projects and ideas files are protected by EXIT traps for cleanup on abnormal exit.
- The verifier seeds `~/.capacitor/ideas.json` with a test idea for the primary project, enabling the full Phase 3 method runner scenario. Without seeded ideas, Phase 3 falls back to a details-only scenario and reports `coverage_mode: "degraded"`.
- In CI mode, it can provision a temporary/stub `claude` CLI so setup validation does not fall back to onboarding just because the GitHub runner lacks the real CLI.
- `scripts/ci/runtime-reliability.sh` launches the AX lane with `CAPACITOR_SKIP_SETUP_VALIDATION=1` so the debug app opens directly to the project surface instead of `WelcomeView`. The CI wrapper uses `--skip-details`, which means only the cards phase runs. Phases 2 and 3 only run when `--skip-details` is NOT set.

That last point matters architecturally: the AX lane is verifying project-surface automation, not first-run setup.

## Artifacts

Verifier artifacts live under:

```text
artifacts/ax-automation-verification/<timestamp>/
```

Important files:

- `summary.txt`
- `summary.json`
- `runs.tsv`
- `run-001/`, `run-002/`, ...
- per-run smoke logs and debug-log slices

## Failure Interpretation

Use the verifier’s `first_failure_context` as the first diagnosis anchor.

### `reason=timeout` for app startup

Interpretation:
- the debug app did not launch as `com.capacitor.app.debug`
- or AX runner could not see it in time

Start with:
- `scripts/dev/restart-app.sh`
- bundle creation/signing path
- whether the app launched as a bundle vs. plain `swift run`

### `reason=timeout` for `ax.project-card.*`

Interpretation:
- the app launched, but the expected card is not in the AX tree
- common causes are onboarding/setup UI, wrong project state, or cards not rendered in the current layout

Start with:
- whether `setupComplete` or setup validation is bypassing the intended surface
- whether `~/.capacitor/projects.json` contains the expected pinned projects
- whether the app is on the project list rather than details/onboarding

### `reason=no_ax_windows`

Interpretation:
- Accessibility is trusted enough to attach to the app process, but the app exposes no usable AX windows

Start with:
- relaunch/window visibility
- `[WindowAX]` log evidence
- `floatingMode` / top-level window behavior

### `reason=accessibility_not_trusted`

Interpretation:
- macOS AX trust is unavailable for the runner process

Use:
- `--allow-untrusted` if the environment should degrade gracefully

### `reason=missing_runner_complete`

Interpretation:
- the smoke runner or raw AX runner bailed before finishing the expected phase

Start with:
- smoke log for that run/phase
- earlier `runner.error` line

## Log-Health Checks

When `--require-log-health` is enabled, success also requires fresh `[WindowAX]` evidence in the app debug log:

- `applicationDidBecomeActive`
- `didBecomeKey`
- at least one line with `isKey=true` and `isMain=true`

That evidence is emitted from:

- `apps/swift/Sources/Capacitor/Utilities/WindowAXDiagnostics.swift`
- `apps/swift/Sources/Capacitor/App.swift`

## When To Use The Raw Runner

Only drop to `scripts/ax/ax_runner.swift` when debugging the AX interface itself rather than the verifier contract.

Typical reasons:

- the verifier tells you a card is missing from the AX tree and you want a minimal repro
- you need to test a hand-written scenario JSON
- you are debugging named AX actions vs. visible clicks

Example:

```bash
swift scripts/ax/ax_runner.swift \
  --bundle-id com.capacitor.app.debug \
  --scenario /tmp/ax-scenario.json \
  --click-mode visible
```

Raw runner caveat:

- it assumes the debug app is already running and on the intended surface
- it does not seed runtime state for you
- it is a debugging tool, not the canonical verification interface
