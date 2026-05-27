# Project Card Work Batch Status Live Proof

Date: 2026-05-26

## Scenario

A project card should not look `Idle` when Capacitor already knows a Work Batch checkpoint needs the operator. The card summary and the status chip should tell the same story.

## Source Changes

- `WorkBatchStatus.sessionState` maps Work Batch states into the existing card status vocabulary in `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:25`.
- `WorkBatchProjectVisualStateResolver` elevates any pending Work Batch checkpoint to `.waiting`, then falls back to the first active Work Batch state in `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:555`.
- `AppState.workBatchSessionState(for:)` exposes that projection to SwiftUI in `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:534`.
- `ProjectCard.currentState` now considers Work Batch state before legacy session state in `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift:196`.
- `StatusChipsRow.presentation` now shows Work Batch state before legacy session state in `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift:60`.

## Automated Evidence

Focused tests:

```bash
swift test --package-path apps/swift --filter 'WorkBatchStateTests|StatusChipsRowTests|ProjectCardAnimationPolicyTests'
```

Result: 48 tests passed, 0 failures.

New coverage:

- `WorkBatchStateTests.testProjectVisualStateElevatesPendingCheckpointEvenWhenBatchIsIdle` proves a pending checkpoint projects `.waiting`.
- `WorkBatchStateTests.testProjectVisualStateUsesFirstActiveBatchStatus` proves active Work Batch states surface on the project card.
- `WorkBatchStateTests.testProjectVisualStateIgnoresIdleDoneBatches` proves completed idle batches do not keep the project visually active.
- `StatusChipsRowTests.testWorkBatchStateWinsOverIdleLegacySession` proves Work Batch `Waiting` beats a legacy idle session chip.
- `StatusChipsRowTests.testActiveRunWinsOverWorkBatchState` preserves the older run-priority rule.

Broad checks:

```bash
swift test --package-path apps/swift
./scripts/ci/swiftformat-lint.sh
bats tests/dev-scripts
git diff --check
```

Results:

- Full Swift: 936 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing tests passed.
- SwiftFormat: 0/301 files require formatting.
- Bats dev scripts: 76 tests passed.
- `git diff --check`: clean.

## Live Debug App Evidence

Restart:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Post-restart guard:

```text
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_debug_processes:
70040 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
capacitor_release_processes:
```

Temporary checkpoint injection:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: batch-typeface-unification-from-source-parable-01ksfw1
Task: 01KSK2QPJEJVNWY12ATPPEAQ3X
Checkpoint: cp-live-project-card-waiting-2026-05-26
```

Live app log after injection:

```text
[2026-05-26T22:51:44.188Z] [DEBUG][ProjectCardView][CardState] parable-school:Waiting path=/Users/petepetrash/Code/parable-school
[2026-05-26T22:51:44.193Z] ReadyChimeGate decision=skip reason=transition source=visible_state project_path=/Users/petepetrash/Code/parable-school old_state=Optional(Capacitor.SessionState.idle) new_state=Optional(Capacitor.SessionState.waiting)
```

The runtime snapshot still reported the legacy project session as idle at the same time, so the visible `Waiting` state came from Work Batch checkpoint projection, not stale session state.

Cleanup:

```text
restored /Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fparable-school/work-batches/state.json
temporary checkpoint count after restore: 0
```

Live app log after restore:

```text
[2026-05-26T22:52:04.169Z] [DEBUG][ProjectCardView][CardState] parable-school:Idle path=/Users/petepetrash/Code/parable-school
[2026-05-26T22:52:04.172Z] ReadyChimeGate decision=skip reason=transition source=visible_state project_path=/Users/petepetrash/Code/parable-school old_state=Optional(Capacitor.SessionState.waiting) new_state=Optional(Capacitor.SessionState.idle)
```

## Result

Pass. A pending Work Batch checkpoint now makes the project card visibly `Waiting`; restoring the original Work Batch state returns the card to `Idle`. The Debug app guard confirmed the live verification targeted `apps/swift/CapacitorDebug.app`, not `/Applications/Capacitor.app`.

## Remaining Risk

This proof used controlled state injection. A naturally agent-created checkpoint still needs to be observed end to end, but the UI projection path is now source-backed, test-backed, and live-verified.
