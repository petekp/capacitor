# Decision: Idle State Stabilization

## Selected approach

**Hysteresis with Asymmetric Thresholds (Approach 1b)** — Swift-side per-project idle stabilization that requires N consecutive idle snapshots before committing an active→idle transition, while allowing instant idle→active transitions.

## Evidence for this choice

- **From analysis:** Only 2 approaches (Laziest and Hysteresis) pass all MUST criteria without exception. Hysteresis handles both 1-cycle and multi-cycle idle flashes with ~35 extra lines of code over the Laziest fix.
- **From research:** Industry consensus (Datadog recovery thresholds, Grafana Pending/Recovering, K8s probe thresholds) is that asymmetric stabilization — slow to enter degraded state, instant to leave — is the correct pattern for status dashboards.
- **From codebase:** The existing `stabilizeEmptyRuntimeSnapshotIfNeeded` in `SessionStateManager.swift` already implements the exact same pattern (consecutive-count threshold) for fully-empty snapshots. Extending this to per-project idle is a natural evolution, not a new concept.
- **From constraints:** Swift-only change means no Rust changes, no UniFFI binding regeneration, no snapshot format changes. One file, testable with mock snapshots, degrades gracefully.

## Why not the alternatives

- **Laziest (1-cycle hold):** Fixes the common case but fails if the idle flash lasts 2+ polling cycles. The code savings (~35 fewer lines) isn't worth the reduced robustness. If we later discover multi-cycle flashes, we'd need to redo the work.
- **Tombstone (2a):** 10s TTL exceeds the 4s maximum genuine-idle delay MUST criterion. UniFFI binding regeneration and new state variants are disproportionate to the problem.
- **Soft Delete (2b):** 3+ files across 2 languages for a UX polish fix. Coordinated Rust+Swift changes multiply the testing and maintenance burden.
- **Suppress SessionEnd (3a):** Showing "Ready" for a genuinely ended session is a semantic lie that would confuse both users and future developers.
- **Deferred Delete (3b):** Architecturally incompatible — CLI-invoked binaries can't guarantee timely cleanup without new events.
- **Hybrid (1b + Rust timestamp):** Over-engineered for now. The transparent-ui-server is optional/diagnostic. If it needs stabilization later, we can add the timestamp field then.

## Implementation plan

### Step 1: Add per-project idle tracking state

In `SessionStateManager.swift`, add:
```swift
/// Tracks consecutive idle snapshots per project path for hysteresis.
/// Key: project path, Value: consecutive idle snapshot count.
private var consecutiveIdleCounts: [String: Int] = [:]
```

### Step 2: Add stabilization method

Add a new private method `stabilizeIdleTransitions(_:)` that:
1. Takes the merged `[String: ProjectSessionState]` map
2. For each project in the map:
   - If the project is idle AND was previously active (`sessionStates[path]?.isActive == true`):
     - Increment `consecutiveIdleCounts[path]`
     - If count < threshold (2): substitute the previous state, log the hold
     - If count >= threshold: commit the idle, reset count, log the commit
   - If the project is active: reset `consecutiveIdleCounts[path]` to 0
   - If the project is idle AND was previously idle (or absent): reset count (already idle, no stabilization needed)
3. Return the stabilized map

### Step 3: Wire into the merge pipeline

In `applyRuntimeProjectStates()`, call `stabilizeIdleTransitions()` AFTER `stabilizeEmptyRuntimeSnapshotIfNeeded()` and BEFORE assigning to `self.sessionStates`. The pipeline becomes:

```
merged = mergeRuntimeProjectStates(...)
stabilized = stabilizeEmptyRuntimeSnapshotIfNeeded(merged)
stabilized = stabilizeIdleTransitions(stabilized)    // NEW
// ... existing didChange check and animation
```

### Step 4: Add diagnostic logging

Log stabilization decisions via `DebugLog.write()`:
- `"idle_stabilize hold project=<path> count=<N>/<threshold>"`
- `"idle_stabilize commit project=<path> count=<N>"`
- `"idle_stabilize reset project=<path> (became active)"`

### Step 5: Add tests

In `TerminalLauncherTests.swift` or a new `SessionStateManagerTests.swift`:
1. `testIdleStabilizationHoldsPreviousActiveState` — project goes from Working to Idle, verify first snapshot holds Working
2. `testIdleStabilizationCommitsAfterThreshold` — project stays Idle for N consecutive snapshots, verify Idle is committed
3. `testIdleStabilizationResetsOnActive` — project goes Idle then back to Working, verify counter resets
4. `testIdleStabilizationPassesThroughAlreadyIdle` — project was already Idle, new Idle snapshot passes through immediately (no double-hold)

### Step 6: Verify

1. `swift test` from `apps/swift/`
2. Manual: observe project card behavior when closing/restarting Claude Code sessions
3. Check `DebugLog` for stabilization decisions

## Known risks and mitigations

- **Risk:** The idle flash is caused by project identity drift, not SessionEnd, and the 2-cycle hold isn't enough to cover the drift recovery time.
  **Mitigation:** Hysteresis handles both causes (it stabilizes ANY active→idle transition regardless of cause). If drift-caused flashes last longer, increase the threshold from 2 to 3.

- **Risk:** Genuine session ends take 4 seconds longer to show as idle.
  **Mitigation:** 4 seconds is imperceptible for a glanceable dashboard. The user already has visual feedback from the terminal (Claude Code's own exit message) before looking at Capacitor.

- **Risk:** The `consecutiveIdleCounts` dictionary grows unbounded as projects are added/removed.
  **Mitigation:** Prune entries for projects no longer in `sessionStates` during the same method call (same pattern as `sessionAttributions` pruning on line 149).
