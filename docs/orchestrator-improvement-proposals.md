# Orchestrator Improvement Proposals

Based on the codebase state inspected on 2026-03-25.

## Current System Map

| Area | Current owner | What it does | Important constraint |
| --- | --- | --- | --- |
| Run launch | `apps/swift/Sources/Capacitor/Models/AppState.swift` + `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` | Swift creates the run in the runtime service, then launches the `method-runner` subprocess | The selected `Idea` is currently discarded before launch |
| Runtime feedback | `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` | Only checkpoint gates talk back to the runtime service | Normal execution emits local method events, but no runtime mutations |
| Card visuals | `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` + `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift` | The striped "working" card state is driven by projected session state | Method runs already affect the chip row, but not the card background state |
| Prompt assembly | `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs` + `scripts/relay/compose-prompt.sh` | The prompt builder writes a header, then the shell script appends skills/templates | The shell script is generic; most prompt customization should happen in the header |
| Worker dispatch | `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` | Runs `codex exec --full-auto -o <relay_root>/last-message.txt -` | Codex is rooted at the repo cwd, while relay outputs live under `~/.capacitor/runs/...` |

## 1. Status Heartbeats And Phase Advance

### Current state

- `BridgeInteractiveIO` only knows how to emit `EmitCheckpoint` mutations and poll for decision files.
- `execute_run()` emits rich local events like `RunStarted`, `PhaseStarted`, `StepStarted`, `WorkerDispatched`, and `GateEvaluated`, but never reports them to the runtime service.
- Swift creates runs with `kind: "create"`, which leaves the run at `status = created`.
- In the reducer, `AdvancePhase` means "complete the current phase and activate the next one." It is not a phase-start mutation.
- The only existing mutation that activates phase 0 on a created run is `AttachSession`, which is a poor semantic match for method-runner progress.

### Options considered

#### Option A: Extend `InteractiveIO` / `BridgeInteractiveIO`

- Add new methods like `emit_phase_started()` and `emit_heartbeat()` next to `emit_gate_checkpoint()`.
- Pros: reuses existing runtime endpoint discovery and keeps the wiring count low.
- Cons: mixes two unrelated responsibilities. Interactive IO is about human gates; heartbeats happen even when no gate exists.

#### Option B: Add a separate `RunStatusReporter`

- Introduce a new adapter seam with a no-op implementation and a runtime-backed implementation.
- The executor calls it from lifecycle points like run start, step start, worker dispatch, gate wait, and periodic long-running dispatch heartbeats.
- Pros: clean separation of concerns, easier testing, easy to no-op in fake mode, and easier to evolve into richer progress reporting later.
- Cons: one more adapter to construct and thread through the executor.

#### Option C: Tail `.method/events.ndjson` from a sidecar

- Keep the executor unchanged and have a separate process watch method events, then mutate the runtime service.
- Pros: very decoupled from the executor.
- Cons: extra moving part, eventual-consistency lag, harder crash recovery story, and more coordination around ownership of progress state.

### Recommended approach

Use **Option B: a separate `RunStatusReporter`**, not an extension of `BridgeInteractiveIO`.

Recommended mutation model:

- Add a lightweight heartbeat/progress mutation, for example `RunMutationKind::Heartbeat`, with optional progress payload such as `phase_id`, `step_id`, and `status_message`.
- Treat the **first heartbeat** as the activation point that moves `Created -> Active` and marks phase 0 active.
- Keep `AdvancePhase` for what it already means today: complete the current phase and activate the next one after `PhaseCompleted`.
- Keep checkpoint behavior in `BridgeInteractiveIO`; it should continue to own only `EmitCheckpoint` plus decision polling.

Why this is the right boundary:

- The executor already has the best signal for progress because it owns the lifecycle events.
- A reporter can publish human-meaningful status text like `Composing prompt`, `Dispatching Codex`, `Waiting for checkpoint`, and `Running tests`.
- This keeps the runtime model truthful instead of inferring run progress from shell sessions.

### Key files that would change

- `core/capacitor-core/src/method_runner/adapters.rs`
- `core/capacitor-core/src/method_runner/executor.rs`
- `core/capacitor-core/src/bin/method_runner.rs`
- `core/capacitor-core/src/domain/run_types.rs`
- `core/capacitor-core/src/reduce/run_reducer.rs`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`

### Rough complexity

`medium`

## 2. Working State On The Project Card

### Current state

- `ProjectCardView.currentState` is driven only by `sessionState?.state ?? .idle`.
- The striped working treatment is applied by `cardStyling(...)`, which uses that `currentState`.
- `StatusChipsRow` already gives method runs priority over delegation and session chips, so the textual chip can say `RUNNING` while the card background still looks idle.
- `SessionStateManager` is intentionally focused on projecting runtime project/session activity with hysteresis and stale-session normalization; it does not know about method runs.

### Options considered

#### Option A: Merge run state into `SessionStateManager`

- Have Swift synthesize a fake or merged `ProjectSessionState` from active runs.
- Pros: the existing card styling path keeps working unchanged.
- Cons: muddies a projection layer that is currently about shell/session truth, not method-run truth. It would also entangle run state with the manager's empty-snapshot and idle hysteresis logic.

#### Option B: Override the card's visual state inline in `ProjectCardView`

- Compute `effectiveState` directly in the view: active/created run => `.working`, paused checkpoint => `.waiting`, otherwise fall back to `sessionState`.
- Pros: smallest diff.
- Cons: if the dock card or other project surfaces need the same logic, the policy gets duplicated.

#### Option C: Add a small shared visual-state resolver in the Swift UI layer

- Create a card-specific resolver that takes `sessionState`, `delegationState`, and `activeRunState`, then returns the visual state plus context text.
- Pros: keeps `SessionStateManager` clean, avoids duplication between project card variants, and makes the precedence rules explicit.
- Cons: one extra UI-layer abstraction.

### Recommended approach

Use **Option C: a shared visual-state resolver in the UI layer**.

Recommended precedence:

- `activeRunState.status == "active"` or `"created"` => visual state `.working`
- `activeRunState.status == "paused"` with a checkpoint => visual state `.waiting`
- otherwise fall back to projected session state

Why this is preferable:

- The striped animation is a **presentation concern**, not a session-projection concern.
- It preserves the narrow responsibility of `SessionStateManager`.
- It can also consume a future run `status_message` from heartbeats to power the context line under the title.

### Key files that would change

- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DockProjectCard.swift`
- A new small resolver file under `apps/swift/Sources/Capacitor/Views/Projects/` or `apps/swift/Sources/Capacitor/Models/`

### Rough complexity

`small`

## 3. Codex Sandbox Output Routing

### Current state

- `CodexWorkerDispatcher` invokes:
  - `codex exec --full-auto -o <relay_root>/last-message.txt -`
- The codex subprocess runs with `current_dir = project_root`.
- The prompt templates instruct workers to write artifacts under `{relay_root}/handoffs/...` and `{relay_root}/review-findings/...`.
- Local E2E artifacts in `handoffs/execute-implement-attempt-00{1,2}-*.md` show Codex falling back to the repo-local `handoffs/` directory because `~/.capacitor/runs/...` was not writable inside the sandbox.
- I did **not** find a writable-root allowlist setting in `~/.codex/config.toml`; the local Codex CLI help does expose `--add-dir <DIR>`.

### Options considered

#### Option A: Pass `--add-dir <relay_root>` to `codex exec`

- Allowlist the relay directory explicitly for the worker subprocess.
- Pros: matches the local Codex CLI surface area, fixes both `-o` and template-written relay artifacts, and keeps output paths canonical.
- Cons: depends on Codex continuing to support `--add-dir`, though that is already part of the current local CLI.

#### Option B: Detect repo-local fallback artifacts after the fact

- Search repo-local `handoffs/` and copy or ingest whatever Codex wrote there.
- Pros: avoids changing codex arguments.
- Cons: heuristic, ambiguous, prone to stale-file bugs, and does not cleanly solve other artifact types like review findings.

#### Option C: Push the allowlist into global user config

- Try to encode an allowlist in `~/.codex/config.toml` or another per-user config surface.
- Pros: centralizes sandbox policy.
- Cons: I did not find a local config key for this, and a product feature should not depend on a manual user-global config tweak.

### Recommended approach

Use **Option A: pass `--add-dir <relay_root>`** from `CodexWorkerDispatcher`.

Why this is the simplest correct fix:

- The templates already target `{relay_root}`.
- `-o` also writes into `{relay_root}`.
- A single allowlisted directory should unblock the full relay contract without inventing brittle fallback-import logic.

I would keep the current contract checks in place so missing `last-message.txt` still fails loudly, but I would treat repo-local fallback detection only as a diagnostic aid, not the primary execution path.

### Key files that would change

- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
- `core/capacitor-core/tests/method_runner/adapter_seam.rs` or equivalent dispatcher tests

### Rough complexity

`small`

## 4. Per-Method Timeout

### Current state

- Built-in method YAML supports defaults like `max_attempts` and `completion_policy`, but there is no timeout field.
- `method_runner.rs` hardcodes `Duration::from_secs(900)` into `AdapterConfig::new(...)` for both `run` and `resume`.
- `WorkerDispatchRequest` has no timeout field, so the dispatcher can only use the global adapter default.
- The normalizer already has a clean precedence model for `defaults -> step override -> fallback`.

### Options considered

#### Option A: Add `timeout_secs` to method defaults, with an optional step override

- Example shape:
  - `method.defaults.timeout_secs`
  - `steps[].timeout_secs`
- Normalize it into the step model and thread it through `WorkerDispatchRequest`.
- Pros: follows the existing method-schema style and supports long-running methods without penalizing short ones.
- Cons: a few more schema and adapter touchpoints.

#### Option B: Add one method-level timeout only

- Example shape:
  - `method.defaults.timeout_secs`
- Rebuild or reconfigure the dispatcher once per run.
- Pros: simpler schema.
- Cons: too coarse if one method mixes quick shaping with long test-heavy execution.

#### Option C: Leave YAML alone and use CLI/env overrides

- Add something like `--timeout-secs` or an env var.
- Pros: smallest implementation.
- Cons: the timeout stops being authored with the method definition, which is exactly where this operational policy belongs.

### Recommended approach

Use **Option A: `timeout_secs` in method defaults with optional step override**.

Recommended threading:

- Normalize `timeout_secs` alongside `max_attempts`.
- Add `timeout: Duration` or `timeout_secs: u64` to `WorkerDispatchRequest`.
- Let the dispatcher prefer `request.timeout` and fall back to `AdapterConfig.default_timeout` for older definitions.

Why this fits the architecture:

- Timeout is part of the step execution contract, not just a binary-global knob.
- `execution_only` can opt into a longer timeout for test-heavy implementation without forcing every built-in method to wait that long on failures.

### Key files that would change

- `methods/builtins/*.yaml`
- `core/capacitor-core/src/method_runner/definition.rs`
- `core/capacitor-core/src/method_runner/adapters.rs`
- `core/capacitor-core/src/method_runner/executor.rs`
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
- `core/capacitor-core/src/bin/method_runner.rs`

### Rough complexity

`medium`

## 5. Idea Context In Prompts

### Current state

- `AppState.runMethodOnIdea(_: Idea, ...)` throws away the `Idea` argument today.
- `RuntimeRunMutationRequest` does not carry idea metadata.
- `MethodRunCoordinator.startRun(...)` passes only `runID`, `methodID`, and `projectPath` into the subprocess.
- `PromptBuildRequest` contains only step/phase/attempt/relay/instructions/template/skills.
- `ShellPromptBuilder` writes a header with `Step`, `Phase`, `Attempt`, and raw instructions.
- `compose-prompt.sh` simply concatenates the header, skills, and template, so it is not the right place for task-specific data modeling.

### Options considered

#### Option A: Concatenate idea text directly into `instructions`

- Inject the title and description into the step instructions before building the prompt.
- Pros: smallest implementation.
- Cons: mixes authored method instructions with runtime task context, makes retries messier, and leaves no clean place for the UI to reuse the same task metadata.

#### Option B: Add explicit task-context fields to the launch and prompt-build contracts

- Carry `idea_id`, `idea_title`, and `idea_description` from Swift into the method-run launch contract.
- Extend `PromptBuildRequest` with an optional structured task context.
- Have `ShellPromptBuilder` render a `## Task Context` block in `prompt-header.md`.
- Pros: explicit, reusable, and keeps the shell composer generic.
- Cons: touches more contracts.

#### Option C: Pass only `idea_id` and let the method runner re-load the idea from storage

- The subprocess would look up the idea in `ideas.md` using `projectPath`.
- Pros: smaller launch payload.
- Cons: adds storage coupling to the subprocess, complicates tests, and makes it harder to surface the same context in runtime snapshots.

### Recommended approach

Use **Option B: explicit task-context fields**.

Recommended shape:

- Stop discarding the selected `Idea` in `runMethodOnIdea`.
- Pass `idea_id`, `idea_title`, and `idea_description` into the method-run launch path.
- Extend `PromptBuildRequest` with a structured task context.
- Render that context in `prompt-header.md`, not in `compose-prompt.sh`.

Why this is the cleanest design:

- The shell script is already a generic assembler; the header is the correct injection point for runtime context.
- The same context can also be persisted on `RunState` later if you want the card context line to say things like `Execute - Fix input width`.
- It preserves a useful separation:
  - method definition = reusable workflow
  - task context = what this specific run is about

### Key files that would change

- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift`
- `core/capacitor-core/src/bin/method_runner.rs`
- `core/capacitor-core/src/method_runner/adapters.rs`
- `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs`
- Potentially `core/capacitor-core/src/domain/run_types.rs` and `core/capacitor-core/src/reduce/run_reducer.rs` if the context is also persisted on the run snapshot

### Rough complexity

`medium`

## Recommended Implementation Order

1. Fix output routing with `--add-dir` first. It is the smallest change and unblocks reliable E2E runs immediately.
2. Add the separate runtime status reporter plus heartbeat/progress payload. That gives the UI a truthful live model.
3. Add the Swift visual-state resolver so active runs light up the card correctly.
4. Add structured task context and thread idea title/description through the prompt path.
5. Add YAML-authored timeouts once the dispatch contract is already being touched.

## Final Recommendation

The cleanest overall direction is:

- make run progress first-class in the runtime model
- keep checkpoint bridging narrowly focused on human gates
- keep session projection and run presentation separate in Swift
- use Codex's existing `--add-dir` escape hatch instead of fallback artifact detection
- carry idea context explicitly rather than smuggling it through free-form instructions

That gives Capacitor a more truthful architecture: shell sessions describe terminal activity, runs describe orchestrator activity, and the project card composes both deliberately instead of hoping one can stand in for the other.
