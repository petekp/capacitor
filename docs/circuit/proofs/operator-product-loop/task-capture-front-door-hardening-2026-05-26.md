# Task Capture Front Door Hardening - 2026-05-26

## Scope

This slice tightens the capture front door so it matches the current product language and the intended user rhythm:

- The visible affordance is a Task affordance, not an Idea affordance.
- The capture overlay should be focusable as soon as it opens and should not turn into a window drag target when clicked.
- Internal `Idea` naming remains in place where it is a legacy storage/API/test contract.

This stays inside the current Swift UI layer and preserves the existing Work Batch auto-routing path.

## Source-Backed Changes

- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:4` adds `TaskCaptureSurfaceCopy` for Task-first visible capture copy.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:61` uses Task-first placeholders.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:105` requests text-area focus on overlay appear, in addition to the existing animation-completion focus request.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:457` extends focus retries through `0.75s`, giving AppKit/SwiftUI animation and window activation more time to settle.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:541` makes the scroll view refuse window dragging and request focus on mouse down.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift:717` makes the text view refuse window dragging, activate the app, make the window key, and claim first responder on mouse down.
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift:905` changes the card capture label/accessibility copy to Task language.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaQueueView.swift:242` changes the empty queue copy to Task language.
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift:118` changes visible status copy from idea/note language to task language.
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift:3` marks the method selector as legacy and changes its visible explanatory copy to task language.

## Verification

Focused command:

```bash
swift test --package-path apps/swift --filter 'IdeaCapturePopoverTests|TaskCaptureSurfaceCopyTests|ProjectFeatureCoordinatorTests|WorkBatchAutoRouterTests'
```

Result:

- 49 tests executed.
- 1 window-server-dependent test skipped.
- 0 failures.

Earlier narrow command also passed:

```bash
swift test --package-path apps/swift --filter 'TaskCaptureSurfaceCopyTests|ProjectFeatureCoordinatorTests|AccessibilityIdentifiersTests'
```

Result:

- 11 tests executed.
- 0 failures.

Added/updated coverage:

- `apps/swift/Tests/CapacitorTests/TaskCaptureSurfaceCopyTests.swift:4` verifies visible capture copy says Task and does not use Idea language.
- `apps/swift/Tests/CapacitorTests/IdeaCapturePopoverTests.swift:114` verifies the capture scroll/text views do not become window drag handles.

Visible-copy scan:

```bash
rg -n 'Text\("[^"]*[Ii]dea|help\("[^"]*[Ii]dea|accessibilityLabel\("[^"]*[Ii]dea|"[^"]*\+ Idea|Dream big|What.s your idea|No ideas' apps/swift/Sources/Capacitor/Views apps/swift/Sources/Capacitor/Support apps/swift/Sources/Capacitor/Models
```

Result:

- No remaining visible capture-surface Idea copy was found.
- The only hit was `Text("Added \(formatRelativeDate(idea.added))")`, where `idea` is the Swift variable name, not rendered copy.

## Manual Verification Status

Live visual verification remains blocked from automation. `screencapture` produced `/tmp/capacitor-task-capture-screen.png`, a black 3024 x 1964 image, so I did not claim a physical click/type pass.

Manual check after unlocking:

1. Relaunch Capacitor Debug.
2. Hover a project card and confirm the button says `Task`.
3. Click `Task`.
4. Confirm the overlay shows Task-oriented placeholder/copy.
5. Type immediately without clicking. It should accept input.
6. Click inside the text area if focus is lost. It should reclaim focus rather than dragging the window.
7. Submit a test Task and confirm Work Batch routing still starts automatically.
