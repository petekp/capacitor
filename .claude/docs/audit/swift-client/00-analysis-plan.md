# Swift Client Exhaustive Analysis Plan

## Scope
`apps/swift/Sources/Capacitor` and `apps/swift/Tests/CapacitorTests`.

## Known-Issues Sweep
- Checked `CLAUDE.md` + `.claude/docs/gotchas.md` for existing caveats.
- Searched Swift code for `TODO|FIXME|HACK` markers.
- Reviewed recent Swift commit history for fragile areas.
- Ran test baseline:
  - `cd apps/swift && swift test --filter SessionStateManagerTests --skip-build`
  - Result on March 5, 2026: 4 failures in `SessionStateManagerTests` tied to stale working-state expectations.

## Subsystem Decomposition
| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Runtime Snapshot Ingestion & State Resolution | `Models/AppState.swift`, `Models/SessionStateManager.swift`, `Models/RuntimeClient.swift`, `Models/ActiveProjectResolver.swift` | Timer-driven polling, FFI snapshot reads, UI state mutation | High |
| 2 | Terminal Activation & Process Execution | `Models/TerminalLauncher.swift` | Subprocess spawn, AppleScript, tmux shell execution | High |
| 3 | Project Creation & Drop Ingestion | `Models/AppState.swift`, `Models/ProjectIngestionWorker.swift` | File I/O, async polling, drag-drop ingestion, status persistence | High |
| 4 | Setup / Onboarding Reliability | `Models/SetupRequirements.swift`, `Views/Setup/WelcomeView.swift`, `App.swift` | Runtime bootstrap, blocking user entry path | High |
| 5 | Hook Server Lifecycle | `Models/HookServerManager.swift` | Process lifecycle, HTTP health checks, restart behavior | High |
| 6 | Test Correctness & Regression Coverage | `Tests/CapacitorTests/*` | Reliability of CI safety net | Medium |

## Method
- Read each subsystem line-by-line.
- Cross-check comments against behavior.
- Verify concurrency, cancellation, and lifecycle transitions.
- Consolidate into severity-ranked findings with concrete fixes.
