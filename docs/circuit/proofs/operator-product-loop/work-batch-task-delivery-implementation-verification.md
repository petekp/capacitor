# Work Batch Task Delivery Implementation Verification

Date: 2026-05-25
Scope: Capacitor-managed Work Batch Task delivery for Claude Code only.

## Automated Verification

Passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|DeliveryPolicy|TaskSession|State|BindingReconciler|AutoRouter|CheckpointExchange|CompletionReport)Tests|AppStateRuntimeSnapshotEffectTests|ProjectCardContextLineResolverTests'
```

Result: 114 selected tests, 0 failures.

Passed:

```bash
swift test --package-path apps/swift
```

Result: 855 XCTest cases plus 19 Swift Testing cases, 0 failures. One existing test was skipped by the suite.

## App Smoke Verification

Passed:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Result:

- Rebuilt `capacitor-core` and the Swift app.
- Relaunched `CapacitorDebug`.
- Confirmed `CapacitorDebug` and `hud-hook serve --port 7474` were running.
- Inspected the live Capacitor window with Computer Use.
- Confirmed the project list rendered after restart.
- Confirmed the `parable-school` project card showed the Work Batch recovery summary `Claude Code session needs reconnect.` instead of a stale legacy session summary.

## Covered User Scenarios

- Adding a related Task to a healthy running batch updates the Work Batch mirror and does not start a new Claude session.
- Adding a related Task to a stale/waiting/done batch resumes the stored Claude Code session with `--resume`.
- A valid Task claim moves a queued Task to working.
- Foreign, malformed, stale, wrong-generation, done-task, and needs-you claims are ignored.
- A Done report for one Task keeps the batch active when other Tasks remain open.
- Checkpoint requests move the Task to needs-you and keep the batch waiting.
- Checkpoint responses and Unresolve use the shared delivery follow-through path.
- A pending checkpoint prevents resume after a newly added related Task.
- Duplicate same-worktree cockpits block delivery instead of choosing silently.
- Work Batch card summaries prefer queued/working Work Batch state over legacy session text.

## Residual Risk

The live app pass was a smoke check, not a full destructive manual routing run against `parable-school` or `arc-design-studio`. The behavior that would create sessions, worktrees, claims, checkpoints, and Done reports is covered by focused unit tests using temporary project roots and terminal script recorders.
