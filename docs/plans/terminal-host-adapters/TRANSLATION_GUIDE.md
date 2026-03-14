# Translation Guide

## Old -> New

| Old pattern | New pattern |
|---|---|
| `ScriptedTerminalDriver(app: .iTerm)` | `ITermTerminalDriver` |
| `ScriptedTerminalDriver(app: .terminal)` | `TerminalAppTerminalDriver` |
| `TerminalActivationFailureReason` declared inside `GhosttyAutomationClient.swift` | terminal-neutral failure type declared in a host-and-Ghostty activation model file |
| `focusTerminalTabByTty(...) -> Bool` | per-app checked focus method that returns match, no-match, or typed failure |
| `launch(...) -> Bool` fire-and-forget | `launch(...) async -> Bool` with checked shell exit and typed failure mapping |
| Ghostty-specific fallback toast copy | generic fallback toast plus terminal-aware `userMessage` when a typed reason exists |
| `[ScriptedTerminalDriver] ...` logs | `[ITermTerminalDriver] ...` and `[TerminalAppTerminalDriver] ...` |

## Gotchas

- Do not replace `ScriptedTerminalDriver` with another generic host runtime owner that merely has a different name.
- Keep shared host helpers pure. It is fine to share escaping, `open -b` script construction, and AppleScript output parsing. It is not fine to centralize app-specific behavior again.
- A focus script returning `false` is not the same as AppleScript execution failure. `false` means no match and should drive `.relaunchNeeded`; execution failure should drive `.failed(reason)`.
- Checked launch cannot block the main actor because the host scripts intentionally sleep before sending input.
- `TerminalScripts.launchWithCommand(...)` is a second consumer of host launch construction. The migration is incomplete if the live drivers are split but the resume path still depends on a generic bucket.
- Ghostty remains the reference quality bar, not the host-terminal abstraction target.

## Before / After Examples

### Host focus

- Before: `ScriptedTerminalDriver.focus(...)` tries `runBoolean`, collapses any non-match into `relaunchNeeded`, and logs with a shared label.
- After: `ITermTerminalDriver.focus(...)` and `TerminalAppTerminalDriver.focus(...)` each own their AppleScript, distinguish `matched` from `execution failed`, and log with app-specific labels.

### Host launch

- Before: `ScriptedTerminalDriver.launch(...)` fires `open -b` and a delayed `System Events` keystroke script, then always returns `true`.
- After: each concrete host driver executes the same high-level strategy through a checked async shell runner and maps shell failure into `TerminalActivationFailureReason.hostOperationFailed(...)`.

### Failure copy

- Before: `AppState` falls back to `Couldn’t activate Ghostty.` when the coordinator reports no typed failure reason.
- After: `AppState` falls back to `Couldn’t activate terminal.` and uses typed `userMessage` for Ghostty, iTerm, and Terminal.app failures.
