# Terminal Session Resolution Hardening

Date: 2026-05-25 20:53 PDT

## Goal

Clicking a Project card or Work Batch card should re-enter the intended existing Claude Code cockpit before launching anything new. The user should not need to understand Ghostty, tmux, duplicate Claude processes, or stale bindings.

## Source-Backed Findings

- Rust/runtime remains the ingest and routing fact boundary; Swift owns deterministic projection and macOS side effects. This matches the architecture split in `.claude/docs/architecture-primer.md`.
- Project-card primary behavior checks Work Batch projection before falling back to legacy terminal launch in `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`.
- Work Batch project-card resolution is conservative: checkpoint batch first, one active bound batch opens, ambiguous multiple batches show Project Detail, no batches falls back to legacy launch in `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift`.
- `TerminalActivationCoordinator` now has a distinct `.alreadySelected` result. With no matching tmux client, this prevents a needless new terminal launch; with a tmux client, it still switches and focuses the client path (`TerminalActivationCoordinator.swift:28-83`).
- `GhosttyTerminalDriver` now treats direct CWD matches as already selected only when the matching tab is in Ghostty's front window. A selected tab in a background single-tab window is focused instead (`TerminalDrivers.swift:70-84`).
- `TerminalLauncher.focusExistingTerminal` treats `.focused` and `.alreadySelected` as success, so Work Batch cockpit re-entry does not resume Claude when a visible session is enough (`TerminalLauncher.swift:183-201`).
- Work Batch rows now make the visible row surface a single tap target when no checkpoint form is open, so users can click the card-shaped row rather than a tiny terminal glyph, while checkpoint rows keep their explicit controls (`WorkBatchListSection.swift:57-75`, `WorkBatchListSection.swift:103-110`).
- The dev restart script now labels the repo-built app as `Capacitor Debug`, avoiding accidental manual testing against `/Applications/Capacitor.app` (`scripts/dev/restart-app.sh:214-223`).

## Failure-Mode Ledger

| Failure mode | Intended behavior | Status |
| --- | --- | --- |
| Installed release app and repo debug app both named `Capacitor` | Debug workflow must expose the repo build as a distinct app target | Fixed by `Capacitor Debug` bundle metadata |
| Selected CWD match is in a background Ghostty single-tab window | Focus that existing window; do not call it already selected | Fixed and covered by `testDirectFocusFocusesSelectedCwdMatchInBackgroundWindow` |
| Selected CWD match is in Ghostty's front window and no tmux client matches | Treat as success; do not spawn a new tmux attach window | Fixed and covered by direct-focus/coordinator tests |
| Selected CWD match has a tmux client available | Switch/focus through tmux; do not let direct selected state mask tmux routing | Covered by `testActivationFlowStillSwitchesWhenAlreadySelectedDirectMatchHasTmuxClient` |
| Duplicate Claude processes share the assigned Work Batch session ID | Re-enter the existing cockpit; do not start another resume | Covered by Work Batch open-cockpit tests |
| Different Claude session IDs exist in the same batch worktree | Block and explain ambiguity instead of guessing | Existing duplicate-cockpit policy preserved |
| Work Batch row click lands outside the small text/icon button | Card-shaped row should open the Work Batch unless a checkpoint form is visible | Fixed by row-level tap target |
| Runtime shell routing snapshot is empty | Use Ghostty/process evidence before launching | Preserved by direct focus before tmux launch |

## Long-Term Model

The right model is ordered evidence, not generic session guessing:

1. Work Batch binding and batch worktree are the strongest identity.
2. Visible Ghostty terminal/worktree match is the preferred re-entry surface.
3. tmux client/session routing is the fallback for project-root/manual sessions.
4. Launch is last resort when no existing cockpit can be defended.

This keeps the current Swift/Rust boundary intact: Rust/runtime can keep improving routing facts, while Swift owns the local Mac activation policy and observable user-facing behavior.

## Automated Verification

Passed:

```bash
swift test --package-path apps/swift --filter 'GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests|TmuxRouterTests|SessionResolutionPolicyTests|WorkBatchAutoRouterTests|WorkBatchBindingReconcilerTests|WorkBatchTaskSessionTests|WorkBatchProjectPrimaryActionResolverTests|AppStateWorkBatchOpenTests'
```

Result: 166 tests, 0 failures.

Passed after row hit-area and duplicate-open hardening:

```bash
swift test --package-path apps/swift --filter 'GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests|WorkBatchAutoRouterTests|WorkBatchTaskSessionTests|AppStateWorkBatchOpenTests'
```

Result: 110 tests, 0 failures.

## Manual Verification

Environment:

- App under test: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`
- Bundle ID: `com.capacitor.app.debug`
- Installed release app was not running during final verification.
- Starting Ghostty windows: 4
- Starting Claude process count: 12

Checks:

1. Opened `parable-school` Project Detail from the debug app.
2. Forced a different Ghostty window, `Mobile Prototype Polish`, to be Ghostty's front window.
3. Activated Capacitor Debug and clicked the `Typeface unification from source parable` Work Batch row body.
4. Observed Ghostty front window changed back to `Typeface unification from source parable`.
5. Observed Ghostty became the frontmost app.
6. Confirmed Ghostty window count remained 4.
7. Confirmed Claude process count remained 12.
8. Repeated via the `parable-school` Project card `Open in Terminal` action.
9. Observed the same result: Ghostty front window `Typeface unification from source parable`, Ghostty frontmost, 4 Ghostty windows, 12 Claude processes, tmux client still `/dev/ttys000|parable-school`.

## Acceptance

- No new Ghostty window was launched for the tested Work Batch re-entry path.
- No new Claude process was launched for the tested Work Batch re-entry path.
- The correct existing Work Batch cockpit became the active Ghostty window.
- The debug/release app ambiguity is removed for future manual tests.
