# AppState Checkpoint Policy

> Doc role: `canonical-spec`
> Status: Current. How AppState routes delegation reviews and run checkpoints.

## Overview

`AppState` maintains two independent window targets for human-in-the-loop review:

- `reviewWindowTarget: ReviewWindowTarget?` -- delegation review routing (`AppState.swift:119`)
- `runCheckpointWindowTarget: RunCheckpointWindowTarget?` -- run checkpoint routing (`AppState.swift:120`)

These targets are independent. Setting or clearing one never mutates the other.

## Delegation Review Routing

### Target Type

```swift
struct ReviewWindowTarget: Equatable {
    let projectPath: String
    let workerID: String
}
```

Defined at `AppState.swift:108-111`.

### Assignment

`reviewWindowTarget` is set explicitly by `showDelegationReview(_:)` (`AppState.swift:1401-1412`). This method:

1. Checks that `isDelegationLoopEnabled` is true (otherwise falls back to terminal launch).
2. Looks up the `RuntimeDelegationState` for the project via `delegationState(for:)`.
3. If a delegation exists, sets `reviewWindowTarget = ReviewWindowTarget(projectPath:, workerID:)`.

### Clearing

`reviewWindowTarget` is set to `nil` in two places:

1. **Auto-close after submission:** `DelegationReviewWindow.scheduleAutoClose()` fires a 2-second timer that sets `appState.reviewWindowTarget = nil` (`DelegationReviewWindow.swift:701-708`).
2. **Window disappear:** `DelegationReviewWindow.onDisappear` sets `appState.reviewWindowTarget = nil` (`DelegationReviewWindow.swift:126-129`).

There is no automatic reconciliation. The delegation review target is purely event-driven.

## Run Checkpoint Routing

### Target Type

```swift
struct RunCheckpointWindowTarget: Equatable {
    let projectPath: String
    let runID: String
    let checkpointID: String
}
```

Defined at `AppState.swift:113-117`.

### Assignment

`runCheckpointWindowTarget` is auto-selected by `reconcileRunCheckpointWindowTarget(previousRunsByID:nextRunsByID:)` (`AppState.swift:1776-1815`), which runs on every runtime snapshot apply (`AppState.swift:613-616`).

### Reconciliation Algorithm

The reconciliation proceeds in three steps:

**Step 1 -- Retain current target if still valid** (`AppState.swift:1780-1787`):

If `runCheckpointWindowTarget` is already set and the referenced checkpoint still exists in the next snapshot (verified by `runCheckpointState(target:runsByID:)` at `AppState.swift:1872-1885`), the target is kept unchanged. This ensures the user is not interrupted mid-review.

The validity check at `AppState.swift:1876-1879` requires all three conditions:
- The run exists in `runsByID`
- The run's status is `"paused"`
- The run's `activeCheckpoint.id` matches `target.checkpointID`

**Step 2 -- Build candidate queue** (`AppState.swift:1789-1797`):

All eligible runs are filtered, sorted oldest-first, and mapped to targets. If no candidates exist, `runCheckpointWindowTarget` is set to `nil`.

**Step 3 -- Select next target** (`AppState.swift:1810-1814`):

- If `runCheckpointWindowTarget` was previously set (meaning the current target just became invalid -- advance-on-clear), select `queuedTargets.first` (the oldest remaining candidate).
- If `runCheckpointWindowTarget` was `nil` (no prior target), only select from newly surfaced checkpoints (`newlySurfacedTargets.first`) to avoid re-presenting checkpoints that were already visible in a prior snapshot.

### Clearing

`runCheckpointWindowTarget` is set to `nil` in three places:

1. **No eligible candidates:** `reconcileRunCheckpointWindowTarget` sets it to `nil` when `queuedTargets` is empty (`AppState.swift:1794-1795`).
2. **Runtime snapshot failure cascade:** After 2+ consecutive snapshot failures, all run state is cleared including the target (`AppState.swift:660`).
3. **Window disappear:** `RunCheckpointReviewWindow.onDisappear` sets `appState.runCheckpointWindowTarget = nil` (`RunCheckpointReviewWindow.swift:101-103`).

## Non-Interference Rule

Setting or clearing `reviewWindowTarget` never mutates `runCheckpointWindowTarget`, and vice versa.

This is structurally guaranteed:
- `reviewWindowTarget` is only written in `showDelegationReview` (`AppState.swift:1407`), `DelegationReviewWindow.scheduleAutoClose` (`DelegationReviewWindow.swift:706`), and `DelegationReviewWindow.onDisappear` (`DelegationReviewWindow.swift:128`). None of these touch `runCheckpointWindowTarget`.
- `runCheckpointWindowTarget` is only written in `reconcileRunCheckpointWindowTarget` (`AppState.swift:1795`, `1811`, `1813`), `handleRuntimeSnapshotFailureIfFresh` (`AppState.swift:660`), and `RunCheckpointReviewWindow.onDisappear` (`RunCheckpointReviewWindow.swift:102`). None of these touch `reviewWindowTarget`.

Proven by `testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState` (`AppStateRunCheckpointTests.swift:7-48`): a pre-existing `reviewWindowTarget` is asserted unchanged after a runtime snapshot apply that sets `runCheckpointWindowTarget`.

## Selection Policy

### Eligibility

A run qualifies as a checkpoint candidate when (`AppState.swift:1817-1818`):

```swift
run.status == "paused" && run.activeCheckpoint != nil
```

### Oldest-First Ordering

Candidates are sorted by `runCheckpointCandidatePrecedes` (`AppState.swift:1845-1869`):

1. Primary sort: `activeCheckpoint.createdAt` (falls back to `run.createdAt`), parsed as ISO 8601 dates, ascending.
2. Tiebreaker 1: `run.id` lexicographic ascending.
3. Tiebreaker 2: normalized `run.projectPath` lexicographic ascending.

Proven by `testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst` (`AppStateRunCheckpointTests.swift:50-85`): given two paused runs with checkpoints at `10:00:00Z` and `10:05:00Z`, the older checkpoint is selected.

### Advance-on-Clear

When the currently targeted checkpoint resolves (run resumes or checkpoint clears), the reconciler advances to the next oldest eligible candidate.

Proven by `testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears` (`AppStateRunCheckpointTests.swift:87-144`): after the older run resumes (status changes to `"active"`, no checkpoint), the target advances to the newer run's checkpoint.

### Newly Surfaced Detection

A checkpoint is considered "newly surfaced" (`isNewlySurfacedRunCheckpoint` at `AppState.swift:1821-1834`) when any of:
- The run did not exist in the previous snapshot (`AppState.swift:1826`)
- The run was not previously paused (`AppState.swift:1827`)
- The run did not previously have an active checkpoint (`AppState.swift:1828`)
- The previous checkpoint ID differs from the current one (`AppState.swift:1833`)

This prevents re-presenting checkpoints that the user has already seen and dismissed.

## Key Files

| Purpose | Path |
|---------|------|
| Window target types | `apps/swift/Sources/Capacitor/Models/AppState.swift:108-120` |
| Delegation review assignment | `apps/swift/Sources/Capacitor/Models/AppState.swift:1401-1412` |
| Checkpoint reconciliation | `apps/swift/Sources/Capacitor/Models/AppState.swift:1776-1815` |
| Eligibility predicate | `apps/swift/Sources/Capacitor/Models/AppState.swift:1817-1818` |
| Newly surfaced detection | `apps/swift/Sources/Capacitor/Models/AppState.swift:1821-1834` |
| Checkpoint target builder | `apps/swift/Sources/Capacitor/Models/AppState.swift:1836-1843` |
| Candidate sort comparator | `apps/swift/Sources/Capacitor/Models/AppState.swift:1845-1869` |
| Checkpoint state resolver | `apps/swift/Sources/Capacitor/Models/AppState.swift:1872-1885` |
| Submission mutation | `apps/swift/Sources/Capacitor/Models/AppState.swift:1414-1446` |
| Snapshot failure clearing | `apps/swift/Sources/Capacitor/Models/AppState.swift:651-661` |

## Test Contracts

| Test Method | File:Line | Validates |
|-------------|-----------|-----------|
| `testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState` | `AppStateRunCheckpointTests.swift:7` | Non-interference: applying a snapshot with a paused run sets `runCheckpointWindowTarget` without mutating a pre-existing `reviewWindowTarget` |
| `testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst` | `AppStateRunCheckpointTests.swift:50` | Oldest-first selection: given two paused runs, the one with the earlier `checkpointCreatedAt` is targeted |
| `testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears` | `AppStateRunCheckpointTests.swift:87` | Advance-on-clear: when the current target's run resumes, the target advances to the next oldest paused checkpoint |
| `testSubmitRunCheckpointDecisionMutatesRuntimeRunWithCheckpointIdentity` | `AppStateRunCheckpointTests.swift:146` | Submission payload: verifies the `mutateRun` request includes `kind`, `project_path`, `run_id`, `checkpoint_id`, `decision_action`, and `decision_note` |
