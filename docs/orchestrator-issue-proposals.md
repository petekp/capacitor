# Orchestrator E2E Issue Proposals

> Generated from `docs/orchestrator-scratchpad.md` issues.
> Each issue gets: current state, options, recommendation, key files, and complexity.

---

## Group 1: Status & Feedback Loop

### 1.1 Card should show "working" state with striped animation during method execution

**Current state:**
`ProjectCardView` computes `currentState` from `sessionState?.state ?? .idle` (line 39). The striped animation is driven by `CardLayerOpacityPolicy.opacities(for:)` in `ProjectCardModifiers.swift` which sets `workingStripe: 1.0` only for `SessionState.working`. When a method run is active, the `StatusChipsRow` shows a `RunStatusChip` (via `StatusChip.swift` lines 60-105), but the card's `currentState` remains `.idle` because the method-runner subprocess does not produce hook events that the session state manager recognizes -- it only writes to the runtime service via bridge mutations.

The `SessionStateManager.mapRuntimeState(_:)` (line 588) maps string states like `"working"` to `SessionState.working`, but runtime project state for a project with an active method run does not get a `"working"` state string from the method runner.

**Options:**

A. **Derive `SessionState` from run status at the projection layer.** In `ProjectCardView`, compute `currentState` to also consider `activeRunState`. If `activeRunState?.status == "active" || activeRunState?.status == "created"`, treat the card as `.working`.
   - *Pros:* Simple, no Rust changes, localized to Swift view layer.
   - *Cons:* Duplicates state derivation logic in the view; the underlying `SessionStateManager` is unaware.

B. **Teach `SessionStateManager` to synthesize `.working` from run state.** When `AppState` passes runtime project states to `SessionStateManager.applyRuntimeProjectStates`, also pass active run states. If a project has an active/created run, force its session state to `.working`.
   - *Pros:* Single source of truth; striped animation, glow, and card ordering all react correctly.
   - *Cons:* Requires changing `SessionStateManager.applyRuntimeProjectStates` signature and merge logic.

C. **Have the method-runner emit synthetic hook events** that the existing ingest pipeline recognizes as `"working"`.
   - *Pros:* No Swift changes; works with existing projection.
   - *Cons:* Architecturally wrong -- method runner is a different subsystem than Claude Code sessions; conflating them creates false signals.

**Recommended approach:** Option B. The `SessionStateManager` already owns the projection of runtime state into UI state. Adding run-awareness there keeps the single source of truth intact and makes the striped animation, border glow, and card reordering all react automatically.

**Key files that would change:**
- `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` -- `applyRuntimeProjectStates` gains run state awareness
- `apps/swift/Sources/Capacitor/Models/AppState.swift` -- passes active run states into `SessionStateManager`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift` -- `currentState` computed property may need minor adjustment

**Rough complexity:** Medium

---

### 1.2 Method runner needs to send AdvancePhase + periodic heartbeats

**Current state:**
The method-runner binary (`core/capacitor-core/src/bin/method_runner.rs`) constructs a `BridgeInteractiveIO` (line 540) that can post `EmitCheckpoint` mutations to the runtime service. However, neither the `executor.rs` run loop nor any adapter sends `AdvancePhase` or status-update mutations during execution. The run stays `status=created` forever in the runtime service.

The `executor.rs` `execute_run` function (line 630) loops through phases and steps, emitting events to the local `events.jsonl` log but never calling back to the runtime service. The `BridgeInteractiveIO` only has `emit_gate_checkpoint` and `capture_response` -- it has no method for reporting phase transitions or progress.

The `RunMutationKind` enum (in `run_types.rs` line 77) already has `AdvancePhase`, `Pause`, `Resume`, `Complete`, `Fail` -- all the verbs needed.

**Options:**

A. **Add a `RuntimeStatusReporter` trait + implementation.** Create a new trait with methods like `report_run_started()`, `report_phase_started(phase_id)`, `report_step_progress(step_id, message)`, and `report_run_completed(status)`. Pass it into `execute_run` alongside the existing adapters. The real implementation posts `AdvancePhase` and status mutations via `RuntimeServiceEndpoint`.
   - *Pros:* Clean separation; testable with a fake; does not pollute the existing `InteractiveIO` trait.
   - *Cons:* New trait + parameter threading through the call chain.

B. **Extend `BridgeInteractiveIO` to also handle status reporting.** Add `report_phase_advance()` and `report_completion()` methods. The executor calls these through the `InteractiveIO` trait.
   - *Pros:* Reuses existing bridge infrastructure and endpoint.
   - *Cons:* Conflates two concerns (checkpoints vs. status reporting); `InteractiveIO` trait becomes bloated; fake implementations must stub more methods.

C. **Post mutations directly from the executor using a service endpoint.** Pass the `RuntimeServiceEndpoint` into `execute_run` and call `endpoint.mutate_run(...)` directly at phase boundaries.
   - *Pros:* Simplest implementation; no new trait.
   - *Cons:* Tight coupling; hard to test without a running service; no separation of concerns.

**Recommended approach:** Option A. A `RuntimeStatusReporter` trait keeps the method runner testable (fake reporter in tests, real one in production). The real implementation reuses `RuntimeServiceEndpoint::mutate_run`. Heartbeats can be periodic `AdvancePhase` or a new `Heartbeat` mutation kind if needed.

**Key files that would change:**
- `core/capacitor-core/src/method_runner/adapters.rs` -- new `RuntimeStatusReporter` trait
- `core/capacitor-core/src/method_runner/` -- new `status_reporter.rs` module with real implementation
- `core/capacitor-core/src/method_runner/executor.rs` -- `execute_run` gains `reporter` parameter; calls at phase start/end/completion
- `core/capacitor-core/src/bin/method_runner.rs` -- constructs real reporter from bridge options

**Rough complexity:** Medium

---

### 1.3 Context line should show idea title, not just method name

**Current state:**
In `ProjectCardView`, `runContextText` (line 218) builds context strings like `"Starting: \(run.methodName)"`, `"Running: \(run.methodName)"`, or `"Checkpoint ready -- \(run.methodName)"`. The `RuntimeRunState` struct (`RuntimeClient.swift` line 421) has `methodId`, `methodName`, `status`, etc., but no field for the idea title or description.

The method run is created via `mutateRun(Create)` in `AppState`, but the idea title is not passed through to the `RunState` domain type. The `RunState` struct (`run_types.rs` line 254) has no field for idea title or context text.

**Options:**

A. **Add a `context_label` field to `RunState` and `MutateRunCommand`.** The `Create` mutation accepts an optional `context_label` (e.g., the idea title). The Swift layer sets it when creating the run. `RuntimeRunState` exposes it. `ProjectCardView.runContextText` uses it.
   - *Pros:* Proper end-to-end solution; the runtime service stores the context with the run.
   - *Cons:* Touches domain types, reducer, UniFFI bindings, and Swift model.

B. **Store idea title in a Swift-side lookup.** `AppState` maintains a `[String: String]` mapping of `runID -> ideaTitle`. `ProjectCardView` receives it and uses it in context text.
   - *Pros:* No Rust changes; fast to implement.
   - *Cons:* Ephemeral -- lost on app restart; doesn't survive runtime service queries.

**Recommended approach:** Option A. The context label is a fundamental property of a run ("what is this run doing?"). Storing it in `RunState` makes it durable and available to any consumer. The cost of touching the domain types is justified because this is the right architectural layer.

**Key files that would change:**
- `core/capacitor-core/src/domain/run_types.rs` -- add `context_label: Option<String>` to `RunState` and `MutateRunCommand`
- `core/capacitor-core/src/reduce/run_reducer.rs` -- `handle_create` copies `context_label` into `RunState`
- `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift` -- UniFFI regeneration picks up new field
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` -- `RuntimeRunState` gains `contextLabel`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift` -- `runContextText` uses `contextLabel` when available
- `apps/swift/Sources/Capacitor/Models/AppState.swift` -- passes idea title into the `Create` mutation

**Rough complexity:** Medium

---

## Group 2: Visual Polish

### 2.1 MethodSelectorView needs full redesign

**Current state:**
`MethodSelectorView` (`apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift`) uses:
- A fixed `frame(width: 380)` (line 45) that breaks the panel's horizontal bounce animation.
- `Color.hudBackground.opacity(0.95)` (line 49) as a solid opaque background, ignoring the app's vibrancy/frosted glass system.
- `RoundedRectangle(cornerRadius: 12)` with a simple white stroke border (line 53).
- No entrance/exit animations, no `appeared` state, no staggered content.

By contrast, `DelegationReviewView` (`DelegationReviewView.swift`) uses:
- `@Environment(\.floatingMode)` to adapt to floating vs. docked layout.
- Staggered `appeared` animations with opacity/offset transitions.
- The natural sizing constraints of its parent container.
- The app's standard `AppTypography` and color tokens.

`IdeaDetailModal` (referenced in scratchpad) similarly uses the overlay system's natural sizing and vibrancy.

**Options:**

A. **Restyle in-place.** Replace the `Color.hudBackground` fill with the app's `DarkFrostedCard` or equivalent vibrancy background. Remove the fixed `frame(width: 380)`. Add `appeared` state-driven staggered animations. Use `@Environment(\.floatingMode)` for layout mode adaptation.
   - *Pros:* Minimal structural change; fixes the visual regression directly.
   - *Cons:* The current component structure (separate `MethodCard`) is fine; just needs restyling.

B. **Replace with a full overlay component** matching `IdeaDetailModal`'s overlay pattern, presented via the same navigation/overlay system rather than as a standalone sheet.
   - *Pros:* Consistent navigation model.
   - *Cons:* More work; may not be necessary if the current sheet presentation is intentional.

**Recommended approach:** Option A. The core issue is styling, not architecture. The component structure is sound -- it just needs the app's visual language applied to it. Key changes: remove fixed width, use vibrancy background, add entrance animations, respect `floatingMode`.

**Key files that would change:**
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` -- restyle background, sizing, animations

**Rough complexity:** Small

---

## Group 3: Codex Dispatch Issues

### 3.1 Codex sandbox blocks writes to execution root

**Current state:**
`CodexWorkerDispatcher` (`worker_dispatch_adapter.rs`) spawns `codex exec --full-auto -o <last-message-path> -` where `last-message-path` is `request.relay_root.join("last-message.txt")` (line 63). The relay root is under `~/.capacitor/runs/<runID>/...`.

The `codex` binary has a sandbox that restricts filesystem writes. When the execution root is outside the project directory, codex cannot write to it. The `-o` flag path (`~/.capacitor/runs/<runID>/.method/phases/.../last-message.txt`) falls outside the sandbox's allowed write paths.

The worker CWD is set to `self.config.project_root` (line 90), which is the project path. Codex's sandbox likely allows writes within the project directory and `$HOME` directories it recognizes, but not arbitrary paths under `~/.capacitor/`.

After dispatch, the executor checks for the `-o` output file. If it doesn't exist despite exit code 0, `AdapterError::ContractViolation` is returned (line 205-209).

**Options:**

A. **Move the `-o` output path into the project directory.** Instead of `relay_root.join("last-message.txt")`, use a path under the project root (e.g., `.capacitor-run/last-message.txt`) and then copy it to the relay root after codex exits.
   - *Pros:* Works within codex's sandbox constraints; no codex changes needed.
   - *Cons:* Leaves artifacts in the project directory; needs cleanup.

B. **Pass codex a `--writable-root` or sandbox-config flag** that explicitly allows writes to the execution root.
   - *Pros:* Clean; no workaround paths.
   - *Cons:* Depends on codex supporting such a flag; may not exist yet.

C. **Use the project-relative path for `-o` and scan for the output file.** Set `-o` to a well-known relative path within the project dir. After codex completes, copy the output to the relay root.
   - *Pros:* Simple; predictable.
   - *Cons:* Potential conflict if multiple runs target the same project; needs unique naming.

**Recommended approach:** Option C with unique naming. Use `-o .capacitor-run-<runID>/last-message.txt` (relative to project CWD). After codex exits, copy the file to the relay root and clean up the temp directory. This avoids sandbox issues while keeping the output contract intact.

**Key files that would change:**
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` -- change `-o` path to project-relative; add post-dispatch copy logic
- `core/capacitor-core/src/method_runner/adapter_config.rs` -- possibly add a `run_id` field so the dispatcher can construct unique paths

**Rough complexity:** Small

---

### 3.2 Timeout needs to be per-method or configurable

**Current state:**
The timeout is hardcoded at `Duration::from_secs(900)` (15 minutes) in `method_runner.rs` line 177 and line 268 (both `CommandKind::Run` and `CommandKind::Resume` paths). This is passed into `AdapterConfig::new` as `default_timeout`. `CodexWorkerDispatcher` uses `self.config.default_timeout` (line 110) for `child.wait_timeout(timeout)`.

The YAML schema (`RawMethodDefaults` in `definition.rs` line 36) has `max_attempts` and `completion_policy` but no `timeout` or `timeout_secs` field. The `RawStep` struct (line 81) also has no timeout field.

**Options:**

A. **Add `timeout_secs` to the YAML schema at method and step level.** Add an optional `timeout_secs` to `RawMethodDefaults` and `RawStep`. The normalizer resolves step-level overrides over method-level defaults. The executor passes the resolved timeout to the dispatcher per step.
   - *Pros:* Maximum flexibility; each method/step can declare its own timeout.
   - *Cons:* Requires schema change, normalizer change, and threading timeout through the dispatch call chain.

B. **Add a `--timeout` CLI flag to the method-runner binary.** The operator or coordinator can pass a timeout that overrides the default.
   - *Pros:* Simple; no schema change; useful for ad-hoc runs.
   - *Cons:* Caller must know the right timeout; no per-step granularity.

C. **Both A and B.** CLI flag overrides the YAML default; YAML default overrides the hardcoded 900s.
   - *Pros:* Full control at every layer.
   - *Cons:* Most implementation work.

**Recommended approach:** Option C (both). The YAML `timeout_secs` field is the right place for method authors to declare expected duration. The CLI flag gives operators escape-hatch control. Resolution order: CLI flag > YAML step > YAML method defaults > hardcoded 900s.

**Key files that would change:**
- `core/capacitor-core/src/method_runner/definition.rs` -- add `timeout_secs: Option<u64>` to `RawMethodDefaults` and `RawStep`; add `timeout` to `NormalizedStep`
- `core/capacitor-core/src/method_runner/executor.rs` -- read resolved timeout from step definition; pass to dispatcher
- `core/capacitor-core/src/method_runner/adapters.rs` -- `WorkerDispatchRequest` gains optional `timeout` field
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` -- use per-request timeout if provided, fall back to `config.default_timeout`
- `core/capacitor-core/src/bin/method_runner.rs` -- add `--timeout` CLI flag; pass through to `AdapterConfig`
- `methods/builtins/execution_only.yaml` -- add `timeout_secs: 1800` (30 min) for the `--real` case
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` -- optionally pass `--timeout` to the subprocess

**Rough complexity:** Medium

---

### 3.3 Idea context not threaded into dispatch prompt

**Current state:**
The dispatch instruction in `execution_only.yaml` (line 27) is: `"Implement the task. Produce a summary of what was done and any decisions made along the way."` This is generic -- it does not mention what task to implement.

The prompt composition chain:
1. `executor.rs` builds a `PromptBuildRequest` with `instructions` from the step's `dispatch.instructions` field.
2. `ShellPromptBuilder` (`prompt_builder_adapter.rs` line 88) writes a header file containing `# Step: {step_id}\nPhase: {phase_id}\nAttempt: {attempt}\n\n{instructions}\n`.
3. `compose-prompt.sh` assembles the final prompt from the header, skills, and template.

No part of this chain receives the idea title, description, or any context about what the user wants done. The `execute_run` function signature (`executor.rs` line 630) takes `source`, `prompt_builder`, `dispatcher`, and `interactive_io` -- none of which carry idea context.

The `MethodRunCoordinator.startRun` (`MethodRunCoordinator.swift` line 37) receives `runID`, `methodID`, and `projectPath` but not the idea title or description.

**Options:**

A. **Pass idea context as a context file in the execution root.** Before launching the method-runner, `MethodRunCoordinator` writes a `context.md` file to the execution root containing the idea title and description. The method-runner's `execute_run` reads this file and prepends it to every step's prompt instructions.
   - *Pros:* No CLI flag changes; no YAML schema changes; the context file is inspectable for debugging.
   - *Cons:* Implicit contract (file must exist at a known path); not part of the formal definition.

B. **Add `--context-title` and `--context-description` CLI flags to the method-runner.** These are threaded into the prompt builder as prefix text.
   - *Pros:* Explicit; visible in process invocation.
   - *Cons:* Shell escaping issues with long descriptions; clutters CLI.

C. **Add an `inputs` mechanism to the method YAML.** The definition declares `inputs: { task_description: { type: text, required: true } }`. The orchestrator writes input values to `inputs/task_description.txt` in the execution root. The prompt builder interpolates `${task_description}` in dispatch instructions.
   - *Pros:* Architecturally correct; methods become reusable templates with explicit inputs; the `RawMethodInput` struct already exists in `definition.rs` (line 48).
   - *Cons:* Larger implementation; requires input resolution + template interpolation.

**Recommended approach:** Option A for the immediate fix, with Option C as the follow-up. Writing a `context.md` file to the execution root is fast, debuggable, and unblocks E2E testing. The formal inputs mechanism (Option C) is the right long-term architecture but is a larger effort that should be planned separately.

**Key files that would change (Option A):**
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` -- `startRun` gains `ideaTitle: String?` and `ideaDescription: String?` parameters; writes `context.md` to execution root
- `apps/swift/Sources/Capacitor/Models/AppState.swift` -- passes idea context to `MethodRunCoordinator.startRun`
- `core/capacitor-core/src/method_runner/executor.rs` -- at run start, read `context.md` from execution root if present; prepend to step instructions
- `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs` -- `PromptBuildRequest.instructions` includes the context prefix

**Rough complexity:** Small (Option A) / Large (Option C)

---

## Group 4: Integration Gaps

### 4.1 Run state not persisting across service restarts

**Current state:**
The `CoreRuntime.mutate_run` method (`lib.rs` line 490) calls `self.persist_snapshot(&snapshot)` after every mutation. The `ReducerState::from_snapshot` method (`reduce/mod.rs` line 46) restores runs from the snapshot on startup (lines 73-77), keyed as `"{project_path}#{run_id}"`.

The snapshot is persisted to `~/.capacitor/runtime/app_snapshot.json` (as indicated by `DEFAULT_RUNTIME_ARTIFACT_RELATIVE_PATH` in `serve.rs` line 23). On service restart, `RuntimeServerState::new` loads the snapshot and reconstructs `ReducerState`.

The reported issue (snapshot shows 0 runs after service restart) suggests either:
1. The snapshot file is being overwritten with an empty snapshot before the run mutation lands.
2. A race between hook event ingestion (which triggers its own snapshot persist) and the run mutation.
3. The snapshot is written correctly but the Swift client reads it before the service fully initializes.

**Options:**

A. **Add run-state logging + investigation.** Add debug logging at `persist_snapshot` to log run count before/after. Check if a hook event triggers a snapshot write that races with the run mutation write. Add a `runs_count` field to the health endpoint for easy verification.
   - *Pros:* Low risk; identifies the actual root cause before committing to a fix.
   - *Cons:* Does not fix anything immediately.

B. **Add a WAL or append-only mutation log** alongside the snapshot so that mutations survive even if the snapshot is momentarily stale.
   - *Pros:* Robust against races.
   - *Cons:* Significant complexity; overkill if the bug is simpler.

C. **Ensure the snapshot is loaded atomically on startup** and that initial hook events don't clear runs. Review the `ReducerState::from_snapshot` path to confirm runs are preserved. Add a targeted test that creates a run, serializes the snapshot, deserializes it, and verifies the run is present.
   - *Pros:* Targeted fix if the issue is snapshot round-tripping.
   - *Cons:* May not find the issue if it's a race condition.

**Recommended approach:** Option A first (investigation), then Option C. The most likely cause is a race condition where a hook event triggers a full snapshot persist with zero runs (because runs are only in the in-memory state when the service has actually processed the mutation). We need logging to confirm the theory before building a fix.

**Key files that would change:**
- `core/capacitor-core/src/lib.rs` -- add run count to persist_snapshot logging
- `core/hud-hook/src/serve.rs` -- add `runs_count` to health endpoint response
- `core/capacitor-core/src/reduce/mod.rs` -- add round-trip test for snapshot with runs

**Rough complexity:** Small (investigation) / Medium (fix)

---

### 4.2 IdeaQueueStatusResolver has dead code for method runs

**Current state:**
`IdeaQueueStatusResolver` (`apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift`) defines `IdeaQueueActivity` enum cases `.methodRunning(phaseName: String?)` and `.methodCheckpointReady` (lines 7-8). These cases have full implementations for `label`, `accessibilityLabel`, `tint`, `showsProgress`, and `symbolName`.

However, the `resolve` function (line 91) only considers `delegationState` and `isGeneratingTitle`. It never checks for active method runs. The function signature is:
```swift
static func resolve(
    idea: Idea,
    isGeneratingTitle: Bool,
    delegationState: RuntimeDelegationState?,
) -> IdeaQueueActivity?
```

It does not receive any run state. The runs are project-level (stored in `RuntimeRunState`), while ideas are per-item. There is no `ideaId` field on `RunState` to link a run back to a specific idea.

**Options:**

A. **Wire up the resolver to receive run state.** Add `activeRunState: RuntimeRunState?` to the `resolve` signature. If the run was started for this idea (requires a linkage mechanism -- see 1.3 above for `context_label`), produce `.methodRunning` or `.methodCheckpointReady`.
   - *Pros:* Makes the existing enum cases functional; shows run progress in the idea queue.
   - *Cons:* Requires idea-to-run linkage, which depends on adding an `idea_id` or similar field to `RunState`.

B. **Remove the dead cases.** Delete `.methodRunning` and `.methodCheckpointReady` from `IdeaQueueActivity` and their implementations.
   - *Pros:* Eliminates dead code; honest about current capabilities.
   - *Cons:* Loses the design intent; will need to be re-added when the feature is implemented.

C. **Add `idea_id` to `RunState` and wire everything up end-to-end.** When a run is created for an idea, the `Create` mutation carries the idea ID. The `RunState` stores it. The Swift layer can then match runs to ideas.
   - *Pros:* Complete solution; enables idea-level run status in the queue, detail view, etc.
   - *Cons:* Touches domain types, reducer, UniFFI, Swift model, and resolver.

**Recommended approach:** Option C, combined with the `context_label` work from issue 1.3. Adding `idea_id: Option<String>` to `RunState` alongside `context_label` is a natural extension. Both fields are set during `Create`. The resolver then matches by `idea_id`. This should be done in the same PR as issue 1.3 to avoid duplicate domain-type churn.

**Key files that would change:**
- `core/capacitor-core/src/domain/run_types.rs` -- add `idea_id: Option<String>` to `RunState` and `MutateRunCommand`
- `core/capacitor-core/src/reduce/run_reducer.rs` -- `handle_create` copies `idea_id`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` -- `RuntimeRunState` gains `ideaId`
- `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift` -- `resolve` gains `activeRunState` parameter; matches by `ideaId`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift` -- passes run state to the resolver
- `apps/swift/Sources/Capacitor/Models/AppState.swift` -- passes `ideaId` in the `Create` mutation

**Rough complexity:** Medium (combined with issue 1.3)

---

### 4.3 Idea text not threaded into dispatch prompt

This is the same issue as 3.3 (Codex Dispatch Issues > Idea context not threaded into dispatch prompt). The scratchpad lists it twice. See section 3.3 above for the full proposal.

---

## Implementation Priority & Dependency Graph

```
                        +-----------+
                        | 1.3 + 4.2 |  context_label + idea_id on RunState
                        +-----+-----+
                              |
                 +------------+------------+
                 |                         |
           +-----+-----+           +------+------+
           |    3.3     |           |     4.2     |
           | Idea ctx   |           | Resolver    |
           | in prompt  |           | wiring      |
           +-----+-----+           +------+------+
                 |
           (unblocked)
```

**Suggested order:**
1. **3.1** Sandbox fix (small, unblocks E2E testing entirely)
2. **1.2** RuntimeStatusReporter (medium, unblocks all status feedback)
3. **1.3 + 4.2** context_label + idea_id on RunState (medium, one domain-type PR)
4. **1.1** Card working state from runs (medium, depends on 1.2 for full effect)
5. **3.3** Idea context in prompts (small, depends on 1.3 for idea text source)
6. **3.2** Configurable timeout (medium, independent)
7. **2.1** MethodSelectorView restyle (small, independent)
8. **4.1** Run persistence investigation (small, independent)
