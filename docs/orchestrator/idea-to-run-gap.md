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
6. **Checkpoint bridge** (when `BridgeInteractiveIO` is active) -- the bridge posts an `EmitCheckpoint` mutation to the runtime service, writes a pending marker to `~/.capacitor/runtime/checkpoint-bridge/<run_id>/`, and polls for a decision file. The Swift UI reads the `ActiveCheckpoint` from the runtime service and writes the decision file when the user decides.

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
| Method runs show working/waiting/none visual state on project cards | No "phase 2 of 5" progression indicator |
| Active checkpoint triggers review window | No history of past checkpoints for a run |
| `RunStatus::Completed` is a valid terminal state | No completion UI showing method run results |
| Delegation loop and method runner coexist in AppState | No unified "orchestration mode" view that shows both |
| `DelegationReviewManifest` decodes review JSON for both paths | The shared decoder is exercised by both paths, but delegation loop is disabled by default in `.frontier` |

---

## What Would Be Needed (to close remaining gaps)

The original four missing pieces have been built. The remaining gaps are:

### 1. Phase progression UI

A visual indicator showing which phase of a method run is active (e.g., "Phase 2 of 5: Design"). The `PhaseInstance` data is available from the runtime's `RunState` but is not surfaced in the project card or detail views.

### 2. Checkpoint history / timeline

A view showing all past checkpoints for a run, not just the active one. This would help users track the arc of a multi-phase method run.

### 3. Method run completion UI

When a run reaches `RunStatus::Completed`, there's no app-level surface for viewing results. The method runner writes output artifacts, but the app doesn't display them.

### 4. Production hardening

The end-to-end path (idea → method selection → run → checkpoint → decision → next phase → completion) is fully wired but has not been exercised under sustained production use. Edge cases around subprocess lifecycle (crashes, timeouts, reconnection) need validation.

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
| Completion | Run completes; results surfaced in app | **Partial.** `RunStatus::Completed` reached; **no completion results UI** |
| Delegation fallback | Method step dispatches to existing delegation Worker | `RunState.delegation_worker_id` strangler bridge field exists. **Not exercised.** |
| Phase progression UI | User sees which phase is active | **Not built.** Only working/waiting/none state visible |

---

## Key Files

| Purpose | Location |
|---------|----------|
| Method template selector UI | `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` |
| Method run creation (AppState extension) | `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift` |
| Method run coordinator (subprocess) | `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` |
| Idea detail + Delegate button | `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift` |
| Project detail (idea → method wiring) | `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift` |
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
| AppState checkpoint surfacing | `apps/swift/Sources/Capacitor/Models/AppState.swift` |
| Feature flags | `apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift` |
