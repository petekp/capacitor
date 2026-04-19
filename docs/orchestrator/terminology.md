# Orchestrator Terminology

> Doc role: `canonical-spec`
> Status: Current. Normalized glossary for orchestrator, delegation, and checkpoint bridge terms.
> Extends: `docs/orchestrator/ubiquitous-language.md` (original baseline)

This glossary normalizes terms across the delegation loop, run kernel, method runner, and checkpoint bridge subsystems. When a term has shifted from its historical definition, the update is noted inline. For the original definitions, see the historical baseline.

---

## Core Terms (carried forward)

These terms originate from `docs/orchestrator/ubiquitous-language.md` and remain accurate.

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Project** | A normalized repository/workspace tracked by Capacitor. | Repo card, workspace item |
| **Project Key** | The durable encoded-path identity for a Project. | Display name, project title |
| **Orchestrator** | The single interactive Claude session representing one Project. | Main worker, assistant, chat |
| **Worker** | A headless `claude -p` execution unit for substantial delegated work in one Project. Runs in a git Worktree. | Workstream, task runner |
| **Worker Session** | The Claude conversation identity used to resume a Worker. Distinct from a Run. | PID |
| **Delegation Loop** | The validated vertical slice where one idea launches one Worker, pauses for review, and resumes. Shipped end-to-end. | Orchestrator mode |
| **Milestone** | A versioned checkpoint published by a Worker for review during the delegation loop. | Proposal, draft |
| **Decision** | The human response that resolves a Review. Values: `approve`, `request_changes`. | Comment, note |
| **Artifact** | A durable file published by the Orchestrator or a Worker. | Temp output |
| **Journal** | The append-only runtime record of orchestration events. | Snapshot log |
| **Worktree** | The git isolation unit used by a Worker. | Workstream |
| **Orchestrator Registration** | The explicit handshake that makes an interactive session the active Orchestrator for a Project. | Discovery, guess |
| **Orchestrator Liveness** | The runtime-owned judgment of whether the registered Orchestrator is still live and reconnectable. | Tab exists |
| **Restart Recovery** | Deterministic reconstruction of orchestration state after app or process restart. | Best effort resume |

---

## Checkpoint Bridge Terms (new)

These terms describe the file-based protocol that connects the method runner CLI to the Swift review UI. Defined in `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` and `checkpoint_bridge_protocol.rs`.

| Term | Definition | Code Type | Aliases to avoid |
|------|-----------|-----------|-----------------|
| **Gate** | A human-in-the-loop approval point declared in a method YAML definition. Gates can appear at phase level or step level. The executor pauses and invokes the `InteractiveIO` trait when a gate is reached. | `RawGate` (`definition.rs:121`) | Checkpoint (ambiguous), barrier |
| **Checkpoint** | An approval record emitted to the run kernel when a gate fires. Created via `EmitCheckpoint` mutation. The run kernel tracks its status (`Pending` / `Active` / `Decided` / `Skipped`) independently from the method runner's gate state. | `ActiveCheckpoint` (`run_types.rs:228`) | Milestone (delegation term) |
| **Checkpoint Bridge** | The subsystem that translates method runner gates into run kernel checkpoints and relays human decisions back. Uses filesystem pending/decision files plus runtime service mutations. | `BridgeInteractiveIO` (`checkpoint_bridge.rs:30`) | IPC layer |
| **Pending Marker** | A JSON file written to `~/.capacitor/runtime/checkpoint-bridge/<run_id>/<checkpoint_id>.pending.json` when a gate fires. Lets the hud-hook relay pair an accepted runtime `SubmitDecision` mutation with the bridge-managed checkpoint waiting on disk. | `CheckpointBridgePending` (`checkpoint_bridge_protocol.rs:38`) | Lock file, signal file |
| **Decision File** | A JSON file written to `~/.capacitor/runtime/checkpoint-bridge/<run_id>/<checkpoint_id>.json` by the hud-hook relay (or test harness) after a successful `SubmitDecision` mutation. The bridge polls for this file. | `CheckpointBridgeDecision` (`checkpoint_bridge_protocol.rs:58`) | Response file |
| **Bridge Interactive IO** | The `InteractiveIO` implementation that posts `EmitCheckpoint` mutations to the runtime service and polls for decision files. Falls back to a wrapped `InteractiveIO` if the runtime service is unreachable or IDs are unsafe. | `BridgeInteractiveIO` (`checkpoint_bridge.rs:30`) | Bridge adapter |
| **Relay** | The runtime service mutation path. `BridgeInteractiveIO.post_checkpoint()` sends an `EmitCheckpoint` `MutateRunCommand` to the runtime service, which updates `RunState.active_checkpoint`. The Swift UI reads the active checkpoint from runtime snapshot polling. | `RuntimeServiceEndpoint.mutate_run()` | RPC, API call |
| **Decision Poll Timeout** | Maximum time the bridge waits for a decision file before treating the gate as rejected. Default: 1 hour (`DECISION_POLL_TIMEOUT` at `checkpoint_bridge.rs:28`). Poll interval: 500ms. | `Duration` constant | Deadline |

---

## Run Kernel Terms (new)

These types live in `core/capacitor-core/src/domain/run_types.rs` and implement the Run Kernel with Methods and Checkpoints architecture. They coexist with delegation types during the strangler-pattern migration.

| Term | Definition | Code Type |
|------|-----------|-----------|
| **Run** (kernel) | A single execution of a method template against a project. Tracks phases, checkpoints, and session bindings. Not the same as a delegation Worker Run. | `RunState` (`run_types.rs:254`) |
| **RunStatus** | Lifecycle state of a kernel run: `Created`, `Active`, `Paused`, `Completed`, `Failed`, `Cancelled`. Terminal states: `Completed`, `Failed`, `Cancelled`. | `RunStatus` (`run_types.rs:15`) |
| **RunMutationKind** | The set of legal mutations on a run: `Create`, `AdvancePhase`, `EmitCheckpoint`, `SubmitDecision`, `AttachSession`, `DetachSession`, `CaptureClaim`, `CaptureFailed`, `CaptureComplete`, `Pause`, `Resume`, `Complete`, `Fail`, `Cancel`. | `RunMutationKind` (`run_types.rs:78`) |
| **ActiveCheckpoint** | The currently pending checkpoint within a run. Holds kind, status, title, summary, media artifacts, mermaid sources, capture state, and decision. At most one per run at a time. | `ActiveCheckpoint` (`run_types.rs:228`) |
| **Checkpoint History Ordinal** | Runtime-owned monotonic order assigned to a checkpoint when it is emitted. Stored as `ActiveCheckpoint.history_ordinal` and advanced by `RunState.next_checkpoint_history_ordinal`; preserved when active checkpoints are archived into `past_checkpoints`. Swift uses it for checkpoint timeline ordering and row identity when present. | `history_ordinal`, `next_checkpoint_history_ordinal` (`run_types.rs:228`) |
| **CheckpointKind** | Classification of a checkpoint: `Proposal`, `ImplementationMilestone`, `AlignmentReview`, `Custom { label }`. | `CheckpointKind` (`run_types.rs:34`) |
| **CheckpointStatus** | Lifecycle of a single checkpoint: `Pending`, `Active`, `Decided`, `Skipped`. | `CheckpointStatus` (`run_types.rs:45`) |
| **CaptureStatus** | State of an agent-browser capture request attached to a checkpoint: `NotRequested`, `Pending`, `InProgress`, `Completed`, `Failed { reason }`. | `CaptureStatus` (`run_types.rs:184`) |
| **InvolvementLevel** | Human involvement mode for a run: `Autonomous`, `Supervised` (default), `Collaborative`. | `InvolvementLevel` (`run_types.rs:69`) |
| **MutateRunCommand** | The command struct sent to the runtime service to mutate run state. Carries all optional fields needed by any mutation kind. | `MutateRunCommand` (`run_types.rs:283`) |

---

## Method Runner Terms (new)

These types live in `core/capacitor-core/src/method_runner/`. The method runner is a standalone CLI binary (`core/capacitor-core/src/bin/method_runner.rs`) that reads YAML definitions and executes phases, steps, and gates using pluggable adapters.

| Term | Definition | Code Type |
|------|-----------|-----------|
| **Method Template** | A reusable description of a multi-phase workflow. Defines phases, default involvement level, and a task archetype. Loaded from YAML via `DefinitionSource`. | `MethodTemplate` (`run_types.rs:108`), `RawPhase`/`RawStep` (`definition.rs:66,81`) |
| **Phase** | An ordered stage within a method. Contains steps and an optional gate. Statuses: `Pending`, `Running`, `Completed`, `Failed`, `Blocked`, `Skipped`. | `RawPhase` (`definition.rs:66`), `PhaseState` (`state.rs:246`) |
| **Step** | A unit of work within a phase. Has an action type (dispatch, interactive, synthesis, pipeline_execute), optional inputs/outputs, max attempts, and an optional gate. | `RawStep` (`definition.rs:81`), `StepState` (`state.rs:254`) |
| **Attempt** | One execution try of a step. A step may have multiple attempts up to `max_attempts`. Tracks workers, output bindings, and status (`Created`, `Dispatching`, `Running`, `HandoffReceived`, `OutputBound`, `Completed`, `Failed`). | `AttemptState` (`state.rs:262`), `AttemptStatus` (`state.rs:51`) |
| **Gate** (method YAML) | An approval checkpoint declared in a phase or step definition. Has an `id` and a `type` (e.g., `"approval"`). When reached, the executor invokes `InteractiveIO.emit_gate_checkpoint()`. | `RawGate` (`definition.rs:121`) |
| **GateOutcome** | Result of gate evaluation: `Approved`, `Rejected`, `Waiting`, `TimedOut`, `ValidationFailed { reason }`. | `GateOutcome` (`executor.rs:77`) |
| **InteractiveIO** | Trait boundary for human-in-the-loop interaction. Three methods: `emit_prompt`, `capture_response`, `emit_gate_checkpoint`. Implementations: `FakeInteractiveIO`, `CliInteractiveIO`, `FileInteractiveIO`, `BridgeInteractiveIO`. | trait `InteractiveIO` (`adapters.rs:157`) |
| **Adapter** | A pluggable implementation of one of the method runner's trait boundaries (`InteractiveIO`, `PromptBuilder`, `WorkerDispatcher`). Selected at binary launch time via CLI flags. | Various structs in `adapters.rs`, `prompt_builder_adapter.rs`, `worker_dispatch_adapter.rs` |
| **Real Adapter** | An adapter that performs actual work: `ShellPromptBuilder` (shell-based prompt composition), `CodexWorkerDispatcher` (subprocess worker dispatch), `BridgeInteractiveIO` (checkpoint bridge to runtime service). Enabled via `--real` flag. | `ShellPromptBuilder`, `CodexWorkerDispatcher`, `BridgeInteractiveIO` |
| **Fake Adapter** | An adapter that returns pre-configured responses without side effects. Used for testing and tracer bullets: `FakePromptBuilder`, `FakeWorkerDispatcher`, `FakeInteractiveIO`. | `FakeInteractiveIO` (`adapters.rs:211`), etc. |

---

## Review Terms (updated)

These terms have expanded since the historical glossary to cover both delegation and run checkpoint review.

| Term | Current Definition | Historical Note |
|------|-------------------|-----------------|
| **Review** | A typed pending decision over a Milestone (delegation) or an ActiveCheckpoint (run kernel). Both paths converge on the same SwiftUI review surface. | Previously only covered delegation milestones. |
| **Review Surface** | The UI surface that renders a pending review. For delegation: `DelegationReviewWindow`. For run checkpoints: `RunCheckpointReviewWindow`. Both are gated by `AppState.reviewWindowTarget` and `AppState.runCheckpointWindowTarget` respectively. | Previously a single surface for delegation only. |
| **Review Manifest** | A JSON manifest describing the artifacts, summary, and decision hints for a review. Decoded by `DelegationReviewManifest` (`DelegationReviewManifest.swift:3`). Used by both delegation milestones (via `manifest_path` in the milestone payload) and run checkpoints (via `checkpoint_manifest_path` in `ActiveCheckpoint`). | Previously delegation-only. The shared decoder means both paths produce the same JSON format. |
| **Delegation Review** | A review triggered by a Worker publishing a Milestone during the delegation loop. Managed by `DelegationLoopManager`. Decision values: `approve`, `request_changes` (`DelegationLoopManager.swift:198`). | Unchanged. |
| **Run Checkpoint Review** | A review triggered by a method runner gate emitting a checkpoint via the bridge. Surfaced when `AppState.runCheckpointWindowTarget` is set. Decision is written as a `CheckpointBridgeDecision` JSON file. | New. Did not exist in the historical glossary. |
| **Review Needed** | A state where either a Milestone has a pending delegation review or an ActiveCheckpoint has `status == .Pending` / `.Active`. | Previously only covered delegation milestones. |

---

## Disambiguation

Several terms have different meanings depending on context. Always qualify them.

### "Run"

| Context | Meaning | Code Type |
|---------|---------|-----------|
| Delegation | One launched or resumed process episode for a Worker. A Worker may span multiple Runs over one Worker Session. | Informal (no dedicated type) |
| Run Kernel | A single execution of a method template. Tracks phases, checkpoints, involvement level, and session bindings. | `RunState` (`run_types.rs:254`) |
| Method Runner | An event-sourced execution instance. Has its own status machine (`Created`, `Running`, `Completed`, `Failed`, `Blocked`). | `MethodRunState` (`state.rs`) |

**Rule:** Use "Worker Run" for delegation context, "Method Run" or "kernel run" for method runner / run kernel context.

### "Checkpoint"

| Context | Meaning | Code Type |
|---------|---------|-----------|
| Delegation | A Milestone — a versioned output published by a Worker for review. | Informal (called "Milestone" in domain) |
| Run Kernel | An `ActiveCheckpoint` — a structured approval record with kind, status, media artifacts, and decision. At most one pending per run. | `ActiveCheckpoint` (`run_types.rs:228`) |
| Method Runner | A Gate — a YAML-declared approval point that pauses execution and invokes `InteractiveIO`. | `RawGate` (`definition.rs:121`) |
| Checkpoint Bridge | The filesystem protocol artifact (pending marker + decision file) that connects a method runner gate to the run kernel's checkpoint state. | `CheckpointBridgePending`, `CheckpointBridgeDecision` |

**Rule:** Use "Milestone" for delegation, "ActiveCheckpoint" or "run checkpoint" for the kernel, "gate" for the YAML declaration, and "bridge checkpoint" for the filesystem protocol.

### "Review"

| Context | Meaning |
|---------|---------|
| Delegation | Human review of a Worker's Milestone. Managed by `DelegationLoopManager`. |
| Run Kernel | Human review of an ActiveCheckpoint. Surfaced via `AppState.runCheckpointWindowTarget`. |

**Rule:** Use "delegation review" or "run checkpoint review" to disambiguate.

### "Gate"

| Context | Meaning | Code Type |
|---------|---------|-----------|
| Method YAML | An `approval`-type declaration on a phase or step that pauses execution. | `RawGate` (`definition.rs:121`) |
| Checkpoint Bridge | The bridge's representation of a gate firing — it writes a pending marker, posts an `EmitCheckpoint` mutation, and polls for a decision file. | `BridgeInteractiveIO.emit_gate_checkpoint()` |
| Executor | The runtime evaluation of a gate, producing a `GateOutcome`. | `GateOutcome` (`executor.rs:77`) |

**Rule:** Use "YAML gate" for the definition, "bridge gate" for the checkpoint bridge path, and "gate evaluation" for the executor outcome.

---

## Relationships (updated)

Carried forward from the historical glossary with additions for the run kernel and method runner.

- A **Project** has exactly one **Project Key**.
- A **Project** has at most one active **Orchestrator**.
- A **Project** may have zero or more active **Workers** (delegation) and zero or more active **Method Runs** (run kernel).
- A **Worker** uses one **Worktree** while active.
- A **Worker** may span multiple **Worker Runs** over one **Worker Session**.
- A **Worker** may publish one or more **Milestones**; each creates one pending **Delegation Review**.
- A **Method Run** follows one **Method Template** and progresses through its **Phases** in order.
- Each **Phase** contains one or more **Steps**; each **Step** may have multiple **Attempts**.
- A **Phase** or **Step** may declare a **Gate**; when reached, the executor invokes the **InteractiveIO** adapter.
- With the **Checkpoint Bridge** adapter, a gate fires an **EmitCheckpoint** mutation, creating an **ActiveCheckpoint** in the **Run Kernel**, and writes a **Pending Marker** to disk.
- The Swift UI reads the **ActiveCheckpoint** from the runtime snapshot and submits a **SubmitDecision** runtime mutation; the hud-hook relay commits the **Decision File** only after that mutation is accepted.
- A **Decision** resolves one **Review** (delegation or run checkpoint).
- The **Journal** records lifecycle transitions for **Orchestrators**, **Workers**, **Milestones**, **Decisions**, and **Method Runs**.
