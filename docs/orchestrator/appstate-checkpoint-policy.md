# AppState Checkpoint Policy

> Doc role: `canonical-spec`
> Status: Current. How AppState routes delegation reviews and run checkpoints.

## Overview

`AppState` maintains two independent window targets for human-in-the-loop review:

- `reviewWindowTarget: ReviewWindowTarget?` -- delegation review routing (`UIState.swift`)
- `runCheckpointWindowTarget: RunCheckpointWindowTarget?` -- run checkpoint routing (`UIState.swift`)

These targets are independent. Setting or clearing one never mutates the other.

## Delegation Review Routing

### Target Type

```swift
struct ReviewWindowTarget: Equatable {
    let projectPath: String
    let workerID: String
}
```

Defined in `apps/swift/Sources/Capacitor/Models/UIState.swift`.

### Assignment

`reviewWindowTarget` is set explicitly by `showDelegationReview(_:)` (`apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`). This method:

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

Defined in `apps/swift/Sources/Capacitor/Models/UIState.swift`.

### Assignment

`runCheckpointWindowTarget` is auto-selected by `RunStateStore.reconcileRunCheckpointWindowTarget(currentTarget:previousRunsByID:)` (`apps/swift/Sources/Capacitor/Models/RunState.swift`), which runs on every runtime snapshot apply (`apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift`).

### Reconciliation Algorithm

The reconciliation proceeds in three steps:

**Step 1 -- Retain current target if still valid** (`RunState.swift`):

If `runCheckpointWindowTarget` is already set and the referenced checkpoint still exists in the next snapshot (verified by `runCheckpointState(target:runsByID:)`), the target is kept unchanged. This ensures the user is not interrupted mid-review.

The validity check requires all three conditions:
- The run exists in `runsByID`
- The run's status is `"paused"`
- The run's `activeCheckpoint.id` matches `target.checkpointID`

**Step 2 -- Build candidate queue** (`RunState.swift`):

All eligible runs are filtered, sorted oldest-first, and mapped to targets. If no candidates exist, `runCheckpointWindowTarget` is set to `nil`.

**Step 3 -- Select next target** (`RunState.swift`):

- If `runCheckpointWindowTarget` was previously set (meaning the current target just became invalid -- advance-on-clear), select `queuedTargets.first` (the oldest remaining candidate).
- If `runCheckpointWindowTarget` was `nil` (no prior target), only select from newly surfaced checkpoints (`newlySurfacedTargets.first`) to avoid re-presenting checkpoints that were already visible in a prior snapshot.

### Clearing

`runCheckpointWindowTarget` is set to `nil` in three places:

1. **No eligible candidates:** `reconcileRunCheckpointWindowTarget` sets it to `nil` when `queuedTargets` is empty (`RunState.swift`).
2. **Runtime snapshot failure cascade:** After 2+ consecutive snapshot failures, all run state is cleared including the target (`RuntimeSnapshotApplicator.swift`).
3. **Window disappear:** `RunCheckpointReviewWindow.onDisappear` sets `appState.runCheckpointWindowTarget = nil` (`RunCheckpointReviewWindow.swift:101-103`).

## Non-Interference Rule

Setting or clearing `reviewWindowTarget` never mutates `runCheckpointWindowTarget`, and vice versa.

This is structurally guaranteed:
- `reviewWindowTarget` is only written in `showDelegationReview` (`AppState+Projects.swift`), `DelegationReviewWindow.scheduleAutoClose` (`DelegationReviewWindow.swift`), and `DelegationReviewWindow.onDisappear` (`DelegationReviewWindow.swift`). None of these touch `runCheckpointWindowTarget`.
- `runCheckpointWindowTarget` is only written from runtime snapshot reconciliation (`RuntimeSnapshotApplicator.swift` + `RunState.swift`), runtime snapshot failure clearing (`RuntimeSnapshotApplicator.swift`), explicit checkpoint review routing (`AppState+MethodRunner.swift`), and `RunCheckpointReviewWindow.onDisappear` (`RunCheckpointReviewWindow.swift`). None of these touch `reviewWindowTarget`.

Proven by `testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState` (`AppStateRunCheckpointTests.swift:7-48`): a pre-existing `reviewWindowTarget` is asserted unchanged after a runtime snapshot apply that sets `runCheckpointWindowTarget`.

## Selection Policy

### Eligibility

A run qualifies as a checkpoint candidate when (`RunState.swift`):

```swift
run.status == "paused" && run.activeCheckpoint != nil
```

### Oldest-First Ordering

Candidates are sorted by `runCheckpointCandidatePrecedes` (`RunState.swift`):

1. Primary sort: `activeCheckpoint.createdAt` (falls back to `run.createdAt`), parsed as ISO 8601 dates, ascending.
2. Tiebreaker 1: `run.id` lexicographic ascending.
3. Tiebreaker 2: normalized `run.projectPath` lexicographic ascending.

Proven by `testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst` (`AppStateRunCheckpointTests.swift:50-85`): given two paused runs with checkpoints at `10:00:00Z` and `10:05:00Z`, the older checkpoint is selected.

### Advance-on-Clear

When the currently targeted checkpoint resolves (run resumes or checkpoint clears), the reconciler advances to the next oldest eligible candidate.

Proven by `testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears` (`AppStateRunCheckpointTests.swift:87-144`): after the older run resumes (status changes to `"active"`, no checkpoint), the target advances to the newer run's checkpoint.

### Newly Surfaced Detection

A checkpoint is considered "newly surfaced" (`isNewlySurfacedRunCheckpoint` in `RunState.swift`) when any of:
- The run did not exist in the previous snapshot
- The run was not previously paused
- The run did not previously have an active checkpoint
- The previous checkpoint ID differs from the current one

This prevents re-presenting checkpoints that the user has already seen and dismissed.

## Key Files

| Purpose | Path |
|---------|------|
| Window target types | `apps/swift/Sources/Capacitor/Models/UIState.swift` |
| Delegation review assignment | `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift` |
| Checkpoint reconciliation | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Eligibility predicate | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Newly surfaced detection | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Checkpoint target builder | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Candidate sort comparator | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Checkpoint state resolver | `apps/swift/Sources/Capacitor/Models/RunState.swift` |
| Submission mutation | `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift` |
| Snapshot apply and failure clearing | `apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift` |

## Test Contracts

| Test Method | File:Line | Validates |
|-------------|-----------|-----------|
| `testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState` | `AppStateRunCheckpointTests.swift:7` | Non-interference: applying a snapshot with a paused run sets `runCheckpointWindowTarget` without mutating a pre-existing `reviewWindowTarget` |
| `testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst` | `AppStateRunCheckpointTests.swift:50` | Oldest-first selection: given two paused runs, the one with the earlier `checkpointCreatedAt` is targeted |
| `testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears` | `AppStateRunCheckpointTests.swift:87` | Advance-on-clear: when the current target's run resumes, the target advances to the next oldest paused checkpoint |
| `testSubmitRunCheckpointDecisionMutatesRuntimeRunWithCheckpointIdentity` | `AppStateRunCheckpointTests.swift:146` | Submission payload: verifies the `mutateRun` request includes `kind`, `project_path`, `run_id`, `checkpoint_id`, `decision_action`, and `decision_note` |
