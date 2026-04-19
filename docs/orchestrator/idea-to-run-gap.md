# Idea-to-Run Gap Analysis

> Doc role: `gap-analysis`
> Status: Updated 2026-03-27. The four "missing pieces" identified below have been built and are feature-flagged behind `methodRunner` (enabled in `.frontier`, disabled in `.stable`).

---

## Current Shipped Flow

The delegation loop is the only shipped path from idea to execution:

1. **Idea capture** -- user creates an idea in the Ideas surface.
2. **IdeaDetailModal "Delegate"** -- `IdeaDetailOverlay` renders a "Delegate" button (`IdeaDetailModal.swift:69`). The `onDelegate` callback is optional; when present, it fires on tap.
3. **DelegationLoopManager** -- receives the idea, launches a headless `claude -p` Worker in a git worktree (`DelegationLoopManager.swift:3-28` sets up `DelegationClaudeLaunchRequest` with `--output-format stream-json --permission-mode bypassPermissions`).
4. **Worker execution** -- the Worker runs in its worktree, producing output.
5. **Milestone** -- the Worker publishes a milestone with a `DelegationReviewManifest` JSON manifest (decoded by `DelegationReviewManifest.swift:3`).
6. **Review** -- the delegation review window surfaces. User sees summary, artifacts, and decision hints.
7. **Decision** -- user approves (`ReviewDecision.approve`) or requests changes (`ReviewDecision.requestChanges`) at `DelegationLoopManager.swift:198`.
8. **Resume or complete** -- on approval the Worker may complete; on request-changes the Worker Session is resumed with feedback.

This path works end-to-end. There is no method selection, no phase structure, and no gates -- the Worker does whatever the delegation prompt says.

---

## Method Runner Flow (standalone)

The method runner is a standalone CLI binary that executes structured multi-phase workflows:

1. **Binary entry** -- `core/capacitor-core/src/bin/method_runner.rs` parses CLI args. Supports three commands: `normalize`, `run`, `resume`.
2. **YAML definition** -- reads a method definition from YAML via `DefinitionSource`. The definition declares phases, steps, gates, and adapter configuration.
3. **Adapter selection** -- CLI flags select adapters: `FakePromptBuilder` / `ShellPromptBuilder` for prompt composition, `FakeWorkerDispatcher` / `CodexWorkerDispatcher` for worker dispatch, and `FakeInteractiveIO` / `CliInteractiveIO` / `FileInteractiveIO` / `BridgeInteractiveIO` for interactive IO.
4. **Phase execution** -- the executor progresses through phases in order. Each phase contains steps; each step may have multiple attempts.
5. **Gate evaluation** -- when a phase or step gate is reached, the executor calls `InteractiveIO.emit_gate_checkpoint()` and then `capture_response()`. The `GateOutcome` determines whether execution continues (`Approved`), halts (`Rejected`, `TimedOut`, `ValidationFailed`), or waits (`Waiting`).
6. **Checkpoint bridge** (when `BridgeInteractiveIO` is active) -- the bridge posts an `EmitCheckpoint` mutation to the runtime service, writes a pending marker to `~/.capacitor/runtime/checkpoint-bridge/<run_id>/`, and polls for a decision file. The Swift UI reads the active checkpoint from the runtime snapshot and submits a `SubmitDecision` runtime mutation. The hud-hook relay commits the bridge decision file only after the runtime mutation is accepted.

This flow now has a Swift invocation path via `MethodRunCoordinator` (see "Closed Gaps" below). The standalone CLI remains available for testing.

---

## Closed Gaps (as of 2026-03-27)

The four missing pieces identified in the original analysis have been built and are feature-flagged:

| Original Gap | Status | Implementation |
|-------------|--------|----------------|
| No method template browser or selector UI | **CLOSED** | `MethodSelectorView.swift` shows available templates; `ProjectDetailView.swift` wires idea → selector |
| No Swift coordinator that invokes the method runner binary | **CLOSED** | `MethodRunCoordinator.swift` (335 lines) spawns the method runner as a subprocess with `--bridge` flags |
| No path from idea → choose method → create run → start binary | **CLOSED** | `AppState+MethodRunner.swift:runMethodOnIdea()` creates RunState via runtime mutation, then launches via coordinator |
| Nothing populates checkpoint review from the idea flow | **CLOSED** | The bridge path is exercised end-to-end when a method run is started from the idea flow |

**Feature flag:** `isMethodRunnerEnabled` (true in `.frontier`, false in `.stable`). The method selector UI only appears when this flag is active.

## Remaining Gaps

| What exists | What does not exist |
|-------------|---------------------|
| Method runs show working/waiting/completed/failed visual state on project cards | **CLOSED.** RunVisualState extended with completed/failed cases + terminal visibility window |
| Active checkpoint triggers review window | **CLOSED.** Decided checkpoints are archived in `runs[].past_checkpoints` and shown in the Project Detail run checkpoint timeline |
| `RunStatus::Completed` surfaces in project cards and ActivityPanel | **CLOSED.** RunCompletionCard shows method name, elapsed time, and status |
| Delegation loop and method runner coexist in AppState | No unified "orchestration mode" view that shows both |
| `DelegationReviewManifest` decodes review JSON for both paths | The shared decoder is exercised by both paths, but delegation loop is disabled by default in `.frontier` |

---

## What Would Be Needed (to close remaining gaps)

The original four missing pieces have been built. The remaining gaps are:

### 1. Phase progression UI — CLOSED

`RunVisualState` extended with `.completed` and `.failed` cases. Terminal states are visible on project cards for 1 hour after completion. The `statusMessage` from the method runner carries phase labels that appear as context text. Card visual state now reflects completed/failed runs with appropriate context text.

### 2. Checkpoint history — CLOSED

The Rust run kernel now archives decided checkpoints in `past_checkpoints` when `SubmitDecision` clears `active_checkpoint`. Each emitted checkpoint receives a runtime-owned `history_ordinal` from the run's durable `next_checkpoint_history_ordinal` cursor, and each archived checkpoint keeps its `history_ordinal`, `decision`, `decided_at`, artifacts, and checkpoint metadata. Swift decodes this typed history from runtime snapshots. History is bounded to the most recent 50 decided checkpoints per run. Project Detail selects the latest run with checkpoint history and renders a run checkpoint timeline from that run's archived checkpoints plus any current active checkpoint, including decision state, notes, timestamps, runtime ordinal-backed row identity/order, and Swift-derived display round numbers per phase.

### 3. Method run completion UI — CLOSED

`RunCompletionCard` added to `ActivityPanel` showing method name, elapsed time, and status (completed/failed/cancelled) with color-coded status icons. Cards appear for terminal runs within the last hour.

### 4. Production hardening — CLOSED

`MethodRunCoordinator` hardened with: configurable timeout parameter (default 1800s), graceful SIGTERM → SIGKILL escalation with 5s grace period, async-safe process tracking for Swift 6.2, expanded stderr buffer (30 → 100 lines), and cancel mutation writes `cancelled` status instead of `failed`.

---

## Aspirational vs Shipped (updated 2026-03-27)

Comparing the full aspirational flow with what is now shipped:

| Flow Step | Aspirational | Status |
|-----------|-------------|--------|
| Idea capture | User creates idea | **Shipped.** `IdeaCapturePopover` → idea queue |
| Method selection | User picks a method template from a browser | **Shipped (feature-flagged).** `MethodSelectorView` shows 4 built-in templates |
| Run creation | Coordinator creates `RunState` and spawns method runner binary | **Shipped.** `AppState+MethodRunner.runMethodOnIdea()` → `MethodRunCoordinator` |
| Phase/step execution | Method runner executes phases with real adapters (`--real` flag) | **Shipped.** Coordinator spawns method runner binary with `--bridge` flags |
| Gate checkpoint | Bridge emits checkpoint to runtime service; Swift surfaces review | **Shipped.** `BridgeInteractiveIO` → runtime → `RunCheckpointReviewWindow` |
| Decision relay | User decides; hud-hook relay writes decision file; bridge polls and resumes | **Shipped.** Full relay chain wired |
| Completion | Run completes; results surfaced in app | **Shipped.** `RunCompletionCard` in ActivityPanel shows method name, elapsed time, status |
| Delegation fallback | Method step dispatches to existing delegation Worker | `RunState.delegation_worker_id` strangler bridge field exists. **Not exercised.** |
| Phase progression UI | User sees which phase is active | **Shipped.** Terminal states visible on cards; statusMessage carries phase labels |
| Checkpoint history UI | User can see prior checkpoint decisions for the selected run | **Shipped.** Project Detail selects the latest checkpoint-history run and shows `past_checkpoints` plus `activeCheckpoint` as a run checkpoint timeline |

---

## Key Files

| Purpose | Location |
|---------|----------|
| Method template selector UI | `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` |
| Method run creation (AppState extension) | `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift` |
| Method run coordinator (subprocess) | `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` |
| Idea detail + Delegate button | `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift` |
| Project detail (idea → method wiring) | `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift` |
| Run checkpoint timeline projection | `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointTimelineProjection.swift` |
| Run checkpoint timeline UI | `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointTimelineSection.swift` |
| Delegation loop manager | `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` |
| Method runner binary | `core/capacitor-core/src/bin/method_runner.rs` |
| Method YAML definition types | `core/capacitor-core/src/method_runner/definition.rs` |
| Method runner executor (gates) | `core/capacitor-core/src/method_runner/executor.rs` |
| Method runner state machine | `core/capacitor-core/src/method_runner/state.rs` |
| InteractiveIO trait + adapters | `core/capacitor-core/src/method_runner/adapters.rs` |
| Checkpoint bridge (BridgeInteractiveIO) | `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` |
| Checkpoint bridge protocol (pending/decision types) | `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs` |
| Run kernel domain types | `core/capacitor-core/src/domain/run_types.rs` |
| Run visual state resolver | `apps/swift/Sources/Capacitor/Views/Projects/ProjectRunVisualStateResolver.swift` |
| Review manifest decoder | `apps/swift/Sources/Capacitor/Models/DelegationReviewManifest.swift` |
| AppState checkpoint/timeline selectors | `apps/swift/Sources/Capacitor/Models/RunState.swift`, `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift` |
| Feature flags | `apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift` |
