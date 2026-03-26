# Orchestrator Feature — Improvement Scratchpad

> Running list of UX and integration issues found during E2E testing (2026-03-25).
> Each item has a severity and a brief description of the desired behavior.

## Status & Feedback Loop

- **Card should show "working" state with striped animation during method execution**
  The project card already has a striped background animation for the `working` session state. A running method should trigger the same visual treatment. "Starting" as a chip label doesn't make sense — it should show the working state chip, and the descriptive context line under the project title should update periodically to reflect what's currently happening (e.g. "Composing prompt…", "Codex implementing…", "Waiting for checkpoint gate…").

- **Method runner needs to send AdvancePhase + periodic heartbeats**
  The method-runner subprocess doesn't update the runtime service during execution. The run stays `status=created` forever (card shows "Starting") because no `AdvancePhase` mutation is sent when the executor begins a phase. The `BridgeInteractiveIO` already has the service endpoint and auth token — extend it (or add a `RuntimeStatusReporter`) to emit phase transitions and step-level progress.

- **Context line should show idea title, not just method name**
  "Starting: Execute" tells you the method but not WHAT is being executed. The context line should include the idea title or a summary, e.g. "Running: Fix input width" or "Execute — composing prompt".

## Visual Polish

- **MethodSelectorView needs full redesign**
  The current implementation uses an opaque `Color.hudBackground` background and a fixed `frame(width: 380)` that breaks the panel's horizontal bounce. It looks nothing like the rest of the app. Needs to use the app's vibrancy/frosted glass system and respect the panel's natural sizing. Study `DelegationReviewView` and `IdeaDetailOverlay` for correct overlay patterns.

## Codex Dispatch Issues (found in E2E testing 2026-03-25)

- **Codex sandbox blocks writes to execution root**
  Codex's sandbox prevents writing to `~/.capacitor/runs/<runID>/...`. It falls back to writing handoffs in the repo's `handoffs/` directory instead. But the method-runner expects `last-message.txt` at the execution root path, so the step is marked as failed even though codex completed its work. Need to either: allow the execution root in codex's sandbox config, or have the method-runner detect alternative output locations.

- **Timeout needs to be per-method or configurable**
  `execution_only` with `--real` runs `swift test` + `cargo test` which takes 15+ minutes. The 900s default times out both attempts. Timeout should be configurable in the method YAML definition or scale with the task.

- **Idea context not threaded into dispatch prompt**
  The dispatch instruction is generic ("Implement the task"). The idea title and description should be injected so codex knows what to work on. Currently codex infers from the worktree state, which happened to work because our changes were already staged.

## Integration Gaps

- **Run state not persisting across service restarts**
  The runtime snapshot sometimes shows 0 runs even when a method-runner is actively running. The `mutateRun(create)` succeeds but the data may not survive a service restart. Needs investigation — likely a persistence/reload issue in the runtime service.

- **IdeaQueueStatusResolver has dead code for method runs**
  The `methodRunning` and `methodCheckpointReady` enum cases exist but are never produced — the resolver doesn't receive run state (runs are project-level, ideas are per-item). Either wire it up or remove the dead cases.

- **Idea text not threaded into dispatch prompt**
  The method-runner's dispatch instructions are generic ("Implement the task") with no idea-specific context. The idea title and description should be injected into the prompt so codex knows what to work on.
