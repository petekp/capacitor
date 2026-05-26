# Status Projection Hardening - 2026-05-25

## Scope

This pass hardens the visible Ready/Idle behavior for live Claude Code cockpits while preserving the current Swift/Rust boundary:

- Rust keeps owning durable runtime ingest, reduce, query, and persisted snapshots.
- Swift keeps owning deterministic UI projection and stabilization after snapshot reads.
- Claude Code, Ghostty, tmux, project roots, and batch worktrees remain the only live worker/cockpit scope for this slice.

## Source-Backed Findings

- `core/capacitor-core/src/reduce/gc.rs` intentionally transitions sessions to `Idle` after signal absence and marks `gc_reason = "signal_absence"`. This is a durable safety net for missing hook/shell signals.
- The live process table still showed Claude Code processes for Work Batch cockpits and manual project-root sessions whose runtime snapshot rows had already become `idle`, often with `pid = 0`.
- `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` is the correct place to project durable runtime state plus live process evidence into card state.
- `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift` already uses process evidence to keep Work Batch bindings honest when Rust runtime liveness has gone stale.

## Implemented Policy

| Scenario | Expected behavior | Implementation |
|---|---|---|
| Runtime project is `idle`, but a Claude process is still alive inside the project root or batch worktree | Project card shows `Ready` | `SessionStateManager` promotes `idle` to `ready` using live Claude process evidence |
| No runtime project state exists yet, but a manual Claude process is alive inside a registered project | Project card shows synthetic `Ready` without inventing durable Rust state | `SessionStateManager` creates a view-only Ready state from live process evidence |
| Claude process is inside a nested project under a broader registered parent | Attribute the process to the deepest matching project | `WorkBatchClaudeProcessScanner.processEvidenceByProjectPath` assigns by deepest path |
| Completed Work Batch still has its assigned Claude cockpit alive | Batch row shows `Ready`, binding remains `done` | `WorkBatchBindingReconciler.markDoneIfUseful` uses `ready` when exact cockpit evidence is live |
| Completed Work Batch has no assigned live cockpit | Batch row remains `Idle` | Existing done cleanup path stays idle without live cockpit evidence |
| Pending checkpoint exists, even if the task is marked done | Batch stays `Waiting` | Existing checkpoint-first branch remains ahead of done cleanup |
| Duplicate cockpit exists while work is open | Batch stays `Waiting` with duplicate issue | Existing duplicate issue behavior remains |
| Duplicate/old cockpit exists after every task is done | Batch is not pulled back into Needs You | Done branch still suppresses duplicate escalation for completed work |

## Automated Verification

Command:

```bash
swift test --package-path apps/swift --filter 'WorkBatchClaudeProcessScannerTests|SessionStateManagerTests|RuntimeSnapshotApplicatorTests|WorkBatchBindingReconcilerTests'
```

Result:

- 59 tests passed.
- Added coverage for live process evidence, deepest-project attribution, runtime applicator wiring, synthetic Ready state, and completed Work Batch Ready state.

Additional command:

```bash
swift test --package-path apps/swift --filter 'TerminalActivationCoordinatorTests|TerminalLauncherTests|GhosttyAutomationClientTests|GhosttyTerminalDriverTests|AppStateWorkBatchOpenTests|WorkBatchAutoRouterTests|WorkBatchTaskSessionTests|WorkBatchDeliveryPolicyTests|WorkBatchOpenActionResolverTests|WorkBatchStateTests|ProjectOrderingTests|OperatorFieldOfWorkProjectionTests|ProjectCardContextLineResolverTests|DockProjectCardPresentationTests'
```

Result:

- 208 tests passed.
- This covered the activation state machine, Ghostty/tmux resolution, Work Batch routing, checkpoint opening, delivery policy, and card presentation projections.

Full Swift command:

```bash
swift test --package-path apps/swift
```

Result after correcting the stale completed-batch expectation:

- 904 tests executed.
- 1 test skipped.
- 0 failures.
- The stale expectation was in `AppStateRuntimeSnapshotEffectTests`: completed Work Batch plus live assigned cockpit now expects `ready`, not `idle`.

Diff hygiene:

- `git diff --check -- <status-projection files>` passed.
- Repository-wide `git diff --check` is still blocked by pre-existing trailing whitespace in `.claude/dead-code-report.md`, which predates this pass and was not touched here.

## Manual Verification Plan

After rebuilding and relaunching Capacitor Debug:

1. Confirm `scripts/dev/check-terminal-activation-state.sh` shows live Claude processes for project-root and Work Batch sessions.
2. Confirm the corresponding project cards show `Ready` instead of `Idle`.
3. Confirm completed Work Batch rows with live assigned cockpits show `Ready`.
4. Click a project card with a live root Claude session and verify it foregrounds the existing cockpit.
5. Click a Work Batch row with a live assigned cockpit and verify it re-enters that cockpit without launching a new Ghostty window.
6. Confirm app logs include the normal runtime snapshot apply line and no new activation ambiguity.

## Manual Verification Result

Commands:

```bash
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh
tail -n 120 ~/.capacitor/runtime/app-debug.log
jq '.batches[] | {id,name,status,current_activity_summary,task_ids}' ~/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/state.json
jq '.batches[] | {id,name,status,current_activity_summary,task_ids}' ~/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fparable-school/work-batches/state.json
```

Observed:

- Capacitor Debug relaunched as `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor`.
- Live Claude process evidence existed for:
  - `arc-design-studio` root/manual and Work Batch sessions.
  - `parable-school` Work Batch sessions.
  - `pete-2025` root/manual session.
- `SessionStateManager.merge` projected:
  - `arc-design-studio state=ready`
  - `parable-school state=ready`
  - `pete-2025 state=ready`
  - `capacitor state=idle`
  - `capacitor-circuit state=idle`
- `ProjectCardView` logs showed:
  - `parable-school:Ready`
  - `arc-design-studio:Ready`
  - `pete-2025:Ready`
- `ActiveProjectResolver.claudeSessions` selected only the Ready Claude-backed projects.
- Work Batch state files showed completed live batches as `ready`, including:
  - `Mobile Prototype Polish`
  - `Verification & Routing Docs`
  - `Typography scale adjustment`
  - `Typeface unification from source parable`

Manual UI limitation:

- After the final `./scripts/dev/restart-alpha-stable.sh --swift-only`, Capacitor Debug relaunched as pid `78357`.
- Computer Use still could not attach to the Capacitor Debug window (`cgWindowNotFound`).
- System Events could not enumerate the app windows, but CoreGraphics did see onscreen Capacitor Debug and Ghostty windows.
- A full-screen screenshot after `caffeinate -u -t 2` showed the macOS lock screen, and CoreGraphics showed `loginwindow` layer `2004` above the app windows.
- Because the desktop is locked, this pass verifies live process projection and persisted Work Batch behavior through tests, app logs, process state, CoreGraphics window evidence, and state files, but does not claim a fresh physical card-click verification.

Blocking manual scenario:

Physical verification remains blocked until the desktop is unlocked:

1. Click a project card with a live root Claude session and verify it foregrounds the existing cockpit.
2. Click a Work Batch row with a live assigned cockpit and verify it re-enters that cockpit without launching a new Ghostty window.
3. Click a checkpoint row and verify it opens the decision surface instead of blindly jumping to the cockpit.

Repeat manual attempt:

- A later continuation rechecked the running app and found Capacitor Debug still alive as pid `78357`.
- CoreGraphics still reported onscreen Capacitor Debug and Ghostty windows, but also reported `loginwindow` layer `2004` covering the screen.
- `screencapture -x /tmp/capacitor-locked-screen-repeat.png` succeeded and produced a `3024 x 1964` screenshot of the locked display.
- The physical project-card, Work Batch row, and checkpoint-row click checks remain unverified for the same reason: the desktop is locked.

Third blocker confirmation:

- A subsequent continuation again found Capacitor Debug alive as pid `78357`.
- CoreGraphics again reported `loginwindow` layer `2004` above Capacitor Debug and Ghostty windows.
- `screencapture -x /tmp/capacitor-lock-check-third.png` produced a `3024 x 1964` locked-display screenshot.
- This is the third consecutive goal turn blocked by the same external desktop-lock condition, so the remaining physical click verification cannot be completed autonomously from the current state.

Resume attempt after `execute`:

- Re-ran focused Swift coverage for the Work Batch, Ready projection, checkpoint open, Ghostty, and activation coordinator slice:

```bash
swift test --package-path apps/swift --filter 'WorkBatchClaudeProcessScannerTests|SessionStateManagerTests|RuntimeSnapshotApplicatorTests|WorkBatchBindingReconcilerTests|TerminalActivationCoordinatorTests|AppStateWorkBatchOpenTests|GhosttyTerminalDriverTests|GhosttyAutomationClientTests'
```

Result:

- 96 tests passed.
- 0 failures.

- Rebuilt and relaunched Capacitor Debug with:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Observed:

- Capacitor Debug relaunched from `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor` as pid `11065`.
- The runtime service relaunched from the matching app bundle as pid `11148`.
- `scripts/dev/check-terminal-activation-state.sh` still reported one Capacitor Debug process and no release Capacitor process.
- Live Claude process evidence still included the existing Work Batch and manual sessions for `arc-design-studio`, `parable-school`, and `pete-2025`.
- App logs again projected active Claude-backed projects as Ready:
  - `/Users/petepetrash/Code/ever/arc-design-studio state=ready`
  - `/Users/petepetrash/Code/parable-school state=ready`
  - `/Users/petepetrash/Code/pete-2025 state=ready`
- `ProjectCardView` logs again showed:
  - `parable-school:Ready`
  - `arc-design-studio:Ready`
  - `pete-2025:Ready`

- Re-ran full Swift verification:

```bash
swift test --package-path apps/swift
```

Result:

- 904 tests executed.
- 1 test skipped.
- 0 failures.

- Re-ran the structural ownership check:

```bash
./scripts/verify/verify.sh --layers 1
```

Result:

- Exit code `0`.
- No ownership/boundary violations were reported.

Manual UI limitation remains:

- Computer Use still cannot attach to the Capacitor Debug window (`cgWindowNotFound`).
- System Events still reports `Capacitor Debug` as visible but with `0` windows.
- A fresh full-screen screenshot still shows the macOS lock screen rather than Capacitor:
  - `docs/circuit/proofs/operator-product-loop/status-projection-hardening-live-blocked-2026-05-25T2342.png`
- The live project-card, Work Batch row, and checkpoint-row click checks remain unverified for this resumed attempt.
