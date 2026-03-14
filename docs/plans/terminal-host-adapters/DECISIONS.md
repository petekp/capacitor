# Decisions

## 2026-03-13 — HSTA-D1 Use Concrete Host Drivers, Not a Shared Host Shell

Option 2 will land as separate concrete `TerminalDriver` implementations:

- `ITermTerminalDriver`
- `TerminalAppTerminalDriver`

The migration will not keep a new generic host-terminal runtime owner beneath them. Shared code is allowed only for pure helpers such as escaping, AppleScript result parsing, and shell-script construction.

Why:

- `TerminalDriver` is already the right ownership seam in the current architecture.
- Adding per-app automation clients beneath another shared host driver would keep the same ambiguity we are trying to remove.
- Separate concrete drivers give us the same clarity Ghostty now has, with lower ceremony than a two-layer host abstraction.

Rejected alternatives:

- Harden `ScriptedTerminalDriver` in place. Too likely to recreate the same mixed-ownership pressure later.
- Add `ITermAutomationClient` and `TerminalAppAutomationClient` beneath a shared host driver. Better than today, but still leaves the runtime owner generic.

Consequences:

- `TerminalDriverRegistry` will own one concrete type per terminal app.
- Driver-specific log labels and test files become part of the public maintenance story for this subsystem.
- `ScriptedTerminalDriver` becomes an explicit deletion target.

## 2026-03-13 — HSTA-D2 Generalize Failure Modeling With One UI-Facing Enum

`TerminalActivationFailureReason` remains the single failure type that flows through the coordinator and `TerminalActivationResult`, but it moves to a terminal-neutral home and grows host-terminal cases.

Target shape:

```swift
enum HostTerminalOperation: Equatable {
    case focusByTTY
    case activateApplication
    case openApplication
    case sendCommand
}

enum TerminalActivationFailureReason: Equatable, Error {
    case ghosttyUnsupportedVersion(String?)
    case ghosttyAutomationUnavailable(String?)
    case hostOperationFailed(
        app: SupportedTerminalApp,
        operation: HostTerminalOperation,
        detail: String?
    )
}
```

Why:

- The coordinator and AppState already expect one optional failure reason.
- A single UI-facing enum keeps failure propagation simple and avoids a second mapping layer.
- Host-terminal failures need typed app and operation context, not more generic strings.

Rejected alternatives:

- Split per-app failure enums and map later. More ceremony for no real gain at the current scale.
- Add only generic string errors. Too weak for testing, user copy, and future diagnostics.

Consequences:

- `AppState` can stop using Ghostty-specific fallback text.
- Ghostty-specific cases stay intact.
- Host-terminal drivers must map checked shell or AppleScript failures into `hostOperationFailed(...)`.

## 2026-03-13 — HSTA-D3 Checked Host Launch Becomes Async

Host-terminal `launch(...)` will become async so the driver can wait for `open -b ...` plus the delayed `System Events` keystroke script to finish without blocking the main actor.

Target contract:

```swift
protocol TerminalDriver: AnyObject {
    func launch(command: String, projectPath: String?) async -> Bool
}
```

The coordinator and launcher keep their roles, but the `launchTerminalWithTmux` callback becomes async as part of the same migration.

Why:

- The current sync `Bool` launch API cannot produce checked failure results without either lying or blocking the UI thread.
- `TerminalLauncher.runBashScriptWithResult(...)` already gives us the right execution primitive off the main actor.
- Option 2 needs checked launch behavior as much as checked focus behavior.

Rejected alternatives:

- Keep the sync fire-and-forget launch API. That preserves the exact blind spot we are trying to remove.
- Block the main actor waiting for shell exit. Unacceptable for a user-triggered launch path with built-in delays.

Consequences:

- `TerminalActivationCoordinator.runActivationFlow(...)` will take an async launch closure.
- `TerminalScripts.launchWithCommand(...)` stays synchronous because it only builds a reusable shell script for project creation and resume.
- Tests must cover both the async runtime launch path and the script-builder path.
