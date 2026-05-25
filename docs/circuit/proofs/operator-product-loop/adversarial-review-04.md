# Adversarial Review 04

Reviewed artifacts:

- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/OperatorViewStateStore.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ReturnBriefView.swift`
- `apps/swift/Sources/Capacitor/Support/Accessibility/AccessibilityIdentifiers.swift`
- `apps/swift/Tests/CapacitorTests/AppStateOperatorViewStateTests.swift`
- `apps/swift/Tests/CapacitorTests/OperatorAttentionProjectionTests.swift`
- `apps/swift/Tests/CapacitorTests/OperatorViewStateStoreTests.swift`
- `apps/swift/Tests/CapacitorTests/ReturnBriefContentTests.swift`
- `apps/swift/Tests/CapacitorTests/AccessibilityIdentifiersTests.swift`

Review stance:

- Treat the first visible return brief as wrong until it proves that it is narrow, visible, fed by the attention projection, and not quietly expanding the runtime boundary.

## Findings

No medium, high, or critical findings.

## Checks

- Confirmed `ProjectsView` renders `ReturnBriefView` above the existing project/activity surface without replacing active/idle project grouping.
- Confirmed the brief is fed by `OperatorAttentionProjection.build(...)` using projects, runs, session state, and manually dormant projects.
- Confirmed `ReturnBriefContent` summarizes needs-you, recently changed, running normally, exceptions, and no-attention states in storyboard order.
- Confirmed the first implementation review fixes are present: completed-worker copy no longer claims evidence, and `operatorViewStateSnapshot` remains `private(set)` in `AppState`.
- Confirmed operator view state persists only narrow last-seen/opened metadata in the Capacitor namespace.
- Confirmed the changed implementation does not introduce a runner, queue, retry platform, broad memory store, new terminal/editor, SaaS workflow, generalized multi-host abstraction, runtime schema change, UniFFI change, or dependency on `/Users/petepetrash/Code/capacitor-circuit`.

## Verification

- `swift test --package-path apps/swift --filter ReturnBriefContentTests`
- `swift test --package-path apps/swift --filter AppStateOperatorViewStateTests`
- `swift test --package-path apps/swift --filter OperatorAttentionProjectionTests`
- `swift test --package-path apps/swift --filter AccessibilityIdentifiersTests`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`

## Residual Risk

The brief currently summarizes the live attention snapshot and carries `lastAppOpenedAt`, but it does not yet use last-seen data to compute true "since you were away" deltas. That is acceptable for this return/orient slice and should be handled in the next lifecycle increment.

## Result

The return-brief implementation is ready for a second clean review.
