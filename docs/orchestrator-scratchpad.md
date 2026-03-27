# Orchestrator Feature — Improvement Scratchpad

> Running list of UX and integration issues found during E2E testing (2026-03-25).
> Each item has a severity and a brief description of the desired behavior.
> Updated 2026-03-27 after post-phase-3 fixes.

## Remaining Issues

### HIGH — Run state "0 runs" after service restart (FIXED 2026-03-27)
Snapshot persistence now has backup rotation (`app_snapshot.json.prev`), fallback loading on corrupt/missing primary, and diagnostic logging when a loaded snapshot has 0 runs. See `core/capacitor-core/src/storage/mod.rs`.

### HIGH — Codex sandbox blocks writes to execution root (FIXED 2026-03-27)
Codex dispatch now passes `--add-dir <execution_root>` to widen the sandbox. `find_handoff()` also searches repo `handoffs/` as a fallback. `CAPACITOR_EXECUTION_ROOT` added to env allowlist. See `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`.

### MEDIUM — Card working-state animation for method runs (IN PROGRESS)
The project card has a striped "working" animation for sessions but doesn't trigger it for method runs. `ProjectRunVisualStateResolver` resolves correctly — the gap is that `currentState` in `DockProjectCard` is a computed property with no SwiftUI change signal. Fix in progress: adding `@State` tracking with `.onChange(of: runVisualState)`.

## Resolved Items (Phase 1–3 Implementation Plan)

All 8 items from the orchestrator implementation plan shipped and pushed to `origin/main`:

- **AdvancePhase + periodic heartbeats** — `RuntimeStatusReporter` emits phase transitions and step-level progress (Items 3/4)
- **Context line shows idea title** — Idea identity fields (`idea_id`, `idea_title`, `idea_description`) threaded through `RunState` and into card context line (Item 6)
- **MethodSelectorView redesigned** — Glass overlay with vibrancy, respects panel sizing (Item 7)
- **Timeout configurable per-method** — `timeout_seconds` field in method YAML definition (Item 2)
- **Idea context threaded into dispatch prompt** — Idea title and description injected into worker prompt (Item 6)
- **IdeaQueueStatusResolver wired** — Resolver receives run state, `methodRunning` and `methodCheckpointReady` cases now active (Item 8)
- **Sandbox routing** — Item 1
- **Run-aware card visuals** — Item 5

## Resolved Duplicates

- "Idea text not threaded into dispatch prompt" (line 41) — duplicate of "Idea context not threaded into dispatch prompt" (line 30), both resolved as Item 6
