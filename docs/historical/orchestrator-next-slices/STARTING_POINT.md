# Orchestrator Starting Point

> Doc role: `start-here`
> Status: Living synthesis as of 2026-03-16
> Scope: Consolidates the orchestrator vision, the current delegation-loop slice, and the scattered side-context discovered across related worktrees.

Action entrypoint: `docs/plans/orchestrator-next-slices/AGENT_EXECUTION_PLAYBOOK.md`

## Why This Document Exists

The orchestrator effort currently lives in three different forms:

1. product exploration
2. a narrow implemented vertical slice
3. a broader future architecture that has not yet landed on the current branch

This document puts those back into one mental model so the next slices can start
from the right boundary assumptions instead of re-deriving history.

## Executive Summary

The current branch does **not** contain the full orchestrator architecture.
What it contains is a real, working **delegation loop** slice:

- capture one idea
- launch one real `claude -p` worker
- isolate it in one managed git worktree
- surface review-needed state on the project card and idea queue
- let the user review in native SwiftUI
- resume the **same** Claude worker session after the review decision

This slice was intentionally chosen to validate the user loop before building
the full persistent orchestrator control plane.

The larger orchestrator vision still exists, but it lives mostly in an
unlanded revised spec and a few side worktrees. The main architectural lesson
from that spec is:

**The filesystem should remain the durable artifact store, but the local
runtime service should remain the authoritative orchestration boundary.**

## Hard Distinction: Orchestrator vs Workstreams

Do not conflate the new orchestrator work with the legacy `Workstreams` feature.

`Workstreams` is a separate, older feature whose job is basically:

- list managed worktrees
- create worktrees
- destroy worktrees
- open a worktree as a project

That feature lives in:

- `apps/swift/Sources/Capacitor/Models/WorkstreamsManager.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/WorkstreamsPanel.swift`
- `apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift`

The orchestrator/delegation work should reuse only the lower-level substrate:

- `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift`

Architecturally:

- `Workstreams` = CRUD over worktrees
- `Delegation loop` = lifecycle control over workers, reviews, and resume continuity
- `Orchestrator` = future project-level control plane over workers, reviews, context, and decisions

`Workstreams` is legacy, planned for excision, and should not be treated as a
feature we intend to keep developing or supporting. It is not the abstraction
to build the orchestrator on top of.

## Source Map

### Current branch sources

- `docs/plans/async-idea-delegation/EXPLORATION.md`
- `docs/plans/delegation-loop-validation/CHARTER.md`
- `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`
- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift`
- `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift`
- `apps/swift/Sources/Capacitor/Utilities/ProjectPrimaryActionResolver.swift`
- `core/capacitor-core/src/domain/types.rs`
- `core/capacitor-core/src/reduce/mod.rs`
- `core/capacitor-core/tests/delegation_contract.rs`

### Tracked architecture sources

- `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`

### Unlanded but still interesting sources

- The original March 15 draft remains useful only as superseded historical context in commit `d11aabd`.
- The full revised spec also exists in a related worktree copy:
  - `.capacitor/worktrees/delegation-09f5dc64/docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`
- A local-only proposal for richer review iteration exists in:
  - `.capacitor/worktrees/delegation-e5801d15/proposal-review-request-iteration-ux.md`
- A local-only experiment around session genealogy and teammate presence exists in:
  - `.capacitor/worktrees/delegation-54da230f/core/capacitor-core/src/domain/types.rs`
  - `.capacitor/worktrees/delegation-54da230f/core/capacitor-core/src/reduce/mod.rs`

### Stale or misleading surfaces

- The March 15 spec is superseded and should not be treated as the current architecture target.

## Timeline

### 2026-03-13: UX exploration

`docs/plans/async-idea-delegation/EXPLORATION.md` captured the product intuition:

- the user should feel like they are delegating, not managing
- the project card should become the async home surface
- the system should show one strong recommendation, not a mini task manager

This document is useful for product feel, but it is explicitly exploratory and
not the architecture spec.

### 2026-03-16 morning: full orchestrator thinking emerges

Commit `d11aabd` on `main` added two design docs:

- `2026-03-15-orchestrator-design.md`
- `2026-03-16-orchestrator-design-revised.md`

The first draft leaned too hard toward file-authoritative orchestration.
The revised draft corrected that and argued for runtime-service-owned
orchestration state with filesystem artifacts remaining durable and human-readable.

### 2026-03-16 late evening: the revised spec is landed on the current branch

The revised orchestrator spec is now tracked at:

- `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`

That spec should be treated as the current architecture target. The March 15
draft remains useful only as superseded historical context.

### 2026-03-16 early afternoon: the narrow slice lands

The delegation-loop implementation landed in a few steps:

- `46a3d61` - Add native delegation review loop
- `c65d1cc` - Normalize delegation artifact project keys
- `6dbbeff` - Wire delegation verifier rules into ledger
- `840b4cc` - PR rollup: Add native delegation review loop (#33)

### 2026-03-16 evening: stabilization pass

Current branch head:

- `2ce3435` - Stabilize delegation loop and surface idea queue status

This commit tightened the session-attach/resume behavior and surfaced delegation
status more clearly in the idea queue.

## What The Delegation Loop Slice Was Trying To Prove

The slice charter in `docs/plans/delegation-loop-validation/CHARTER.md` made an
important strategic choice:

- validate the user loop with the smallest architecture that still teaches us something real
- do **not** build the whole persistent orchestrator first

The charter's core bet was:

- use the runtime service for machine-readable slice state
- use Swift for worktree/process/review side effects
- keep the slice narrow enough that success or failure is legible

What was explicitly deferred:

- persistent project orchestrator sessions
- orchestrator registration/liveness
- MCP transport
- multi-worker coordination
- generated review actions
- the full future architecture

## What Is Actually Implemented On The Current Branch

### Runtime state model

The runtime side currently models one active delegation per project via:

- `ProjectDelegationState`
- `DelegationReviewState`
- `DelegationMutationKind`
- `DelegationReviewDecision`

These live in `core/capacitor-core/src/domain/types.rs` and are reduced in
`core/capacitor-core/src/reduce/mod.rs`.

Important current constraint:

- delegations are stored by normalized `project_path`
- that means the current model is effectively **one active delegation per project**

This is enough for the slice, but it is not yet a general orchestrator worker model.

### Swift side-effect owner

`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` currently owns:

- managed worktree creation
- worker artifact directory setup
- initial worker prompt creation
- `claude -p` launch
- session ID discovery from Claude stream JSON and session files
- writing review decision artifacts
- resuming the same Claude session
- reconciliation from on-disk milestone/completion artifacts back into runtime mutations

This is a good example of a useful architecture seam:

- Rust/runtime owns durable machine-readable lifecycle state
- Swift owns side effects and local platform/tool integration

That is the same seam the future orchestrator should preserve.

### User-facing surfaces

The slice adds:

- project-card routing into review when a delegation is `review_needed`
- idea-queue state projection for delegated work and review-ready status
- a native SwiftUI review screen

Key files:

- `apps/swift/Sources/Capacitor/Utilities/ProjectPrimaryActionResolver.swift`
- `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`

### End-to-end slice flow

The current implemented flow is:

1. User captures an idea.
2. `AppState.delegateIdea(...)` calls into `DelegationLoopManager.startDelegation(...)`.
3. A managed worktree is created under `.capacitor/worktrees/`.
4. A real `claude -p` worker is launched in that worktree.
5. Runtime receives a `start` mutation, then an `attach_session` mutation when session identity is discovered.
6. The worker writes milestone artifacts (`brief.md`, `manifest.json`).
7. Reconciliation notices those files and emits `review_ready`.
8. Project card and idea queue show review-needed state.
9. User reviews in `DelegationReviewView`.
10. Swift writes `decision.json` and `decision.md`.
11. Runtime receives a `resume` mutation.
12. Swift resumes the **same** worker session via `--resume`.
13. Worker eventually writes a completion marker.
14. Reconciliation emits `complete` and clears the active delegation from runtime state.

## What The Stabilization Commit Fixed

The most important stabilization work in `2ce3435` was not cosmetic. It fixed a
real continuity risk in the slice.

### The continuity problem

The slice only feels like one delegated conversation if the review loop resumes
the **same** Claude worker session after the human decision.

That means Capacitor must correctly:

- discover the session ID from stream JSON or session files
- backfill it into runtime state if missing
- avoid duplicate `attach_session` mutations
- notice when the discovered session differs from what runtime currently thinks

### What changed

`2ce3435` added:

- explicit `DelegationLoopError` cases
- better user-facing failure messages
- session attach deduping
- session reattach logic during reconcile
- backfilling of missing session IDs during review submission
- idea queue activity states:
  - generating title
  - delegated and working
  - ready for review
  - in progress

Architecturally, this matters because it reinforces that worker identity is not
"whatever process is around right now." It is a durable conversation identity
that must survive review interruption and app restarts.

## Verification State

The following targeted checks were run successfully while gathering this context:

- `swift test --filter DelegationLoopManagerTests`
- `swift test --filter IdeaQueueStatusResolverTests`
- `swift test --filter ProjectPrimaryActionResolverTests`
- `cargo test -p capacitor-core --test delegation_contract`

What those prove:

- worker session discovery works across stream/file paths
- session attach dedupe and reattach logic are covered
- project-card action routing is covered
- idea-queue state projection is covered
- runtime delegation state survives restart recovery

## Important Unlanded Context

### 1. Revised orchestrator architecture

The strongest articulation of the larger vision lives in the revised March 16 spec.

Its most important claims are:

- each project eventually gets one persistent orchestrator conversation
- the orchestrator is the user-facing "single face"
- the runtime service, not Swift or ad hoc files, should own orchestration state
- the filesystem remains the durable artifact store
- MCP should be a thin adapter over runtime commands and queries
- workers remain isolated in git worktrees
- the system should recover cleanly after app restarts or worker exits

This revised spec is the best starting point for future slices, even though it
has not yet been landed on the current branch.

### 2. Richer request-changes iteration

The local-only proposal in
`.capacitor/worktrees/delegation-e5801d15/proposal-review-request-iteration-ux.md`
argues that the current request-changes path is too coarse.

Its main idea is:

- when the reviewer requests changes, the worker should first acknowledge what
  it thinks changed
- then produce revision artifacts
- then return to review again instead of jumping straight to completion

This is a promising extension of the current slice because it deepens the
human-in-the-loop review contract without requiring the full orchestrator.

### 3. Session genealogy / teammate presence

The local-only changes in
`.capacitor/worktrees/delegation-54da230f/.../types.rs` and `reduce/mod.rs`
introduce:

- `SessionRelation`
- `SessionRelationKind`
- `TeammatePresence`

This looks like early groundwork for making session lineage and collaborator
presence visible to the runtime.

Why this matters for the orchestrator:

- a real orchestrator eventually needs to distinguish parent orchestrator sessions,
  worker sessions, subagents, and perhaps human teammates
- that is a graph problem, not just a list-of-sessions problem

This experiment is not yet integrated, but it points at the next-order state model.

## What Is Not Built Yet

The current branch does **not** yet implement:

- persistent orchestrator registration/liveness
- a runtime-owned orchestration journal
- MCP adapter and tool surface for orchestrator commands
- explicit orchestrator identity separate from worker identity
- multi-worker concurrency per project
- reducer-owned project card modes beyond the narrow delegation loop
- generated smart review actions
- the separate trust-boundary review origin described in the revised spec

The current review surface is native SwiftUI, which was the deliberate choice in
the slice charter.

## Architectural Lessons Worth Carrying Forward

### 1. Keep state ownership and side-effect ownership separate

The current slice works because it keeps a healthy split:

- runtime owns machine-readable truth
- Swift owns side effects

That is a classic distributed-systems boundary in miniature.

If the next slices let Swift become the authoritative owner of orchestration
truth, the app will become harder to recover and reason about after crashes.

### 2. Durable identity matters more than UI polish

The delegation loop only feels coherent because session identity is treated as
a first-class thing that must survive interruption.

This is a good reminder that in agent systems, "resume the same worker" is a
state/identity problem before it is a UX problem.

### 3. The current reducer is intentionally narrow

One active delegation per project was the right simplification for the slice.
It is probably the wrong long-term model for the orchestrator.

That means the next slices should not keep stretching the current reducer shape
until it accidentally becomes a generic orchestration platform without a clear redesign.

### 4. Reuse substrate, not feature baggage

`WorktreeService` is a reusable substrate.
`WorkstreamsManager` is feature baggage.

The orchestrator should reuse the former and avoid inheriting the latter.

## Good Starting Questions For The Next Slices

These are the questions the next planning pass should answer explicitly:

1. Do we first land the revised orchestrator spec onto the current branch as tracked docs?
2. What is the smallest runtime-owned orchestration model that extends the current single-delegation slice without creating migration debt?
3. Is the next most valuable slice:
   - richer review iteration on top of the current delegation loop
   - orchestrator identity and registration
   - a runtime orchestration journal
   - multi-worker support
4. Which parts of the March 16 revised spec are validation-spike material versus later product polish?
5. Should session genealogy / teammate presence become part of the orchestrator state model now, or remain a later enhancement?

## Recommended Reading Order For A Fresh Agent

1. `docs/plans/delegation-loop-validation/CHARTER.md`
2. `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`
3. `core/capacitor-core/src/domain/types.rs`
4. `core/capacitor-core/src/reduce/mod.rs`
5. `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift`
6. `apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift`
7. `core/capacitor-core/tests/delegation_contract.rs`
8. `docs/plans/async-idea-delegation/EXPLORATION.md`
9. The revised spec in commit `d11aabd` or the related worktree copy

## Bottom Line

The delegation loop slice is real, implemented, and stabilized enough to build on.

The orchestrator vision is also real, but it has not yet been translated into a
tracked, landed architecture on this branch.

The safest next move is to treat this document as the bridge:

- the current slice proves a real user loop
- the revised spec explains the correct long-term boundary
- `Workstreams` should be treated as legacy and kept out of the new design

That gives the next slice planning pass a clean starting point instead of a
scattered pile of branch archaeology.
