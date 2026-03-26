# Orchestrator Implementation Plan

This plan synthesizes:

- `docs/orchestrator-scratchpad.md`
- `docs/orchestrator-improvement-proposals.md`
- `docs/orchestrator-adversarial-review.md`

The sequence below is intentionally conservative:

- Fix the E2E blockers first.
- Make run truth explicit before polishing UI.
- Persist task context once and reuse it for prompts and UI, instead of creating parallel sources of truth.
- Keep `RunMutationKind::AdvancePhase` as a phase-completion mutation. Do not overload it as a phase-start signal.
- Treat `created` as a transient record state. Add an explicit run-start mutation instead of activating runs on the first heartbeat.

## Preflight Check

Before starting Phase 2, rerun the existing Rust run persistence contract and compare it to Swift's snapshot-failure behavior:

- Rust already has `core/capacitor-core/tests/run_kernel_contract.rs::scenario_snapshot_recovery`, which proves snapshot persistence in isolation.
- Swift currently clears `runStatesByID` after two fresh `/runtime/snapshot` failures in `apps/swift/Sources/Capacitor/Models/AppState.swift::handleRuntimeSnapshotFailureIfFresh(...)`.

Do not widen the implementation to Rust snapshot persistence unless a live reproduction disproves the existing Rust contract. The most likely first fix is Swift-side run-sink handling, not reducer persistence.

## Phase 1: Critical Path

### 1. Allow Codex to write to the relay root

- **Title**: Allow `codex exec` to write to the per-run relay directory outside the repo
- **Files changed**:
  - `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
  - `core/capacitor-core/tests/method_runner/real_worker_dispatcher.rs`
- **What to do**:
  - In `CodexWorkerDispatcher::dispatch(...)`, change the argv construction from `codex exec --full-auto -o <last-message> -` to `codex exec --full-auto --add-dir <relay_root> -o <last-message> -`.
  - Keep `request.relay_root` as the single allowed write root. Do not add repo-local handoff import logic.
  - Preserve the existing clean-exit contract check that requires `<relay_root>/last-message.txt`.
  - Extend `worker-dispatch.metadata.json` to record the effective `relay_root` and the final argv so future regressions are diagnosable.
  - In `real_worker_dispatcher.rs`, assert that the captured argv contains `--add-dir` and that the passed directory is the absolute `request.relay_root`.
- **Dependencies**: None
- **Estimated scope**: 2 files, about 25-50 lines
- **Test strategy**:
  - Run `cargo test -p capacitor-core --test real_worker_dispatcher`.
  - Add an argv-level assertion using `scripts/test/fake-codex.sh`'s captured `argv.txt`.
  - Smoke-test one real method run and verify that `HANDOFF.md` and `last-message.txt` land under `~/.capacitor/runs/<run-id>/.../relay/workers/<worker>/`.
- **Risks**:
  - `--add-dir` is a Codex CLI contract owned outside this repo.
  - Future relay artifacts must stay under the single allowlisted relay root or this fix silently becomes incomplete.

### 2. Make worker timeout authored in the method definition

- **Title**: Add method-level `timeout_secs` and thread it through run and resume
- **Files changed**:
  - `methods/builtins/execution_only.yaml`
  - `methods/builtins/shape_and_execute.yaml`
  - `core/capacitor-core/src/method_runner/definition.rs`
  - `core/capacitor-core/src/method_runner/adapters.rs`
  - `core/capacitor-core/src/method_runner/executor.rs`
  - `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
  - `core/capacitor-core/src/bin/method_runner.rs`
  - `core/capacitor-core/tests/method_runner/adapter_seam.rs`
  - `core/capacitor-core/tests/method_runner/real_worker_dispatcher.rs`
- **What to do**:
  - Add `RawMethodDefaults.timeout_secs: Option<u64>` in `definition.rs`.
  - Normalize that to `NormalizedMethodDefinition.timeout_secs: Option<u64>`.
  - Reject `timeout_secs == 0` during normalization.
  - Do not add step-level timeout overrides in the first cut. Keep the first version method-level only.
  - Set `method.defaults.timeout_secs: 1800` in:
    - `methods/builtins/execution_only.yaml`
    - `methods/builtins/shape_and_execute.yaml`
  - Add `timeout_secs: Option<u64>` to `WorkerDispatchRequest`.
  - In `execute_dispatch_workers(...)` inside `executor.rs`, populate `WorkerDispatchRequest.timeout_secs` from `normalized.method.timeout_secs`.
  - In `CodexWorkerDispatcher::dispatch(...)`, prefer `request.timeout_secs` over `AdapterConfig.default_timeout`.
  - Leave the binary's `AdapterConfig::new(..., Duration::from_secs(900), ...)` fallback in `src/bin/method_runner.rs` for methods that do not author a timeout.
  - Make sure resumed runs still use the frozen definition snapshot so the effective timeout does not drift on `resume`.
- **Dependencies**: Item 1 is independent but should land first because it is the smaller E2E unblocker
- **Estimated scope**: 9 files, about 140-220 lines
- **Test strategy**:
  - Extend normalization tests to cover `timeout_secs` defaulting and zero-value rejection.
  - Extend `adapter_seam.rs` so the recorded `WorkerDispatchRequest` carries the authored timeout.
  - Extend `real_worker_dispatcher.rs` to assert the effective timeout used by the dispatcher.
  - Run `cargo test -p capacitor-core`.
- **Risks**:
  - This only fixes dispatcher timeout, not hangs in other phases of the method runner.
  - A method-level timeout is intentionally coarse; some long/short mixed workflows may eventually need step-level override.

## Phase 2: Status Visibility

### 3. Add explicit run-start and heartbeat mutations to the run kernel

- **Title**: Separate lifecycle transitions from liveness updates in `RunState`
- **Files changed**:
  - `core/capacitor-core/src/domain/run_types.rs`
  - `core/capacitor-core/src/reduce/run_reducer.rs`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
  - `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift`
  - `core/capacitor-core/tests/run_kernel_contract.rs`
  - `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs`
  - `core/hud-hook/tests/serve_integration.rs`
- **What to do**:
  - Add `RunMutationKind::Start`.
  - Add `RunMutationKind::Heartbeat`.
  - Add `status_message: Option<String>` to:
    - `MutateRunCommand`
    - `RunState`
    - `SnapshotRunPayload`
    - `RuntimeRunMutationRequest`
    - `RuntimeRunState`
  - Implement `handle_start(...)` in `run_reducer.rs`:
    - transition `Created -> Active`
    - mark phase 0 `PhaseStatus::Active`
    - set `PhaseInstance.started_at`
    - record `status_message`
    - be idempotent if the run already started
  - Implement `handle_heartbeat(...)` in `run_reducer.rs`:
    - update `updated_at`
    - replace `status_message` if a non-empty message is present
    - reject terminal runs
  - Keep `handle_advance_phase(...)` semantics exactly as they are today: complete current phase, activate next phase, finish run if it was the last phase.
  - Do not reuse `AttachSession` as a start signal.
- **Dependencies**: Item 2
- **Estimated scope**: 7 files, about 160-260 lines
- **Test strategy**:
  - Add reducer contract coverage for `Create -> Start -> Heartbeat -> AdvancePhase`.
  - Verify `status_message` survives snapshot persistence and recovery.
  - Extend Swift decode/encode tests for the new run fields.
  - Extend `serve_integration.rs` so the runtime HTTP layer accepts the new mutation kinds.
- **Risks**:
  - Duplicate `Start` calls need idempotent handling or retries will become noisy failures.
  - Heartbeats without a freshness policy can still leave stale `active` runs behind after crashes.

### 4. Introduce a dedicated `RunStatusReporter`

- **Title**: Report executor lifecycle progress through a separate runtime-backed adapter
- **Files changed**:
  - `core/capacitor-core/src/method_runner/mod.rs`
  - `core/capacitor-core/src/method_runner/adapters.rs`
  - `core/capacitor-core/src/method_runner/run_status_reporter.rs`
  - `core/capacitor-core/src/method_runner/executor.rs`
  - `core/capacitor-core/src/method_runner/resume.rs`
  - `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
  - `core/capacitor-core/src/bin/method_runner.rs`
  - `core/capacitor-core/tests/method_runner/adapter_seam.rs`
  - `core/capacitor-core/tests/method_runner/checkpoint_bridge.rs`
  - `core/capacitor-core/tests/method_runner/run_status_reporter.rs`
- **What to do**:
  - Add a new adapter seam in `run_status_reporter.rs`:
    - `enum RunStatusEventKind`
    - `struct RunStatusEvent`
    - `trait RunStatusReporter`
    - `struct NoopRunStatusReporter`
    - `struct RuntimeRunStatusReporter`
  - Keep checkpoint emission inside `BridgeInteractiveIO`. Do not merge checkpoint and progress responsibilities.
  - In `src/bin/method_runner.rs`, construct a `RuntimeRunStatusReporter` whenever bridge mode is enabled; otherwise use `NoopRunStatusReporter`.
  - Thread the reporter through both `execute_run(...)` and `resume_run(...)`.
  - Emit status events from `executor.rs` at these points:
    - immediately after the local `RunStarted` event: send `Start`
    - when a new phase becomes active: send `Heartbeat` with a phase message
    - before prompt assembly: `Composing prompt`
    - before dispatch: `Dispatching Codex`
    - before gate polling: `Waiting for checkpoint`
    - after each non-final `PhaseCompleted` event: send `AdvancePhase`, then immediately send a `Heartbeat` for the newly-active phase
    - after final success: `Complete`
    - on fatal failure paths: `Fail`
  - In `worker_dispatch_adapter.rs`, replace the single long `wait_timeout(timeout)` call with a loop of shorter waits, and send a reporter heartbeat every 30 seconds while Codex is still running.
  - On `resume_run(...)`, emit one immediate heartbeat for the recovered phase/step so resumed runs do not sit silently.
  - Reporter failures should log and continue. They must not abort the run.
- **Dependencies**: Item 3
- **Estimated scope**: 10 files, about 220-340 lines
- **Test strategy**:
  - Add spy/reporter seam tests that assert event order for `execute_run(...)` and `resume_run(...)`.
  - Add a runtime-backed integration test similar to `checkpoint_bridge.rs` that captures `/runtime/run/mutate` payloads.
  - Manual smoke test: once the subprocess launches, the run should stop showing `created` and should update its message during long Codex work.
- **Risks**:
  - Periodic heartbeats require careful throttling to avoid snapshot churn.
  - Retry paths can emit duplicate messages unless event emission is centralized.
  - Best-effort reporting can hide runtime outages unless logs stay explicit.

### 5. Drive project-card visuals from run truth, not session fallback

- **Title**: Add a shared visual-state resolver for run-aware project cards
- **Files changed**:
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/DockProjectCard.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectRunVisualStateResolver.swift`
  - `apps/swift/Tests/CapacitorTests/AppStateSessionObservationTests.swift`
  - `apps/swift/Tests/CapacitorTests/StatusChipsRowTests.swift`
  - `apps/swift/Tests/CapacitorTests/ProjectRunVisualStateResolverTests.swift`
- **What to do**:
  - Add `ProjectRunVisualStateResolver` as a small Swift UI-layer policy object. Keep `SessionStateManager` unchanged.
  - In `AppState.activeRun(for:)`, stop returning `runStatesByID.values.first`.
  - Replace it with deterministic selection:
    - paused run with active checkpoint wins
    - then active run
    - then created run
    - tie-break on newest `updatedAt`, then newest `createdAt`
  - In `handleRuntimeSnapshotFailureIfFresh(...)`, stop clearing `runStatesByID` on the second snapshot failure. Keep the last known run snapshot and let the resolver apply a freshness guard to stale `active` runs.
  - In `ProjectRunVisualStateResolver`, apply these presentation rules:
    - paused run with `activeCheckpoint != nil` => `.waiting`
    - fresh active run => `.working`
    - created run => fall back until `Start` lands
    - otherwise fall back to delegation/session presentation
  - Use `run.statusMessage` to drive the project-card context line in `ProjectCardView`.
  - Add `activeRunState` to `DockProjectCard` and pass it from `DockLayoutView.projectCard(...)`.
  - Keep `StatusChipsRow` as the chip renderer, but update its tests for the new run precedence and any created-state fallback changes.
- **Dependencies**: Items 3 and 4
- **Estimated scope**: 9 files, about 180-300 lines
- **Test strategy**:
  - Add resolver tests for run/session/delegation precedence.
  - Update `AppStateSessionObservationTests` so transient snapshot failures do not immediately erase run state.
  - Manual smoke test in both the main project grid and the dock strip:
    - active run => striped working card
    - paused checkpoint => waiting card
    - transient runtime restart/fetch failure => card does not immediately go blank
- **Risks**:
  - Preserving last-known runs can make stale runs linger if the freshness threshold is too loose.
  - The dock and full card can drift if they do not share the same resolver.

## Phase 3: Polish

### 6. Persist idea task context and inject it into prompt headers

- **Title**: Thread idea context through run creation, on-disk task context, and prompt assembly
- **Files changed**:
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
  - `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift`
  - `apps/swift/Tests/CapacitorTests/MethodRunCoordinatorTests.swift`
  - `core/capacitor-core/src/domain/run_types.rs`
  - `core/capacitor-core/src/reduce/run_reducer.rs`
  - `core/capacitor-core/src/method_runner/adapters.rs`
  - `core/capacitor-core/src/method_runner/storage.rs`
  - `core/capacitor-core/src/method_runner/executor.rs`
  - `core/capacitor-core/src/method_runner/resume.rs`
  - `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs`
  - `core/capacitor-core/src/bin/method_runner.rs`
  - `core/capacitor-core/tests/method_runner/adapter_seam.rs`
  - `core/capacitor-core/tests/method_runner/real_prompt_builder.rs`
  - `core/capacitor-core/tests/run_kernel_contract.rs`
- **What to do**:
  - In `AppState.runMethodOnIdea(idea:method:for:)`, stop discarding the `Idea` argument.
  - Add `ideaId`, `ideaTitle`, and `ideaDescription` to:
    - `RuntimeRunMutationRequest`
    - `MutateRunCommand`
    - `RunState`
    - `SnapshotRunPayload`
    - `RuntimeRunState`
  - In `run_reducer.rs::handle_create(...)`, snapshot those fields onto the run so UI and prompts share the same task identity.
  - Add a description normalizer in Swift, for example `compactRunIdeaDescription(_:)`, that trims whitespace and clamps size before the text is passed to CLI or prompt headers.
  - Extend `MethodRunCoordinator.startRun(...)` with `ideaID`, `ideaTitle`, and `ideaDescription`, and pass them as CLI flags:
    - `--idea-id`
    - `--idea-title`
    - `--idea-description`
  - In `src/bin/method_runner.rs`, parse those flags and write `.method/task-context.json` using a new `MethodRunPaths.task_context_path()`.
  - Add `task_context: Option<TaskContext>` to `PromptBuildRequest`.
  - In both `execute_run(...)` and `resume_run(...)`, load `.method/task-context.json` and pass it into the prompt builder.
  - In `ShellPromptBuilder` and `FakePromptBuilder`, render a `## Task Context` block above the instructions. Keep `scripts/relay/compose-prompt.sh` generic and unchanged.
  - Once the run snapshot contains `ideaTitle`, update the card context-line composition to prefer `ideaTitle` over bare `methodName`.
- **Dependencies**: Item 5 for UI reuse; prompt-injection work can start after Items 1 and 2
- **Estimated scope**: 16 files, about 260-420 lines
- **Test strategy**:
  - Add Swift tests for run-mutation encoding and CLI argument construction.
  - Extend `method_runner.rs` CLI parse tests for the new idea flags.
  - Extend prompt-builder tests so `prompt-header.md` contains `## Task Context`.
  - Extend run-kernel contract tests so idea fields survive snapshot recovery.
- **Risks**:
  - Raw idea descriptions can bloat prompts or accidentally break Markdown structure.
  - If `task-context.json` is missing on resume, prompt composition can silently regress unless the loader fails loudly.

### 7. Redesign `MethodSelectorView` to use the app's overlay system

- **Title**: Replace the fixed opaque method selector with a glass modal that respects natural sizing
- **Files changed**:
  - `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
  - `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorModalOverlay.swift`
- **What to do**:
  - Split the current selector into:
    - a content view for the method list
    - a modal overlay wrapper that handles scrim, escape dismissal, and transition
  - Remove the hard-coded `.frame(width: 380)` from `MethodSelectorView`.
  - Replace the opaque `Color.hudBackground` panel with the same frosted/vibrant treatment used by `IdeaDetailOverlay` and other project overlays.
  - Make the container respect natural sizing with a max width instead of a fixed width.
  - Keep the existing `onSelect` callback, but restyle the cards so the method name, description, and phase count read like native app UI instead of a detached sheet.
  - In `ProjectDetailView`, present the selector through the new overlay instead of the bare `Color.black.opacity(0.3)` wrapper.
- **Dependencies**: Item 6 is optional if you want the selector copy to echo idea title in the header; otherwise independent
- **Estimated scope**: 3 files, about 100-180 lines
- **Test strategy**:
  - Manual verification only:
    - narrow and wide window widths
    - keyboard escape dismissal
    - clicking outside closes the overlay
    - the panel no longer fights the host panel's horizontal bounce
- **Risks**:
  - Modal focus and escape handling can conflict with the host panel if the overlay wrapper is not isolated cleanly.
  - Styling drift is likely if the selector copies glass values instead of reusing the app's shared overlay primitives.

### 8. Wire method-run state into the idea queue and remove the dead path

- **Title**: Make `IdeaQueueStatusResolver` actually surface method-running and checkpoint-ready states
- **Files changed**:
  - `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift`
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
  - `apps/swift/Tests/CapacitorTests/IdeaQueueStatusResolverTests.swift`
  - `apps/swift/Tests/CapacitorTests/AppStateRunCheckpointTests.swift`
- **What to do**:
  - Add `AppState.activeRun(for idea: Idea, in project: Project) -> RuntimeRunState?`.
  - Match runs to ideas using the new `run.ideaId`.
  - Change `IdeaQueueStatusResolver.resolve(...)` to accept `runState: RuntimeRunState?`.
  - Return:
    - `.methodRunning(...)` when the matching run is `active`
    - `.methodCheckpointReady` when the matching run is `paused` and has `activeCheckpoint`
  - Use `run.statusMessage ?? run.methodName` for the visible label text.
  - Update `ProjectDetailView` so each idea row passes both delegation state and run state into the resolver.
  - Remove any remaining dead branches or tests if a case is still unreachable after wiring.
- **Dependencies**: Item 6
- **Estimated scope**: 5 files, about 70-130 lines
- **Test strategy**:
  - Add resolver tests for:
    - matching active run
    - matching paused checkpoint run
    - mismatched `ideaId`
    - delegation still winning when review is ready
  - Add one app-state test that a paused run checkpoint targeted at a specific idea resolves to that idea only.
  - Run `swift test --package-path apps/swift`.
- **Risks**:
  - Multiple concurrent runs on the same idea need a deterministic winner.
  - Long `statusMessage` text can make idea-row labels noisy unless trimmed.

## Recommended Execution Order

1. Item 1: relay-root allowlist
2. Item 2: method-authored timeout
3. Item 3: `Start` and `Heartbeat` run mutations
4. Item 4: `RunStatusReporter` in executor, resume, and dispatcher
5. Item 5: run-aware card visibility and Swift failure-hysteresis fix
6. Item 6: persisted task context and prompt-header injection
7. Item 8: idea queue wiring and dead-code removal
8. Item 7: method selector redesign

This order keeps the first half focused on correctness and E2E reliability, then spends UI effort only after the runtime snapshot is trustworthy enough to drive it.
