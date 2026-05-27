# Adversarial Review 08

Reviewed artifacts:

- `apps/swift/Sources/Capacitor/Views/Projects/OperatorFieldOfWorkProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Tests/CapacitorTests/OperatorFieldOfWorkProjectionTests.swift`
- Current Scene 2 Field Of Work diff after the exception-placement fix.

Review stance:

- First clean pass after wiring the attention-derived field of work.
- Attack the risk that stale or failed work gets hidden as dormant, projects duplicate across sections, hidden projects vanish, or the UI expands into a broader runner/control system.

## Findings

No medium, high, or critical findings.

## Checks

- Confirmed the field renders the storyboard sections in order: Needs You, Running Normally, Recently Changed, Dormant / Hidden.
- Confirmed failed and stale exception items now surface in Needs You instead of falling through to Dormant / Hidden.
- Confirmed checkpoint items still beat exception items for the same project, preserving the decision-first priority.
- Confirmed projects missing from the attention summary still render as Dormant / Hidden fallback rows instead of disappearing.
- Confirmed hidden projects remain marked and collapsed inside the existing hidden disclosure when they belong to Dormant / Hidden.
- Confirmed `ProjectsView` reuses the existing `ProjectCardView`, `CompactProjectCardView`, primary actions, reorder tracking, and hidden-project controls.
- Confirmed the change does not add checkpoint action routing, runner behavior, queue/retry machinery, broad memory, task DAGs, new terminal/editor behavior, SaaS framing, generalized host abstraction, or old Circuit runtime dependency.

## Verification

- `swift test --package-path apps/swift --filter OperatorFieldOfWorkProjectionTests`
- `swift test --package-path apps/swift --filter OperatorAttentionProjectionTests`
- `swift test --package-path apps/swift --filter ReturnBriefContentTests`
- `swift test --package-path apps/swift`
- Scoped `git diff --check` for touched tracked Swift files.
- Scoped trailing-whitespace check for new Swift, test, plan, and proof files.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- `pgrep -fl CapacitorDebug`
- `pgrep -fl "hud-hook serve"`

## Residual Risk

The Dormant / Hidden section still uses the existing `HIDDEN` disclosure header for manually hidden rows. That is acceptable for this slice because the parent section now gives the product-level label, and the old hidden-project affordance remains intact.

## Result

The Scene 2 field-of-work implementation is solid enough for a second clean review pass.
