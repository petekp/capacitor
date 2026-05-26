# Task Capture Front Door Live Proof - 2026-05-26

## Scenario

Verify the most fragile remaining Task front-door behavior in the live Capacitor Debug app:

- Clicking the visible Task affordance opens the capture overlay.
- The text area is focused immediately.
- Typing works without restarting the app or manually refocusing the input.
- Closing the overlay without submitting does not create a new Task or worker session.

This is a live verification of the focus bug that previously made the capture form intermittently impossible to type into.

## Environment

Restarted the app from the current repo build:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Observed after restart:

- Capacitor Debug pid: `56777`
- Runtime service pid: `56862`
- App path: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor`
- `scripts/dev/check-terminal-activation-state.sh` reported one Debug app process, no release app process, and active Ready projects for `pete-2025`, `arc-design-studio`, and `parable-school`.

## Live Steps

1. Opened the live Capacitor Debug app through Computer Use.
2. Confirmed the `pete-2025` project card exposed `Add task to this project`.
3. Clicked the visible `+ Task` affordance on the `pete-2025` card.
4. The overlay opened with project label `pete-2025`.
5. Accessibility state showed the focused element as the capture text entry:

```text
The focused UI element is text entry area (settable, string)
```

6. Typed:

```text
Live focus proof 2026-05-26
```

7. Accessibility state immediately reflected the typed text and the Add Task button became enabled:

```text
text entry area (settable, string) Live focus proof 2026-05-26
button Description: Add Task
```

8. Closed the overlay without submitting.
9. Re-read the app state and confirmed the overlay was gone and the project cards were back.

## Result

Pass.

The Task capture overlay accepted typing immediately after opening. This validates the live behavior behind the source changes in `IdeaCapturePopover.swift`: focus-on-appear, delayed focus retries, and AppKit text/scroll views refusing window-drag behavior.

No Task was submitted during this proof, so the test did not intentionally create a new Work Batch, wake a Claude session, or add worker churn.

## Follow-Up Front Door Hardening

After the focus proof, Computer Use exposed a related usability gap: the visible `+ Task` button is hover-driven, so the project card did not always expose a stable automation/accessibility path for adding a Task. The context menu also still used the stale `Capture Idea...` label.

Patched behavior:

- Project cards now expose an `Add Task` accessibility action when Task capture is available.
- The project-card context menu now says `Add Task...`.
- The menu uses a plus icon instead of the old idea/lightbulb metaphor.

Live restart check after this patch showed `pete-2025`, `arc-design-studio`, `parable-school`, and `capacitor` cards exposing these secondary actions:

```text
Hide, Add Task, View Details, Open in Terminal
```

## Notes

- A full-screen screenshot was intentionally not retained because it captured unrelated desktop content. This proof records only the Capacitor-specific accessibility and command evidence.
- A first Computer Use element-index click did not open the overlay, while a direct click on the visible `+ Task` affordance did. Treat that as a Computer Use targeting limitation unless it reproduces for a human click.

## Automated Verification

Focused command:

```bash
swift test --package-path apps/swift --filter 'IdeaCapturePopoverTests|TaskCaptureSurfaceCopyTests|ProjectFeatureCoordinatorTests|WorkBatchAutoRouterTests'
```

Result:

- 49 tests executed.
- 1 window-server-dependent test skipped.
- 0 failures.

Follow-up focused command after the accessibility-action patch:

```bash
swift test --package-path apps/swift --filter 'TaskCaptureSurfaceCopyTests|IdeaCapturePopoverTests|ProjectFeatureCoordinatorTests|WorkBatchAutoRouterTests'
```

Result:

- 49 tests executed.
- 1 window-server-dependent test skipped.
- 0 failures.
