# Capacitor Preview Work Batch Integration Spec

Status: implementation spec
Date: 2026-05-27
Scope: Capacitor-only macOS preview wiring for Work Batch cards

## Bottom Line

Wire the current `Capacitor Preview` macOS proof into Work Batch cards as a
small, explicit preview affordance.

The user experience should be:

```text
I add Tasks.
Capacitor routes and runs them in a Work Batch.
When I want to check visual/native app work, the Work Batch card can build and
open the exact preview app for that batch worktree.
I do not need to rebuild manually or understand terminal/session plumbing.
```

This slice is deliberately narrow. It supports the Capacitor app only, macOS
only, and the current fixed preview identity:

```text
Capacitor Preview
com.capacitor.app.preview
```

It must not introduce a generic preview provider, web preview support, a runner,
a flow engine, task DAG behavior, a new terminal/editor, the old Circuit
runtime, or SaaS framing.

## Source-Backed Current State

### Work Batch card surface

- `WorkBatchListSection` renders each batch row from a `WorkBatchProjection`
  and currently accepts actions for opening the row, opening the cockpit,
  unresolving completed Tasks, and answering checkpoints
  (`apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift:3`).
- The row already separates the batch summary click from the terminal/cockpit
  icon (`WorkBatchListSection.swift:54`, `WorkBatchListSection.swift:125`).
  Preview should use the same pattern: a small secondary affordance, not a hidden
  side effect of the card click.
- Pending checkpoints are rendered inside the row and answered from Project
  Detail (`WorkBatchListSection.swift:70`, `WorkBatchListSection.swift:133`).
  Checkpoints must stay higher priority than preview.
- Task rows already show a done correction affordance via `onUnresolve`
  (`WorkBatchListSection.swift:223`). Preview failure should not create a new
  correction model in this slice.

### Work Batch state and projection

- `WorkBatchStatus` currently models `ready`, `working`, `waiting`,
  `compacting`, and `idle`, and maps those into card/session visuals
  (`apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:3`).
- `WorkBatchTaskStatus` currently models `queued`, `working`, `needs_you`, and
  `done` (`WorkBatchState.swift:41`).
- `WorkBatchRecord` has batch identity, project path, status, summary, task IDs,
  optional cockpit binding ID, and timestamps. It has no preview field
  (`WorkBatchState.swift:88`).
- `WorkBatchStateSnapshot` stores batches, tasks, classifications,
  checkpoints, and delivery records. It has no preview records today
  (`WorkBatchState.swift:254`).
- `WorkBatchStateStore` persists state under the project data directory in
  `~/.capacitor/projects/.../work-batches/state.json`
  (`WorkBatchState.swift:386`, `WorkBatchState.swift:403`).
- `WorkBatchProjection` is the view-facing shape and currently includes batch
  identity, status, queued count, current summary, tasks, checkpoints, and
  cockpit binding (`WorkBatchState.swift:428`).
- `WorkBatchProjectionBuilder` sorts batches by attention priority and merges
  tasks, checkpoints, and bindings into projections (`WorkBatchState.swift:575`).

### Work Batch action behavior

- `AppState.workBatches(for:)` obtains projections from `WorkBatchAutoRouter`
  (`apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:526`).
- `openWorkBatch` is checkpoint-first. If a pending checkpoint exists, Capacitor
  navigates to Project Detail and focuses the checkpoint instead of opening the
  cockpit (`AppState+Projects.swift:546`).
- If no checkpoint is pending, the card opens the cockpit or starts an unbound
  batch session (`AppState+Projects.swift:576`).
- The explicit cockpit action already errors honestly when no binding exists
  (`AppState+Projects.swift:639`).
- `WorkBatchOpenActionResolverTests` already assert that pending checkpoints win
  before cockpit opening (`apps/swift/Tests/CapacitorTests/WorkBatchOpenActionResolverTests.swift:6`).

### Work Batch worktree and agent context

- Managed batch worktrees live under `.capacitor/worktrees/<name>`
  (`apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift:151`).
- `WorkBatchCockpitBinding` records the batch ID, project path, worktree path,
  Claude Code session ID, host, status, and timestamps
  (`apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:22`).
- `WorkBatchContextMirror` writes `.capacitor/work-batch-context.md` into the
  batch worktree and records the batch/task context plus claim, Done, and
  checkpoint artifact paths (`WorkBatchTaskSession.swift:119`).
- Done reports currently include `task_id`, `status`, `summary`, `evidence`,
  and `completed_at`, with no structured preview field
  (`apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:93`).

### Current macOS preview proof

- `MacOSPreviewWorkStatus` already has the exact four proof-backed states this
  slice needs:
  `preview_building`, `ready_to_inspect`, `preview_failed`, and
  `preview_unavailable`
  (`apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift:4`).
- `MacOSPreviewWorkProof` records status, app path, bundle ID, display name,
  pid, launch time, worktree path, git head, dirty state, build command, build
  log path, expected identity, failure reason, and timestamp
  (`apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift:29`).
- `MacOSPreviewWorkRequest.capacitorPreview` is hardcoded to the Capacitor app,
  `apps/swift/CapacitorPreview.app`, `com.capacitor.app.preview`, and
  `Capacitor Preview`
  (`apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift:60`).
- `MacOSPreviewWorkCoordinator.run` writes a building proof, refuses to continue
  if the preview identity is already running, builds the app, checks the app
  bundle identity, launches by exact app path, verifies launched path and bundle
  ID, then writes a ready proof
  (`apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift:136`).
- The launcher uses `NSWorkspace.openApplication(at:)` with
  `createsNewApplicationInstance = true`
  (`apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift:560`).
- The debug menu currently exposes this only as `Build and Open Capacitor
  Preview` (`apps/swift/Sources/Capacitor/Debug/AppDebugSupport.swift:246`).
- The proof test suite covers command construction, real env-gated build/launch,
  identity mismatch, launched path mismatch, and already-running preview identity
  (`apps/swift/Tests/CapacitorTests/MacOSPreviewWorkProofTests.swift:8`,
  `MacOSPreviewWorkProofTests.swift:33`, `MacOSPreviewWorkProofTests.swift:60`,
  `MacOSPreviewWorkProofTests.swift:124`, `MacOSPreviewWorkProofTests.swift:170`,
  `MacOSPreviewWorkProofTests.swift:215`).

### Preview build script

- `scripts/dev/build-preview-app.sh` requires an explicit worktree path and
  produces a local Capacitor Preview app (`scripts/dev/build-preview-app.sh:17`).
- The script uses a stable preview bundle ID and display name by default
  (`build-preview-app.sh:6`).
- The output app path must be inside the worktree and must end in `.app`
  (`build-preview-app.sh:86`, `build-preview-app.sh:91`).
- The script writes preview-specific plist values including
  `CapacitorChannel=preview`, `CapacitorProfile=preview`, and disables Sparkle
  automatic checks (`build-preview-app.sh:280`).
- The script signs the helper and app before reporting the preview app path,
  bundle ID, and display name (`build-preview-app.sh:316`).

### Existing preview strategy docs

- `docs/circuit/preview-work-strategy.md` already frames Preview Work as a Work
  Batch result and launch layer backed by internal evidence, not a replacement
  for the batch session (`docs/circuit/preview-work-strategy.md:95`).
- The same doc names the unified user-facing states:
  `Preview unavailable`, `Preview not needed`, `Preview building`,
  `Ready to inspect`, and `Preview failed`
  (`docs/circuit/preview-work-strategy.md:250`).
- The macOS scenario ledger says the first native slice should build from the
  batch worktree, launch the exact app by path, and never present the root
  checkout, installed release app, or stale Debug app as preview
  (`docs/circuit/preview-work-macos-scenarios.md:24`).
- The ledger also says evidence is internal and users should see status, result,
  preview, risk, and action (`docs/circuit/preview-work-macos-scenarios.md:97`).

## UX Hypotheses To Test

1. Preview belongs on the Work Batch card, not in the Debug menu.
   Users should not need to know the preview proof exists.

2. Preview is secondary to task alignment.
   If a checkpoint is pending, clicking the main batch card should still open the
   checkpoint. Preview can be present, but it must not interrupt `Needs You`.

3. Preview should be explicit.
   Clicking the card should keep its current checkpoint/cockpit behavior. A small
   preview button or status/action row should build/open preview.

4. Preview evidence is internal.
   The card should not show build commands, raw logs, git hashes, or proof paths.
   It should show only compact labels such as `Preview available`,
   `Preview building`, `Ready to inspect`, `Preview failed`, or
   `Preview unavailable`.

5. No worktree means no batch preview yet.
   A batch-specific preview should use the batch worktree from the cockpit
   binding. If no binding/worktree exists, the preview control should be disabled
   with a plain reason such as `No batch worktree yet`.

6. One native preview identity is enough for this slice.
   The fixed `com.capacitor.app.preview` identity means Capacitor should support
   one active Capacitor Preview at a time. If another preview app with that
   identity is already running, the card should show `Preview already open` or
   `Preview failed`, not pretend it launched the selected batch preview.

7. Ready means identity-proven, not just build-succeeded.
   `Ready to inspect` appears only after Capacitor has verified app path, bundle
   ID, display name, pid, launch time, worktree path, and proof timestamp.

8. Preview failure does not mean Task failure.
   If preview build/launch fails, the Work Batch and Task statuses remain honest.
   The user can retry preview or open the cockpit.

## User-Facing Card States

Only Capacitor-capable batches show preview UI in this slice. Other projects
show no preview control.

| Internal status | Card copy | Preview action | Primary card click |
|---|---|---|---|
| no capability | none | none | checkpoint or cockpit |
| capability exists, no binding/worktree | `Preview unavailable` | disabled | checkpoint or cockpit/start |
| no proof yet | `Preview available` | `Open Preview` starts build | checkpoint or cockpit |
| `preview_building` | `Preview building` | disabled spinner/progress | checkpoint or cockpit |
| `ready_to_inspect` and matching preview app still running | `Ready to inspect` | foreground preview | checkpoint or cockpit |
| `ready_to_inspect` but preview app not running | `Preview available` | rebuild/open preview | checkpoint or cockpit |
| `preview_failed` | `Preview failed` | retry preview | checkpoint or cockpit |
| another fixed preview identity already running | `Preview already open` or `Preview unavailable` | foreground existing preview only if proof matches this batch; otherwise disabled/retry after close | checkpoint or cockpit |

The first implementation should prefer the less surprising behavior:

- A ready preview action should foreground the existing preview only when the
  stored proof matches the selected batch worktree and the running app path still
  matches the proof.
- If the running preview identity belongs to another worktree, do not foreground
  it as this batch's preview. Show a concise conflict.

## Internal Data Model

Add a Swift-owned preview state model. Do not add Rust persistence in this slice.

Rationale:

- Swift already owns macOS build/launch/window side effects.
- Existing Work Batch state and binding stores are Swift-owned JSON under
  `~/.capacitor/projects/.../work-batches`.
- Preview records are product/UI state for a macOS side effect, not core runtime
  reducer state yet.

Proposed files:

- `apps/swift/Sources/Capacitor/Models/WorkBatchPreviewState.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchPreviewStateTests.swift`

Proposed types:

```swift
enum WorkBatchPreviewStatus: String, Codable, Equatable {
    case previewUnavailable = "preview_unavailable"
    case previewAvailable = "preview_available"
    case previewBuilding = "preview_building"
    case readyToInspect = "ready_to_inspect"
    case previewFailed = "preview_failed"
}

struct WorkBatchPreviewRecord: Codable, Equatable, Identifiable {
    let id: String
    let batchID: String
    let projectPath: String
    let worktreePath: String?
    let status: WorkBatchPreviewStatus
    let appPath: String?
    let bundleID: String?
    let displayName: String?
    let pid: Int32?
    let proofPath: String?
    let buildLogPath: String?
    let failureReason: String?
    let updatedAt: Date
}

struct WorkBatchPreviewProjection: Equatable {
    let status: WorkBatchPreviewStatus
    let label: String
    let isActionEnabled: Bool
    let actionLabel: String
    let reason: String?
}
```

`preview_available` is a UI/store convenience state, not a
`MacOSPreviewWorkProof` status. It means the batch has a preview-capable
worktree but no currently running, identity-proven preview.

Persistence:

```text
~/.capacitor/projects/<encoded-project>/work-batches/previews.json
~/.capacitor/projects/<encoded-project>/work-batches/previews/<batch-id>/latest-preview-proof.json
~/.capacitor/projects/<encoded-project>/work-batches/previews/<batch-id>/latest-build.log
```

Keep preview records outside `state.json` for the first slice. This avoids
expanding canonical routing state while the preview UX is still being tested.
If preview later becomes part of Done/review protocol, move the stable subset
into the canonical Work Batch state deliberately.

Projection changes:

- Add `preview: WorkBatchPreviewProjection?` to `WorkBatchProjection`.
- Extend `WorkBatchProjectionBuilder.build(...)` or add a thin merge layer so
  projections can include preview records.
- Existing tests that construct `WorkBatchProjection` directly must pass
  `preview: nil`.

Capability detection:

```swift
enum CapacitorMacOSPreviewCapability {
    static func projection(
        projectPath: String,
        batch: WorkBatchProjection,
        previewRecord: WorkBatchPreviewRecord?
    ) -> WorkBatchPreviewProjection?
}
```

For this slice, availability is intentionally hardcoded:

- Project path resolves to the Capacitor repo and contains
  `scripts/dev/build-preview-app.sh`.
- The worktree contains `apps/swift/Package.swift`.
- Capacitor project batches get a preview projection even before a cockpit
  binding exists, but the action is disabled until the batch has a worktree.

Existing batch worktrees do not need to contain the preview script. Capacitor
uses the current project checkout's script to build the selected batch worktree,
so older worktrees can still be previewed as long as they contain the app
sources.

Add a code comment/TODO at the capability boundary:

```swift
// TODO: Replace this Capacitor-only proof hook with explicit project preview
// capabilities once we design the generic provider model.
```

## Preview Action Flow

Add an AppState entry point:

```swift
func openWorkBatchPreview(_ batch: WorkBatchProjection, for project: Project)
```

Behavior:

1. Read the batch binding.
2. If no binding or no worktree path exists, store/report `preview_unavailable`
   with reason `No batch worktree yet`.
3. Verify the capability is available for the binding worktree.
4. Write a preview record with `preview_building` immediately.
5. Build a `MacOSPreviewWorkRequest.capacitorPreview` using:
   - `worktreeURL`: binding worktree path
   - `proofDirectoryURL`: the project data preview directory for that batch
   - `buildScriptURL`: the current Capacitor project checkout's
     `scripts/dev/build-preview-app.sh`
6. Run `MacOSPreviewWorkCoordinator`.
7. Convert the returned proof into a `WorkBatchPreviewRecord`.
8. Refresh UI and show a concise toast:
   - ready: `Preview ready`
   - failed: `Preview failed`
   - unavailable: `Preview unavailable`

The action must not:

- open or start a Claude Code session
- write to the old Circuit runtime
- mutate Task completion state
- mark preview proof as user-facing evidence
- store product proof files in `docs/circuit/proofs/...`

## Required Coordinator Adjustment

The current proof coordinator fails if the fixed preview identity is already
running. That is correct for the debug proof, but the card UX needs one more
safe path:

```text
If the running preview app path matches this batch's latest ready proof, the
preview action may foreground that app instead of failing or rebuilding.
```

Implement this as a small activation helper, not a broad launcher rewrite:

```swift
protocol MacOSPreviewAppActivating {
    func activate(pid: Int32) -> Bool
}
```

Rules:

- If the stored proof is ready, running app bundle ID is
  `com.capacitor.app.preview`, running app path equals proof app path, and proof
  worktree path equals this batch binding worktree path, activate that pid.
- If any of those checks fail, do not activate it as this batch preview.
- If another preview identity is running from another path/worktree, show a
  conflict and let the user close/retry later.

Do not add per-batch bundle IDs in this slice.

## UI Wiring

Update `WorkBatchListSection`:

- Add `onOpenPreview: (WorkBatchProjection) -> Void`.
- Render a small preview button next to the terminal/cockpit button when
  `batch.preview != nil`.
- Use an icon button with an accessibility label and help text.
- Keep the terminal/cockpit icon as the cockpit action.
- Keep the summary button as checkpoint/cockpit primary action.
- Add a compact preview status line only for meaningful states:
  `Preview building`, `Ready to inspect`, `Preview failed`, or
  `Preview unavailable`.

Suggested copy:

```text
Preview building
Ready to inspect
Preview failed
Preview unavailable
```

Suggested action labels:

```text
Open Preview
Bring Preview Forward
Retry Preview
```

Do not show:

- build command
- proof path
- log path
- git head
- raw pid

## Phase Plan

### Phase 1: Product model and persistence

Files:

- `apps/swift/Sources/Capacitor/Models/WorkBatchPreviewState.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchPreviewStateTests.swift`

Steps:

1. Add preview status, record, projection, and store.
2. Persist preview records in `work-batches/previews.json`.
3. Store proof/log artifacts in `work-batches/previews/<batch-id>/`.
4. Add tests for encode/decode, missing file equals empty records, and
   `MacOSPreviewWorkProof` to `WorkBatchPreviewRecord` mapping.

Acceptance:

- Preview records round-trip with ISO dates.
- Missing preview state does not break existing projects.
- No Rust or UniFFI changes are needed.

### Phase 2: Capability and projection merge

Files:

- `apps/swift/Sources/Capacitor/Models/WorkBatchPreviewState.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- relevant Work Batch tests

Steps:

1. Add `preview: WorkBatchPreviewProjection?` to `WorkBatchProjection`.
2. Add a preview store factory to `WorkBatchAutoRouter`.
3. Merge preview records into projections.
4. Add the Capacitor-only capability check with the TODO for generic provider
   support.
5. Keep non-Capacitor projects at `preview == nil`.

Acceptance:

- Existing Work Batch projection behavior remains unchanged when no preview
  state exists.
- A Capacitor batch without a binding/worktree gets an unavailable preview
  projection with a disabled action.
- A Capacitor batch with a binding/worktree gets a preview projection.
- A non-Capacitor project does not show preview UI.
- Pending checkpoint sort/open behavior is unchanged.

### Phase 3: AppState preview action

Files:

- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchPreviewActionTests.swift`

Steps:

1. Move the current proof coordinator out of `Debug/` before Work Batch card code
   depends on it. The debug menu may keep calling it, but the product card path
   should not depend on a misleading Debug-only location.
2. Add `openWorkBatchPreview(_:for:)`.
3. Resolve the batch binding and worktree path.
4. Write `preview_building` before starting the build.
5. Run the preview coordinator with batch worktree and `~/.capacitor` proof
   directory.
6. Convert result to preview record.
7. Show a concise toast and refresh state.
8. Add activation helper for already-running proof-matching previews.

Acceptance:

- No binding produces disabled/unavailable state, not a Claude launch.
- Build success produces `ready_to_inspect`.
- Build failure produces `preview_failed` and preserves Task/Batch status.
- Existing matching preview is activated, not rebuilt.
- Existing non-matching preview is treated as a conflict.

### Phase 4: Work Batch card UI

Files:

- `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`

Steps:

1. Pass `onOpenPreview` from Project Detail.
2. Add preview button and status line to the batch row.
3. Keep checkpoint/cockpit primary card click unchanged.
4. Add accessibility labels and hover help.
5. Keep UI compact: no proof/log text on the card.

Acceptance:

- Capacitor Work Batch cards expose preview without hiding the cockpit action.
- Checkpoint-ready batches still open checkpoint on primary click.
- Preview button never launches Ghostty or Claude Code.
- Non-Capacitor project cards are visually unchanged.

### Phase 5: Focused verification

Automated tests:

```bash
swift test --package-path apps/swift --filter WorkBatchPreviewStateTests
swift test --package-path apps/swift --filter WorkBatchOpenActionResolverTests
swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests
```

If Swift files outside the narrow slice are touched, also run:

```bash
swift test --package-path apps/swift
```

Manual test:

1. Restart the correct debug app:

   ```bash
   ./scripts/dev/restart-alpha-stable.sh
   ./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
   ```

2. Open the Capacitor project in `Capacitor Debug`.
3. Use an existing Capacitor Work Batch with a binding/worktree, or add a small
   visual Task that creates one.
4. Confirm the batch card shows preview availability.
5. Click the preview affordance.
6. Confirm the card moves to `Preview building`.
7. Confirm `Capacitor Preview.app` launches from the batch worktree path.
8. Confirm the card moves to `Ready to inspect`.
9. Click the preview affordance again and confirm it foregrounds the existing
   matching preview instead of launching a terminal.
10. Close the preview app and retry from the card.
11. Open a non-Capacitor project and confirm no preview affordance appears.

Proof artifacts to inspect:

```text
~/.capacitor/projects/<encoded-project>/work-batches/previews.json
~/.capacitor/projects/<encoded-project>/work-batches/previews/<batch-id>/latest-preview-proof.json
~/.capacitor/projects/<encoded-project>/work-batches/previews/<batch-id>/latest-build.log
```

## Rollback Risks

- Slow builds may make the card look stuck. Mitigation: write
  `preview_building` immediately and keep the UI responsive.
- The fixed preview bundle ID prevents simultaneous Capacitor previews.
  Mitigation: make the conflict explicit and defer per-batch bundle IDs.
- A stale ready proof could foreground an old app. Mitigation: activate only
  when running app path, proof app path, and worktree path all match.
- Preview could accidentally become another evidence dump. Mitigation: keep raw
  logs/proofs out of the card and store them under `~/.capacitor`.
- Product code may accidentally depend on Debug-labeled proof symbols.
  Mitigation: move preview proof types out of `Debug/` before card wiring. The
  debug menu can remain, but the Work Batch card path should call product-owned
  preview code.
- The build script is Capacitor-specific. Mitigation: add the explicit TODO at
  the capability boundary and do not pretend this works for user apps yet.

## Non-Goals For This Slice

- Generic project preview configuration.
- Web preview.
- iOS/simulator preview.
- Per-batch bundle IDs.
- Multiple simultaneous native preview apps.
- Automatic preview after every Done report.
- Agent-authored preview evidence protocol.
- Screenshot capture.
- Raw evidence UI.
- New terminal/editor behavior.
- Old Circuit runtime or runner/flow-engine/task-DAG behavior.

## Completion Criteria

This spec is ready to execute when:

1. The implementation path is Swift-owned and does not require Rust changes.
2. The Work Batch card behavior is concrete enough to implement without another
   product debate.
3. The Capacitor-only hardcoding is explicit and TODO-marked.
4. The fixed bundle ID limitation is surfaced as one active preview identity.
5. The proof storage path is under `~/.capacitor`, not `docs/circuit/proofs`.
6. Checkpoints remain the highest-priority interruption.
7. The user never needs to choose build commands, app paths, or terminal
   sessions to inspect this preview.
