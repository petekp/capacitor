# Work Batch Waiting Attention Recovery

Date: 2026-05-26

## Scenario

A Work Batch can be `Waiting` for two very different reasons:

- A checkpoint is ready and the user needs to answer it.
- The batch needs recovery because Capacitor could not safely continue delivery, reconnect to Claude Code, or disambiguate the cockpit.

The second case should not appear as normal background work. It needs operator attention, but it should still explain the recovery action plainly.

## Intended Behavior

- Pending checkpoints keep using the checkpoint-first path.
- Non-checkpoint `Waiting` Work Batches surface as an exception/Needs You item.
- Healthy `Ready`, `Working`, and `Compacting` Work Batches remain Running Normally.
- Duplicate cockpit summaries recommend resolving duplicate sessions.
- Missing/reconnect summaries recommend reconnecting the session.

## Source Changes

- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift` adds `waitingWorkBatch` and classifies non-checkpoint waiting batches as exceptions.
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift` excludes `.waiting` from the running-work candidate.
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionPrimaryActionResolver.swift` routes `waitingWorkBatch` through the normal project action instead of treating it as a terminal shortcut.
- `scripts/dev/restart-alpha-stable.sh` now forces `projectDetails,ideaCapture,llmFeatures`, keeping the canonical Debug build on the Task-first product-loop path.

## Automated Verification

Focused Swift tests passed:

```bash
swift test --package-path apps/swift --filter 'OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|OperatorAttentionPrimaryActionResolverTests'
```

Result: 35 tests passed.

Focused dev-script tests passed:

```bash
bats tests/dev-scripts/restart-alpha-stable.bats tests/dev-scripts/check-terminal-activation-state.bats tests/dev-scripts/restart-app.bats
```

Result: 18 tests passed.

Full dev-script verification passed:

```bash
bats tests/dev-scripts
```

Result: 82 tests passed.

Full Swift verification passed:

```bash
swift test --package-path apps/swift
```

Result: 941 XCTest cases passed with 1 skipped, plus 19 Swift Testing tests passed.

Formatting and whitespace checks passed:

```bash
./scripts/ci/swiftformat-lint.sh
git diff --check
```

## Live Verification

Strict Debug-app preflight passed after relaunch:

```text
timestamp: 2026-05-26T23:22:04Z
front_app: Capacitor
front_app_pid: 32401
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app

capacitor_debug_processes:
32401 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:
```

Bundle metadata proved the expected Debug identity and Task-first feature set:

```text
CFBundleIdentifier: com.capacitor.app.debug
CFBundleDisplayName: Capacitor Debug
CapacitorFeaturesEnabled: projectDetails,ideaCapture,llmFeatures
```

A temporary synthetic waiting batch was added to `parable-school` state:

```text
batch_id: batch-live-waiting-attention-2026-05-26
task_id: task-live-waiting-attention-2026-05-26
status: waiting
summary: Claude Code session needs reconnect.
```

The running Debug app projected the project card as Waiting:

```text
[2026-05-26T23:14:53.905Z] [DEBUG][ProjectCardView][CardState] parable-school:Waiting path=/Users/petepetrash/Code/parable-school
```

The original Work Batch state was restored after the live check, and the synthetic batch was verified absent.

## Result

Pass for this slice. Waiting Work Batches that are not pending checkpoints are now treated as recovery attention instead of normal running work.

Remaining risk: the current stable UI intentionally keeps the Work Batch card list simple, so the field-of-work section placement is source/test-proven rather than separately screenshot-proven in the visible app.
