# Task Capture Front Door Hardening Adversarial Review 01 - 2026-05-26

## Scope

Reviewed the Task capture copy and focus hardening slice against the operator-control-plane goal.

Files reviewed:

- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift`
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaQueueView.swift`
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift`
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
- `apps/swift/Tests/CapacitorTests/IdeaCapturePopoverTests.swift`
- `apps/swift/Tests/CapacitorTests/TaskCaptureSurfaceCopyTests.swift`

## Findings

No medium, high, or critical findings.

## Low Residual Risks

1. [Low] Live click/type verification is still blocked by the black automation screenshot.
   - Why low: the Goal allows live verification when app state allows it, and current automation cannot see the desktop. Source and focused tests prove the intended copy and AppKit focus mechanics.
   - Follow-up: manually verify typing into the capture overlay after unlocking.

2. [Low] Internal names still say `Idea`.
   - Why low: `CONTEXT.md` explicitly allows older surfaces/code to retain Idea where needed, while product language should prefer Task. This slice changes visible copy without breaking storage/accessibility/test contracts.

3. [Low] The legacy Method Selector still exists.
   - Why low: this slice does not make it more prominent; it only removes visible idea wording. Automatic Work Batch routing remains the capture path.

## Verification Reviewed

```bash
swift test --package-path apps/swift --filter 'IdeaCapturePopoverTests|TaskCaptureSurfaceCopyTests|ProjectFeatureCoordinatorTests|WorkBatchAutoRouterTests'
```

Result:

- 49 tests executed.
- 1 skipped.
- 0 failures.

## Verdict

The slice is aligned with the vision and safe to build on.
