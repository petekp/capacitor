# Terminal Host Adapters Audit

## Method

- Re-opened the Option 2 architecture note and validated it against the live Swift activation code.
- Inspected the current host-terminal driver boundary, launcher, coordinator, AppState toast surface, Ghostty failure model, UX spec, and manual QA evidence.
- Measured the remaining shared-host-driver debt with `rg` against active source, tests, and current docs.
- Compared the host-terminal coverage shape against the dedicated Ghostty driver test surface to choose the migration target.

## Initial Metrics

| Pattern | Count | Why It Is Debt |
|---|---:|---|
| `ScriptedTerminalDriver` references in active source, tests, and current docs | 7 | iTerm and Terminal.app still share one runtime owner |
| `\[ScriptedTerminalDriver\]` log labels in active source, tests, and current docs | 2 | logs and live evidence still identify the shared bucket instead of the terminal app |
| `case .iTerm` or `case .terminal` branches inside `TerminalDrivers.swift` | 5 | app-specific behavior still accumulates inside a generic driver |
| `Couldn’t activate Ghostty.` fallback copy | 1 | non-Ghostty failures can still surface misleading UX |
| dedicated iTerm or Terminal.app driver test files | 0 | there is no per-app behavior guard equivalent to `GhosttyTerminalDriverTests.swift` |
| host launch-script assertions in `TerminalLauncherTests.swift` | 2 | current host coverage proves only script text, not focus or failure behavior |

## Current Metrics

| Pattern | Count | Why It Matters |
|---|---:|---|
| `ScriptedTerminalDriver` references in active source, tests, and current docs | 0 | the shared host driver is fully deleted |
| `\[ScriptedTerminalDriver\]` log labels in active source, tests, and current docs | 0 | log ownership is now app-specific |
| combined `case .iTerm, .terminal` shared-host branch | 0 | host-terminal behavior is no longer grouped into one branch |
| `Couldn’t activate Ghostty.` fallback copy in active source and current docs | 0 | non-Ghostty failures no longer imply Ghostty |
| dedicated iTerm driver test files | 1 | `ITermTerminalDriverTests.swift` now guards iTerm focus and launch behavior |
| dedicated Terminal.app driver test files | 1 | `TerminalAppTerminalDriverTests.swift` now guards Terminal.app focus and launch behavior |

## Leverage Assessment

- High leverage:
  - `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
- Medium leverage:
  - `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift`
  - `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
  - `apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift`
  - `.claude/docs/terminal-activation-ux-spec.md`
  - `docs/ARCHITECTURE.md`
- Low leverage or historical context:
  - `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`
  - `docs/plans/terminal-routing-foundation/*`

## Hard Conclusions

- The shared host driver is the real remaining asymmetry. Route derivation and activation coordination are already in acceptable shape.
- Separate concrete `TerminalDriver` implementations are the right Option 2 landing zone. Adding sub-clients beneath another shared host driver would preserve the ownership problem with more indirection.
- `TerminalActivationFailureReason` can no longer live as a Ghostty-specific type inside `GhosttyAutomationClient.swift`. The host adapters need the same typed path to UI copy and test assertions.
- Checked host launch needs an async boundary. Any plan that keeps `launch(...)` synchronous either lies about success again or blocks the main actor during the intentional launch delay.
- Shared code is still worth keeping, but only as pure helpers. The migration should aggressively reject a second generic host-behavior bucket.
- Manual QA remains part of the ship gate because AppleScript and `System Events` behavior is partly environment-dependent.

## Implementation Status

- `HSTA-01` is complete.
- `HSTA-02` is complete.
- `HSTA-03` is partially complete: docs and automated verification are done; fresh live host-terminal proof is still pending.

## Validation Spikes

| Spike | Question Answered | Cost | Success Signal | Failure Signal |
|---|---|---:|---|---|
| Async checked host launch spike | Can the host launch path wait for shell exit without blocking the UI thread? | Low | `launch(...) async` uses `runBashScriptWithResult(...)` and driver tests prove deterministic success or failure | The coordinator or launcher must block the main actor to observe launch exit |
| Per-app adapter skeleton spike | Is the concrete-driver split small and coherent in the current code? | Low | `ITermTerminalDriver` and `TerminalAppTerminalDriver` compile cleanly and shrink registry ambiguity immediately | The split only creates wrapper types while behavior still lives in shared branches |
| Failure-copy spike | Can the UI stop implying Ghostty for nil or host-terminal failures? | Very Low | A small AppState regression test proves the generic fallback and host-specific `userMessage` flow | AppState still needs to guess the app because failures arrive untyped |

## Proposed Slice Order

- `HSTA-01`: generalized failure model plus iTerm extraction
- `HSTA-02`: Terminal.app extraction plus shared-driver deletion
- `HSTA-03`: docs, live proof, and final convergence
