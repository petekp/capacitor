# Idea-to-Run Gap Analysis

> Doc role: `gap-analysis`
> Status: Current. Documents what exists vs what's needed to connect idea capture to method execution.

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

This flow runs independently. No Swift UI invokes it.

---

## The Gap

There is no UI or coordinator that connects idea capture to method selection to method run creation. Specifically:

| What exists | What does not exist |
|-------------|---------------------|
| `IdeaDetailModal` "Delegate" button goes to `DelegationLoopManager` | No method template browser or selector UI in Swift |
| Method runner binary reads YAML and executes phases/steps/gates | No Swift coordinator that invokes the method runner binary |
| `BridgeInteractiveIO` bridges gates to `AppState.runCheckpointWindowTarget` | No path from idea -> choose method -> create run -> start binary |
| `AppState.runCheckpointWindowTarget` surfaces run checkpoint reviews | Nothing populates it from the idea flow; only the standalone binary's bridge writes checkpoint state |
| `DelegationReviewManifest` decodes review JSON for both delegation and run checkpoint paths | The shared decoder exists but only the delegation path exercises it end-to-end in the app |

The method runner is a CLI tool. The delegation loop is a Swift-managed process. They share the runtime service and the review manifest format, but there is no invocation bridge between them.

---

## What Would Be Needed

To close the gap, four pieces are required:

### 1. Method template browser / selector UI

A SwiftUI view that lets the user browse available method templates and select one for an idea. This would replace (or augment) the current direct "Delegate" action.

- **Input:** list of `MethodTemplate` records (from YAML definitions on disk or from the runtime service)
- **Output:** a selected `MethodTemplate` and an `InvolvementLevel`

### 2. Run creation coordinator

A Swift coordinator (analogous to `DelegationLoopManager`) that:

- Creates a `RunState` via a `Create` `MutateRunCommand` to the runtime service
- Spawns the method runner binary as a subprocess with `--bridge` flags pointing at the runtime service
- Monitors the subprocess lifecycle (attach/detach session, failure detection)

### 3. Checkpoint bridge wiring to AppState

The checkpoint bridge already handles the bridge-to-relay-to-UI path:

- `BridgeInteractiveIO.post_checkpoint()` sends `EmitCheckpoint` to the runtime service (`checkpoint_bridge.rs:166-185`)
- The runtime service updates `RunState.active_checkpoint`
- `AppState` already has `runCheckpointWindowTarget` (`AppState.swift:120`) and checkpoint surfacing logic (`AppState.swift:1780-1814`)

The gap is that nothing invokes the method runner binary from Swift to trigger this path. The bridge protocol and UI rendering are ready.

### 4. End-to-end invocation path

When the user decides on a run checkpoint review, Swift sends a `SubmitDecision` mutation to the runtime service. The hud-hook relay (`checkpoint_bridge_relay.rs`) already writes the `CheckpointBridgeDecision` file — this part works. The missing piece is that nothing in the idea-capture flow invokes the method runner binary that would create the bridge checkpoints in the first place.

---

## Aspirational vs Shipped

Comparing the full aspirational flow (from `docs/superpowers/plans/2026-03-23-end-to-end-product-flow-validation.md`) with what actually ships today:

| Flow Step | Aspirational | Shipped |
|-----------|-------------|---------|
| Idea capture | User creates idea | User creates idea |
| Method selection | User picks a method template from a browser | **Not built.** "Delegate" goes directly to `DelegationLoopManager` |
| Run creation | Coordinator creates `RunState` and spawns method runner binary | **Not built.** No Swift coordinator invokes the binary |
| Phase/step execution | Method runner executes phases with real adapters (`--real` flag) | Method runner CLI works standalone with `--real` flag; no Swift invocation |
| Gate checkpoint | Bridge emits checkpoint to runtime service; Swift surfaces review | Bridge works end-to-end in CLI tests. Swift checkpoint review UI exists (`runCheckpointWindowTarget`). **Not wired from idea flow.** |
| Decision relay | User decides; hud-hook relay writes decision file; bridge polls and resumes | Bridge polling + relay works end-to-end. **Not reachable from idea flow.** |
| Completion | Run completes; results surfaced in app | `RunStatus::Completed` is a valid terminal state. **No app-level completion UI for method runs.** |
| Delegation fallback | Method step dispatches to existing delegation Worker | `RunState.delegation_worker_id` strangler bridge field exists (`run_types.rs:266`). **Not exercised.** |

The end-to-end validation plan (`2026-03-23-end-to-end-product-flow-validation.md:5-11`) explicitly scopes out the Swift-backed live `InteractiveIO` and idea-to-method selection UI, confirming these are known future work.

---

## Key Files

| Purpose | Location |
|---------|----------|
| Idea detail + Delegate button | `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift` |
| Delegation loop manager | `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` |
| Method runner binary | `core/capacitor-core/src/bin/method_runner.rs` |
| Method YAML definition types | `core/capacitor-core/src/method_runner/definition.rs` |
| Method runner executor (gates) | `core/capacitor-core/src/method_runner/executor.rs` |
| Method runner state machine | `core/capacitor-core/src/method_runner/state.rs` |
| InteractiveIO trait + adapters | `core/capacitor-core/src/method_runner/adapters.rs` |
| Checkpoint bridge (BridgeInteractiveIO) | `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` |
| Checkpoint bridge protocol (pending/decision types) | `core/capacitor-core/src/method_runner/checkpoint_bridge_protocol.rs` |
| Run kernel domain types | `core/capacitor-core/src/domain/run_types.rs` |
| Review manifest decoder | `apps/swift/Sources/Capacitor/Models/DelegationReviewManifest.swift` |
| AppState checkpoint surfacing | `apps/swift/Sources/Capacitor/Models/AppState.swift` (line 120, 1780-1814) |
| Aspirational end-to-end plan | `docs/superpowers/plans/2026-03-23-end-to-end-product-flow-validation.md` |
