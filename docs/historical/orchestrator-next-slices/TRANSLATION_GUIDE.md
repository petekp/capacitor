# Translation Guide

> Doc role: `authoritative-plan`
> Status: Active

Use this file during implementation so the current validated delegation slice is
translated toward the larger orchestrator architecture instead of forked away
from it.

## Current Status

- The delegation loop is real and tested.
- The revised orchestrator architecture is now tracked on the current branch as the authoritative target spec.
- The first additive runtime orchestration shell is in place:
  - `ProjectOrchestratorState` exists as an explicit future-facing snapshot type
  - a tiny orchestrator mutation seam exists for `register`, `mark_stale`, and `clear`
  - `ActiveWorkerRunState` exists and is driven by current delegation mutations
- A typed orchestration event journal now rides alongside the snapshot so the runtime exposes both current state and recent transition history.
- A runtime-derived `project_orchestration_views` read model now exposes project-card modes such as `active`, `review_needed`, and `stale_orchestrator`.
- That runtime-owned `project_orchestration_views` read model now also carries the pending review payload and review action context when the mode is `review_needed`, plus `active_idea_id` when the mode is `active`, so cards, queues, and nearby review flows can trust one projection instead of treating raw delegation payload/state as a second lifecycle gate.
- The Swift read model now decodes orchestrators, active worker runs, orchestration events, and project orchestration views from the runtime snapshot, and project-card / idea-queue surfaces now consume that projection instead of inferring queue/review lifecycle directly from raw delegation status.
- The runtime service now exposes the minimal explicit orchestrator mutation transport, so future registration/reconnect work can use authenticated runtime requests instead of falling back to in-process-only mutation seams.
- Project-card primary action now reconnects explicit active/stale orchestrators via `claude --resume <session_id>` when runtime-owned orchestrator identity exists; plain terminal launch remains the fallback when it does not.
- Project-card open flow is now also the first trustworthy registration caller: explicit user open arms registration, but the runtime must later report exactly one exact-path root project session before Swift sends `register`.
- Active orchestrators now become stale through the same runtime-snapshot seam: Swift marks them stale only after two consecutive fresh snapshots miss the exact root-project `session_id`.
- This migration should evolve the current loop rather than replace it with a separate prototype.

## Current Surface -> Target Shape

| Current surface | Why it is transitional | Target shape |
|---|---|---|
| `ProjectDelegationState` keyed by `project_path` | Good enough for one active delegation, too narrow for long-term orchestration | Runtime-owned orchestration state with explicit orchestrator identity, worker identity, and run identity |
| `DelegationLoopManager` as the slice side-effect owner | Correctly owns worktree/process/review side effects, but the control path is too slice-specific | Keep local side effects here or a successor seam, but move machine-readable control semantics into the runtime orchestration core |
| `RuntimeDelegationState` | Useful current read model, but named and shaped for the narrow slice | Transitional worker/review projection inside a broader orchestration read model |
| `orchestration_events` in the runtime snapshot | Transitional journal shape carried inside the persisted snapshot, not a final dedicated journal store | Runtime-owned append-only orchestration journal and projections derived from its typed vocabulary |
| `project_orchestration_views` in the runtime snapshot | Transitional runtime-owned lifecycle summary for project cards and nearby UI surfaces; now includes pending review payload and review action context when a review is needed plus the active delegated idea identity when work is in flight | Broader orchestration read models where cards, queues, routing, review chrome, and review actions consume reducer-owned lifecycle summaries instead of re-deriving them in Swift |
| `POST /runtime/orchestrator/mutate` | Minimal explicit registration transport without policy yet | The authenticated runtime-facing orchestration tool surface used by orchestrator registration and reconnect flows |
| `brief.md` + `manifest.json` milestone contract | Already a good durable artifact contract | Keep milestone artifacts durable and versioned; let runtime validate and project them |
| `decision.json` + `decision.md` | Good durable decision artifacts | Keep them as durable artifacts, but have runtime own the state transition they represent |
| Project card / queue `review_needed` routing | Proven user-value surface | Preserve the UX, but derive it from the broader orchestration read model |
| Native SwiftUI review surface | Correct first trust boundary for the slice | Keep it unless and until a better separate trust-boundary surface is justified |
| `WorktreeService` | Good low-level isolation substrate | Keep and reuse |
| `WorkstreamsManager` / `WorkstreamsPanel` | Legacy feature abstraction with misleading overlap | Excise; do not migrate forward |

## Lookup Rule After The Migration

When the migration is healthy, the answer to "where does this fact live?" should be:

- durable human-readable narrative and artifacts: filesystem
- machine-readable orchestration truth: runtime service
- user-visible orchestration voice: orchestrator
- local execution, process launch, review presentation, and worktree side effects: Swift

## Naming Guidance

- Say **orchestrator** when you mean the persistent project-level interactive session.
- Say **worker** when you mean a headless delegated execution unit.
- Say **worktree** when you mean the git isolation unit.
- Say **workstreams** only when discussing the legacy feature slated for removal.
- Say **run** when you mean one launched/resumed process episode, not the enduring worker conversation identity.

## Edge Cases And Gotchas

- The delegation loop is a validated user loop, not the final architecture. Preserve its value without freezing its data model.
- The larger orchestrator should not be made file-authoritative just because artifacts are already on disk.
- Do not use display names for identity, especially in restart or same-name-project cases.
- A worker may survive many runs; process lifetime and conversation lifetime are different concepts.
- A worker session inside `.capacitor/worktrees/` can still project activity onto the pinned project in Swift. Registration must therefore use exact root-project session paths, not any session that happens to light up the project card.
- The same exact-path rule applies to liveness. Worker activity can coexist with a missing orchestrator, so stale marking must watch the registered orchestrator session specifically rather than treating any project activity as proof of life.
- Be careful about naming temporary bridge types. Temporary names are how accidental architectures become permanent.

## Suggested Translation Tests

- Existing delegation-loop tests still pass after the orchestration shell expands.
- Restart recovery keeps the same orchestrator and worker identities.
- Review readiness remains derivable through the new orchestration read model.
- Same-name projects stay isolated by path-based identity.
