# Delegation Loop Validation Charter

## Mission

Validate Capacitor's async delegation loop with the narrowest architecture that
still exercises the real product value:

1. the user captures an idea with almost no friction
2. Capacitor starts meaningful background work in an isolated worktree
3. the project card becomes the home for async state
4. the user is brought back only for a concrete review/decision
5. the same worker resumes and completes after that decision

This slice intentionally validates the **delegation loop**, not the full
persistent project-orchestrator architecture.

## Why This Slice

The repo and prior exploration point to two different risks:

- We could overbuild an orchestration platform before proving the user loop is magical.
- We could underbuild and validate only a fake demo path that teaches us little.

This charter chooses the middle path:

- real worker execution
- real worktree isolation
- real runtime-owned slice state
- real project-card and review UX
- no persistent orchestrator session yet
- no MCP transport yet

If this slice is compelling, we can layer the persistent orchestrator on top of a
proven user loop instead of betting on it up front.

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Current Gap |
|------|---------------|--------|---------|--------------|-------------|
| Live runtime truth | `hud-hook` + `capacitor-core` | Claude hooks, shell signals | authenticated runtime reads | local runtime service | no worker/review reducer |
| Human-editable project state | `~/.capacitor/projects/...` | user edits, agent edits | markdown artifacts | file watchers, atomic writes | no machine-owned worker/review contract |
| Async capture entrypoint | Swift idea capture flow | quick user idea input | persisted ideas + UI surfaces | `ProjectFeatureCoordinator`, `ProjectDetailView`, idea queue | no delegation execution path |
| Project home surface | project cards | runtime snapshot + project data | active/idle card UI | `ProjectsView`, `ProjectCardView` | no async delegation state |
| Isolation boundary | Swift worktree services | git repo path | managed worktrees | `WorktreeService`, `WorkstreamsManager` | not yet connected to async agent work |

## Chosen Direction

### Architecture Shape

The first slice is **idea-capture-first and review-loop-first**:

- user starts from existing idea capture
- Capacitor turns one idea into one worker job
- runtime service owns minimal worker/review state for the slice
- worker writes durable artifacts to disk
- project card surfaces job state and review-needed status
- native in-app review screen handles the user decision
- worker resumes after the decision

### What We Are Explicitly Deferring

- persistent project orchestrator sessions
- orchestrator registration/liveness contracts
- MCP transport and tool surface
- multi-worker coordination
- generated review actions
- cross-machine adoption
- separate-origin local web review surface

## Option Comparison

### Option A: Full Orchestrator First

Persistent orchestrator, runtime-owned orchestration snapshot, worker lifecycle,
review flow, and MCP transport in the first slice.

**Rejected for first slice:** architecturally correct, but too likely to prove
infrastructure instead of product value.

### Option B: Swift-Only Proof

Keep all slice state in Swift and filesystem artifacts, then migrate later if
the loop proves valuable.

**Rejected for first slice:** fastest path, but knowingly violates the repo's
runtime-boundary direction and likely creates migration debt immediately.

### Option C: Delegation Loop with Minimal Runtime State

Add only the worker/review state needed for the loop into the runtime service,
reuse idea capture as the trigger, and keep review native in SwiftUI.

**Chosen:** smallest architecture that still validates the real product loop
without building on the wrong long-term boundary.

## Scope

### In Scope

- reuse existing idea capture as the trigger
- create one worker job from one idea
- run the worker in a managed git worktree
- store worker artifacts under the project's Capacitor storage directory
- add minimal runtime-owned job/review state and HTTP endpoints
- show delegation status on the project card
- open a native review surface from the card when user input is needed
- resume the same worker after the user submits a decision
- recover runtime-owned slice state after app restart

### Out of Scope

- a visible orchestrator chat/session owned by Capacitor
- multi-step approval/proposal loops before work starts
- multiple simultaneous workers per project
- generic task orchestration for arbitrary future features
- HTML prototype sandboxing
- LLM-generated review options
- final architecture for the full orchestrator mode

## End-to-End Slice Walkthrough

1. User captures an idea using the existing idea capture flow.
2. User chooses a new CTA to delegate that idea into execution.
3. Swift creates a managed worktree for the project.
4. Swift launches one real `claude -p` worker in that worktree with a fixed worker briefing.
5. Worker writes progress to `status.md`.
6. Worker reaches one review checkpoint and writes:
   - `brief.md`
   - `manifest.json`
   - review artifacts
7. Swift watcher forwards the milestone into the runtime service.
8. Runtime service marks the project as `review_needed`.
9. The project card shows that state and routes the user into a native review screen.
10. User chooses `Approve` or `Request changes` and can add short notes.
11. Swift writes the decision artifacts, resumes the same worker session, and forwards the decision mutation into the runtime service.
12. Worker finishes and the project card returns to a non-review state.

This is the only flow the slice needs to prove.

## Ownership Boundaries

### Runtime service owns

- slice-level worker and review state
- typed mutations for worker lifecycle and review decisions
- typed snapshot/read model consumed by the app
- restart recovery for the slice's state

### Swift app owns

- idea-capture entrypoint and user flow
- worktree creation and local process launch
- filesystem watching for worker artifacts
- native review screen
- card-state presentation and routing

### Worker owns

- code changes inside its worktree
- short progress updates in `status.md`
- one milestone publication using the defined artifact contract

## Invariants

- The local runtime service remains the authoritative owner of machine-readable slice state.
- The slice reuses the existing encoded-path project identity, never display-name identity.
- The slice must work with two projects that share the same display name.
- Worker execution always happens in a managed worktree.
- The worker/review loop is real; it must not be a fake stub path.
- Orchestrator-specific concepts must not leak into the first slice's public UX.
- When the slice flag is off, current terminal-router behavior remains unchanged.

## External Surfaces

- existing idea capture UI and persistence
- local runtime service HTTP endpoints
- managed git worktrees under `.capacitor/worktrees/`
- Claude hooks flowing into `hud-hook serve`
- one new worker launch/resume path via local `claude -p`
- project cards as the main async status surface

## Implementation Decisions

### Trigger

Use the existing idea capture flow as the only slice trigger. Do not add a new
top-level "orchestrator" or "delegate" product surface outside that path.

### Runtime model

Add a **minimal** worker/review model to `capacitor-core`, separate from current
session/routing state. Keep it intentionally narrow:

- project delegation state
- worker summary
- current review-needed milestone, if any

Do not introduce a general orchestration platform model in this slice.

### Worker identity

Use a Capacitor-owned `worker_id` plus a real Claude conversation/session ID.
The slice should be able to resume the same worker after review.

### Worker artifact contract

For the first slice, require:

- `status.md`
- `milestones/01/brief.md`
- `milestones/01/manifest.json`
- optional artifact files referenced by the manifest

Keep `manifest.json` versioned and machine-readable. Treat `brief.md` as
human-facing narrative.

### Review actions

Use a fixed action set:

- `Approve`
- `Request changes`

Optionally allow a short note field. Do not generate predictive pivots in this slice.

### Review surface

Use a native SwiftUI full-window modal/detail-style review screen. The separate
local web page remains a future upgrade, not part of this charter.

### Rollout

Gate the slice behind a new feature flag, enabled only in internal frontier/dev use.

## Guardrails

- Do not add MCP transport in this slice.
- Do not add orchestrator registration in this slice.
- Do not create parallel long-term and short-term state owners for the same worker/review facts.
- Keep machine-readable contracts narrow and versioned.
- Prefer additive runtime types/endpoints over reshaping existing session/routing contracts.
- Use the app's existing worktree and modal UI patterns instead of inventing parallel implementations.
- Delete or isolate any temporary glue once the slice proves or disproves the loop.

## Disqualifiers

Stop and reopen the architecture decision if any of these become true:

- the slice cannot validate the loop without adding persistent orchestrator ownership
- runtime-side slice state starts expanding into a generic orchestration platform
- Swift must become the authoritative owner of worker/review state to make progress
- the review loop requires generated options or a web sandbox to feel usable
- worker resume cannot reliably target the same Claude session

## Acceptance Criteria

The slice is successful only if all of the following are true:

1. A user can delegate one captured idea into one real worker run.
2. The project card shows a meaningful async state change while the worker runs.
3. The project card switches into a clear review-needed state when the worker publishes a milestone.
4. The review screen gives the user enough context to decide without reading Claude transcripts.
5. Submitting a decision resumes the same worker and changes visible state accordingly.
6. Restarting Capacitor does not lose the worker/review state for the slice.
7. The feature remains isolated behind a flag and does not regress current router behavior.

## Verification

### Automated

- reducer tests for slice-level worker/review state
- runtime endpoint tests for mutate + snapshot flow
- worker identity tests covering same-session resume
- Swift tests for card-state projection and review routing
- restart recovery tests using persisted runtime snapshot state

### Manual

- delegate one idea end to end
- review and approve it
- review and request changes on a second run
- confirm same-name projects do not collide
- restart the app mid-flow and confirm recovery

## Next Step After This Slice

If the slice proves compelling, the next architecture exploration should answer:

- whether to layer in a persistent orchestrator session
- whether the delegation loop feels complete without a conversational orchestrator, or whether users naturally want to talk to something
- whether MCP belongs in Swift or `hud-hook`
- whether review should graduate from native SwiftUI to a separate-origin local web surface

Those are second-phase questions. This charter intentionally avoids answering
them prematurely.
