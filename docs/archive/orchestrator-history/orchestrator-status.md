# Orchestrator Feature — Current State Assessment

**Date:** 2026-03-19
**Assessed against:** main @ 033db28

## What Actually Exists in Code

### Rust Core (`core/capacitor-core/src/`)
- `DelegationMutationKind`: Start, AttachSession, ReviewReady, Resume, Complete
- `ProjectDelegationState`: project_path, worker_id, idea_id, worktree, session_id, status, current_review
- `DelegationStatus`: Working, ReviewNeeded
- `DelegationReviewDecision`: Approve, RequestChanges
- `MutateDelegationCommand` with full delegation lifecycle
- Delegation reducer with proper rejection paths (returns `MutationOutcome { ok: false }`)

### Rust Server (`core/hud-hook/src/`)
- `POST /runtime/delegation/mutate` — authenticated mutation transport
- Returns `MutationOutcome` JSON, including rejection cases

### Swift App (`apps/swift/Sources/Capacitor/`)
- `DelegationLoopManager` — file-driven reconciliation: working → review_ready → complete
- `DelegationReviewView` — review UI for milestone review decisions
- `ProjectPrimaryActionResolver` — routes project card to review vs. terminal vs. reconnect
- `IdeaQueueStatusResolver` — resolves idea queue display state
- `RuntimeClient.mutateDelegation()` — now properly throws on reducer rejections (fixed 2026-03-19)

### What Works End-to-End
- Capture idea → delegate to worker → worker produces milestone → review ready
- Review UI shows milestone context, user can approve or request changes
- Approved delegations complete, request-changes resume the worker

## What Does NOT Exist (Despite Slice Tracker Claims)

The historical slice tracker (`docs/historical/orchestrator-next-slices/SLICES.yaml`) claims
slices 002 and 003 landed the following. **None of this exists in the codebase:**

- `ProjectOrchestratorState` type (no Rust struct, no Swift decoding)
- Orchestrator mutation kinds: register, mark_stale, clear
- Orchestrator registration handshake
- Orchestrator reconnect flow
- Append-only orchestration event journal
- `project_orchestration_views` read model
- `ActiveWorkerRunState` type

**Likely explanation:** These were either planned but never implemented, implemented on a
branch that was never merged, or removed during cleanup. The delegation loop works without
them — it uses `ProjectDelegationState` directly.

## Ship Review Bugs — Status

| Bug | Severity | Status |
|-----|----------|--------|
| Swift callers ignore MutationOutcome.ok | High | **Fixed** (033db28) |
| DelegationLoopManager cache poisoning | Medium | **Fixed** (via Bug 1 fix) |
| OrchestratorMutationKind::Clear ignores session_id | Medium | **N/A** (type doesn't exist) |
| Stale test name | Low | **N/A** (test was already renamed/removed) |
| Snapshot fsync barrier | Low | Open (not user-facing) |

## Honest Next Steps

The delegation loop works. The "orchestrator" layer described in the planning docs was
aspirational architecture that didn't land. The real question is: **what user-facing
feature needs to ship next?**

Options in order of user value:
1. **Review iteration** (slice 005 concept) — let users request changes and get a revised
   milestone without restarting the delegation. Currently request-changes is terminal.
2. **Controlled concurrency** (slice 006 concept) — multiple workers per project. This
   requires the orchestrator layer that doesn't exist yet.
3. **Build the orchestrator layer** (slices 002/003 as originally scoped) — explicit
   orchestrator identity, registration, reconnect. Prerequisite for concurrency but not
   for review iteration.

Recommendation: **Ship review iteration first** (it works with the existing delegation
model), then build the orchestrator layer when concurrency becomes the priority.
