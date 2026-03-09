# True Ending Audit

Date: 2026-03-08
Status: closed through `TE-406`

This audit starts the finish-line tranche after convergence (`RW-200` through `RW-206`) and namespace purity (`NP-300` through `NP-303`).

## Mission

Finish the repo cleanup by deleting the remaining misleading residue: stale historical checkpoint guidance, the last accidental Swift `Models/` subtree, and the live reliability debt that was previously hidden behind stale path-based ratchets.

## Method

- Re-read the existing architecture control plane in `architecture/`.
- Ran `scripts/architecture/check_architecture_guards.sh --status`.
- Re-ran the retargeted `scripts/ci/runtime-reliability-guard.sh --status`.
- Enumerated the remaining Swift files under `apps/swift/Sources/Capacitor/Models/`.
- Counted actionable historical-checkpoint `TODO (user-run)` rows.
- Measured the remaining nonzero reliability budgets that still point at live Swift files.
- Counted the remaining collaborator-registry surface on `Composition/AppState.swift`.

## Measured Finish-Line Debt

Measured on March 8, 2026 after `NP-303`.

| Pattern | Current count | Why it matters | Ratchet |
| --- | ---: | --- | --- |
| nested Swift files under `apps/swift/Sources/Capacitor/Models/WindowAnchoring` | 0 | final accidental `Models/` subtree after the top-level budget reached zero | frozen at `0` |
| `TODO (user-run)` rows in historical checkpoint docs | 0 | archived docs no longer look like live operational guidance | frozen at `0` |
| `HookServerManager.waitUntilExit()` | 0 | live startup/lifecycle code no longer blocks synchronously during process discovery | frozen at `0` |
| `ProjectDetailsManager.waitUntilExit()` | 0 | project-details workflows no longer use synchronous subprocess waits | frozen at `0` |
| `TerminalLauncher.outputData.append(...)` | 0 | terminal subprocess I/O no longer depends on manual append-based buffering | frozen at `0` |
| `AppState dragdrop group.leave` budget | 0 | ratchet now matches live code instead of a stale allowance | frozen at `0` |
| collaborator/service-registry fields on `Composition/AppState.swift` | 27 | outer shell state still exposes a broad collaborator graph to views/tests | measure now; decide whether to ratchet after the finish-line ownership decision |

## Inventory and Leverage

### High leverage

- `apps/swift/Sources/Capacitor/Support/HookServerManager.swift`
  Why: one real live blocking wait remains in startup/lifecycle code, and the reliability guard now reports it honestly.
- `apps/swift/Sources/Capacitor/Models/WindowAnchoring/*`
  Why: this is the last accidental Swift `Models/` residency.
- `docs/audit/ARCHITECTURE_CHECKPOINT_2026-03-06.md`
  Why: still contains unexecuted manual smoke TODOs and deleted-path historical residue.
- `docs/audit/ARCHITECTURE_CHECKPOINT_2026-03-07.md`
  Why: still reads like live guidance even though the tranche it described has been superseded.

### Medium leverage

- `apps/swift/Sources/Capacitor/Application/Projects/ProjectDetailsManager.swift`
  Why: live blocking waits remain, but the subsystem is less central than startup/runtime.
- `apps/swift/Sources/Capacitor/Composition/AppState.swift`
  Why: no longer transition debt, but still a broad collaborator registry that may or may not deserve further shrinkage.
- `scripts/ci/runtime-reliability-guard.sh`
  Why: now truthful again, but still carries nonzero budgets that define the final reliability cleanup queue.

### Low leverage

- `docs/audit/SUMMARY.md`
- `docs/audit/ARCHITECTURE_CHECKPOINT_2026-03-08.md`
- `architecture/HANDOFF.md`

These files are important for clarity, but they follow the real cleanup slices rather than drive them.

## Hard Conclusions

1. The big migration is done. The remaining work is finish-line hygiene and reliability truthfulness, not architectural rescue.
2. The last Swift namespace debt is a small support-infrastructure subtree. It should be deleted as debt, not debated as architecture.
3. The March 6/7 checkpoints are now harmful in their current form because they contain actionable-looking TODO tables even though they are only history.
4. The retargeted reliability guard revealed one real live startup debt in `HookServerManager` instead of silently checking deleted files. That is progress, but it means the finish line still includes real behavior work.
5. `Composition/AppState.swift` is no longer a god object, but it is still broad enough that we should make an explicit finish-line decision about whether its service-registry surface is intentional or residual complexity.

## Proposed Slices

### TE-400: True Ending Audit + Ratchet Reset
Status: completed.

Outcome:

- keep the existing control plane authoritative
- record the remaining finish-line debt
- freeze the next cleanup surfaces with truthful ratchets

### TE-401: Historical Checkpoint Quarantine

Outcome:

- convert the March 6/7 checkpoints into explicit archive material
- remove `TODO (user-run)` residue from historical docs
- keep the summary index truthful

Status: completed.

Closed state after TE-401:

- historical checkpoint `TODO (user-run)` rows are now `0`
- the March 6 and March 7 checkpoints remain in the tree only as archived stubs
- current checkpoint readers are redirected to the March 8 checkpoint and this finish-line audit

### TE-402: Window Anchoring Rehome

Outcome:

- move the nested `Models/WindowAnchoring/*` subtree into `Support/WindowAnchoring/*`
- reduce residual Swift `Models/` residency to zero

Status: completed.

Closed state after TE-402:

- nested `Models/WindowAnchoring/*.swift` count is now `0`
- window anchoring support types now live under `Support/WindowAnchoring/*`
- the old `Models/WindowAnchoring/*` paths are frozen at zero

### TE-403: Hook Server Startup Probe Deblocking

Outcome:

- remove the live `HookServerManager.waitUntilExit()` startup/process-discovery block
- drive that ratchet from `1` to `0`

Status: completed.

Closed state after TE-403:

- `HookServerManager.waitUntilExit()` count is now `0`
- live-server discovery now completes through an async termination callback instead of a synchronous wait
- tests cover late-probe stop dominance, delayed live-server adoption, and the fresh-launch fallback path

### TE-404: Project Details Process Cleanup

Outcome:

- remove the remaining `ProjectDetailsManager.waitUntilExit()` calls
- remove the manual `TerminalLauncher.outputData.append(...)` buffering path
- remove the remaining `WorktreeService.waitUntilExit()` call
- keep observable ordering and watcher behavior stable

Status: completed.

Closed state after TE-404:

- `ProjectDetailsManager.waitUntilExit()` count is now `0`
- `TerminalLauncher.outputData.append(...)` count is now `0`
- `WorktreeService.waitUntilExit()` count is now `0`
- git sensemaking now uses async command execution, terminal script output is file-backed rather than append-buffered, and worktree git execution no longer uses `waitUntilExit()`

### TE-405: AppState Surface Decision

Outcome:

- decide whether the remaining `AppState` collaborator graph is intentional shell state or still finish-line complexity debt
- if it is debt, shrink it with explicit ownership boundaries rather than ad hoc cleanup

Status: completed.

Closed state after TE-405:

- the remaining `AppState` collaborator surface is explicitly accepted as intentional SwiftUI shell-environment access
- finish-line cleanup does not require splitting `AppState` further unless it resumes owning policy or construction

### TE-406: Architecture End-State Decision

Outcome:

- explicitly decide whether `architecture/` remains permanent governance or is archived as migration history
- close the finish-line tranche truthfully

Status: completed.

Closed state after TE-406:

- `architecture/` remains the permanent architecture-governance surface
- the finish-line tranche is complete with no pending slices in the control plane
