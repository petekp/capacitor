# Orchestrator Execution Playbook

> Doc role: `authoritative-plan`
> Status: Active
> Last updated: 2026-03-16
> Intended audience: coding agents and humans executing the orchestrator migration

## Use This File First

If a future coding agent is given only one file for this effort, it should be
this one.

This playbook is intentionally self-contained. It captures:

- the mission
- the validated current state
- the target architecture
- the ubiquitous language
- the foundation-preparation work
- the next five implementation slices
- the required testing, ratcheting, and verification discipline

Companion files in the same directory exist to help execution stay structured,
but this file is the single-file entrypoint.

## Mission

Evolve Capacitor from a validated single-worker delegation loop into a
project-level orchestrator that:

- gives each project one persistent orchestration experience
- keeps substantial async work moving with minimal micromanagement
- surfaces only high-signal decisions and completions
- recovers cleanly across app restarts, session churn, and worker exits

## What Is Already True

The current branch has validated a real **delegation loop** slice:

- one idea can become one real `claude -p` worker
- that worker runs in one managed git worktree
- the runtime owns machine-readable delegation state
- Swift owns worktree/process/review side effects
- the user can review a milestone in native SwiftUI
- the same Claude worker session can be resumed after the review decision

This is proven by existing targeted tests:

- `cargo test -p capacitor-core --test delegation_contract`
- `swift test --package-path apps/swift --filter DelegationLoopManagerTests`
- `swift test --package-path apps/swift --filter IdeaQueueStatusResolverTests`
- `swift test --package-path apps/swift --filter ProjectPrimaryActionResolverTests`

## Target Architecture

The authoritative long-term target is the revised orchestrator architecture:

- filesystem artifacts remain durable and human-readable
- the authenticated local runtime service remains the authoritative orchestration boundary
- Swift remains the owner of presentation and local side effects
- the orchestrator is the user-visible single face
- workers remain isolated in git worktrees

The migration must preserve the good seam already present in the delegation loop:

- Rust/runtime owns machine-readable truth
- Swift owns local execution and side effects

## Ubiquitous Language

The full canonical glossary lives in `/Users/petepetrash/Code/capacitor/UBIQUITOUS_LANGUAGE.md`.
Use those terms exactly. The condensed version is:

| Term | Definition | Aliases To Avoid |
|---|---|---|
| **Project** | One normalized repository/workspace tracked by Capacitor | Repo card, workspace item |
| **Project Key** | The durable encoded-path identity for a project | Display name, project title |
| **Orchestrator** | The single interactive Claude session that represents a project | Main worker, assistant |
| **Worker** | A headless `claude -p` execution unit for substantial delegated work | Workstream, subagent |
| **Worker Session** | The Claude conversation identity used to resume a worker | PID, run |
| **Run** | One concrete launched or resumed process episode for a worker | Session |
| **Delegation Loop** | The validated vertical slice where one idea launches one worker, pauses for review, and resumes | Orchestrator mode |
| **Milestone** | A versioned checkpoint published by a worker for review | Proposal, draft |
| **Review** | A typed pending decision over a milestone | Modal state, interrupt |
| **Decision** | The human response that resolves a review | Comment, note |
| **Artifact** | A durable file published by the orchestrator or worker | Temp output |
| **Journal** | The append-only runtime record of orchestration events | Snapshot log |
| **Review Surface** | The UI surface that renders a pending review | Web sandbox, modal |
| **Worktree** | The git isolation unit for a worker | Workstream |
| **Workstreams** | Legacy worktree CRUD feature planned for excision | Worker system, orchestrator substrate |

### Language Rules

- Never use project display name as durable identity.
- Never use `workstream` to mean worker, worktree, or orchestrator activity.
- Distinguish **worker session** from **run**. A worker may survive multiple runs.
- Distinguish **delegation loop** from **orchestrator architecture**. The former is the validated slice; the latter is the larger target system.

## Hard Constraints

### Invariants

- The authenticated local runtime service remains the live application boundary.
- Rust/runtime owns orchestration state reduction and typed read models.
- Swift owns presentation, macOS side effects, and local transport/composition-root concerns.
- Human-readable files remain first-class artifacts for humans and agents.
- Durable identity is path-based, not display-name-based.
- One project has at most one active orchestrator conversation at a time.
- Workers execute in git worktrees.
- `Workstreams` is legacy and must not be used as the basis for new orchestrator design.

### Non-goals For This Plan Window

- Cross-project orchestration
- Remote/cloud execution
- A kanban/task-board UI
- Replacing Claude Code's native subagent/task model
- Building a second large product surface before the control plane is sound

## Session Protocol For Future Coding Agents

### Start Of Session

1. Read this file.
2. Read `/Users/petepetrash/Code/capacitor/UBIQUITOUS_LANGUAGE.md`.
3. Read:
   - `docs/plans/orchestrator-next-slices/CHARTER.md`
   - `docs/plans/orchestrator-next-slices/DECISIONS.md`
   - `docs/plans/orchestrator-next-slices/SLICES.yaml`
   - `docs/plans/orchestrator-next-slices/HANDOFF.md`
4. Run:
   - `bash docs/plans/orchestrator-next-slices/guard.sh --status`
5. Start the highest-priority unblocked slice.

### During A Slice

- Write or update the failing test first when a good seam exists.
- Carry deletions in the same slice as the replacement.
- Update `SLICES.yaml`, `MAP.csv`, and `DECISIONS.md` as part of the work, not after.
- If a slice reveals the architecture target is wrong, stop and add a decision entry before continuing.

### End Of Slice

- Run the slice-specific verification commands.
- Run the residue queries.
- Update `HANDOFF.md`.
- If budgets decrease, update `RATCHETS.yaml`.

## Foundation Preparation

This preparation work should happen before the first major implementation slice.
Some of it is already started by the control-plane package being created now.

### FP-1: Converge The Specs

Goal:

- land the revised orchestrator design onto the current branch as tracked source
- make the current authoritative docs unambiguous

Required outcomes:

- one tracked revised orchestrator spec on the current branch
- `STARTING_POINT.md` and this playbook point at the same target architecture
- stale or misleading doc surfaces are marked as non-authoritative or removed

Current status:

- complete

### FP-2: Freeze Terminology

Goal:

- enforce one domain language before architecture and state-model work widens

Required outcomes:

- `UBIQUITOUS_LANGUAGE.md` exists and is current
- new slices use canonical terms consistently
- ambiguous terms are called out explicitly in reviews and docs

Current status:

- initial glossary complete; future slices must keep it current

### FP-3: Quarantine Legacy Workstreams

Goal:

- make it hard for future agents to accidentally extend legacy `Workstreams`

Required outcomes:

- agent-facing warnings exist
- ratchets freeze the current `Workstreams` reference count or drive it downward
- new orchestrator work reuses only `WorktreeService`

Current status:

- initial quarantine is in place; future slices should only move the legacy counts downward

### FP-4: Prepare Verification And Control Plane Artifacts

Goal:

- have enough process scaffolding that future slices can be deterministic and resumable

Required outcomes:

- charter, slice ledger, decision log, map, ratchets, handoff, and ship checklist exist
- guard script runs
- verification commands are explicit, not implied

### FP-5: Design The Type Shell Before Broad Behavior Changes

Goal:

- define the minimum orchestration nouns and lifecycle seams before the codebase starts accreting ad hoc concepts

Required outcomes:

- the next implementation slice starts with a type- and state-machine shell
- worker identity, worker session identity, run identity, milestone, review, and decision are all explicit

## Priority And Scope

### slice-001: Foundation hardening and authoritative spec convergence

Goal:

- finish the foundation-prep work so the architecture target is explicit and legacy confusion is frozen

In scope:

- land revised orchestrator spec on current branch
- align `STARTING_POINT.md`, this playbook, `CHARTER.md`, and `DECISIONS.md`
- tighten `Workstreams` quarantine language and ratchets
- define the initial orchestration type shell in docs before code movement

Out of scope:

- runtime code changes to implement orchestrator behavior
- multi-worker support

Deletion targets:

- stale doc wording that implies file-authoritative orchestration
- stale doc wording that implies `Workstreams` is a living dependency
- empty or misleading local spec placeholders

Primary verification:

- `bash docs/plans/orchestrator-next-slices/guard.sh`
- doc residue queries in `SLICES.yaml`

Exit criterion:

- a future coding agent can read the current branch docs and arrive at one architectural conclusion

### slice-002: Runtime orchestration core

Goal:

- create the minimum runtime-owned orchestration shell that can support one orchestrator and one worker with deterministic recovery

In scope:

- runtime orchestration types
- orchestrator identity
- worker identity
- run identity
- journal/event vocabulary
- read-model vocabulary
- restart recovery tests

Out of scope:

- multi-worker scheduling
- smart review actions
- big UI changes

Likely touch surfaces:

- `core/capacitor-core/src/domain/types.rs`
- `core/capacitor-core/src/reduce/mod.rs`
- `core/capacitor-core/src/lib.rs`
- `core/capacitor-core/src/runtime_state/snapshot.rs`
- `core/capacitor-core/tests`
- `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`

Deletion targets:

- the assumption that one `ProjectDelegationState` keyed only by `project_path` is the long-term orchestration model

Primary verification:

- failing Rust contract tests first
- replay/restart recovery tests
- `cargo test -p capacitor-core`
- targeted Swift runtime decoding/bridge tests

Exit criterion:

- the runtime can represent orchestrator/worker identity explicitly without pretending the delegation loop model is the final architecture

### slice-003: Orchestrator registration and reconnect

Goal:

- make one project / one orchestrator conversation real

In scope:

- explicit orchestrator registration handshake
- minimal tool or transport seam required for registration
- liveness and reconnect semantics
- stale-orchestrator detection
- project-card routing to orchestrator when appropriate

Out of scope:

- broad worker scheduling
- generated review actions

Deletion targets:

- any ad hoc inference path that guesses orchestrator identity from files or tabs without explicit registration

Primary verification:

- reducer/state-machine tests for registration lifecycle
- Swift routing/reconnect tests
- focused manual check for duplicate-orchestrator prevention

Exit criterion:

- reopening a project with a live orchestrator reconnects cleanly without duplicate sessions

### slice-004: Re-home the validated delegation loop under the new control plane

Goal:

- keep the already-proven user loop, but route it through the real orchestrator architecture

In scope:

- idea -> worker spawn through runtime-owned orchestration commands
- milestone -> review read model through the new runtime shell
- decision submission -> worker resume through the new runtime shell
- preserve current user-visible delegation value

Out of scope:

- concurrency beyond one active worker

Deletion targets:

- slice-specific state ownership that is replaced by the new orchestration shell
- temporary compatibility glue added only to bridge old and new models

Primary verification:

- existing delegation-loop tests updated rather than duplicated
- runtime contract tests
- end-to-end regression of the current delegation loop behavior

Exit criterion:

- the delegation loop still works, but it now rides on the long-term control plane instead of a temporary slice model

### slice-005: Review iteration and decision quality

Goal:

- improve the human-in-the-loop quality of the review cycle before adding breadth

In scope:

- richer `request_changes` iteration
- worker acknowledgment artifact
- revision artifacts
- re-review loop
- optionally safe generated review actions with fallback

Out of scope:

- multi-worker orchestration
- cross-project state

Deletion targets:

- generic request-changes flow that assumes one note and one terminal completion is sufficient once revision flow replaces it

Primary verification:

- regression tests for request-changes -> revision -> re-review
- review-surface tests
- contract tests for revision artifacts

Exit criterion:

- the system can iterate on a milestone without forcing the user to restart from scratch

### slice-006: Controlled concurrency

Goal:

- move from one-worker-at-a-time assumptions to a small, explicit worker pool per project

In scope:

- multiple active workers per project
- per-project concurrency caps
- runtime read models for worker summaries
- cancellation/retry rules
- project-card summaries that remain calm and high-signal

Out of scope:

- cross-project orchestration
- user-visible dependency-graph editing

Deletion targets:

- single-active-delegation assumptions in runtime and Swift projections

Primary verification:

- state-machine tests for worker concurrency
- replay tests for interleaved worker events
- manual checks for project-card comprehensibility under >1 active worker

Exit criterion:

- the product can coordinate a small number of concurrent workers without becoming a fleet-management UI

## Testing And Verification Discipline

### TDD Rule

When a slice changes behavior, start with:

1. a failing test
2. or a failing verifier rule if the change is primarily structural

Do not start by editing implementation code unless the failing proof seam truly does not exist.

### Verification Ladder

Every implementation slice must define:

- targeted automated checks
- at least one residue query
- any manual-only checks
- exact deletion targets

Minimum recurring commands:

- `bash docs/plans/orchestrator-next-slices/guard.sh --status`
- `cargo test -p capacitor-core --test delegation_contract`
- `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests'`

Use fuller gates when the slice widens:

- `cargo test -p capacitor-core`
- `swift test --package-path apps/swift`
- `swift build --package-path apps/swift`
- `bash docs/plans/orchestrator-next-slices/SHIP_CHECKLIST.md`

### Ratchet Rule

Budgets can only decrease.

The initial ratchets focus on:

- legacy `Workstreams` reference count
- migration placeholder markers

Future slices should add ratchets for:

- dead compatibility names
- temporary bridge types
- stale orchestration-state aliases

### Residue Rule

A slice is not done just because the new path works.

A slice is done when:

- replaced code is deleted
- obsolete docs are updated or archived
- tests reference the canonical terms and owners
- the residue queries return zero matches

## Anti-Drift Rules

- Do not let Swift become the authoritative owner of orchestration truth.
- Do not treat display name as durable identity.
- Do not let `Workstreams` or its UI concepts creep into orchestrator naming.
- Do not add a second control plane “temporarily.”
- Do not preserve old names as compatibility aliases unless a decision entry explicitly allows it.

## Immediate Next Move

Start with `slice-002`.

The best next action is:

1. add the minimum orchestration type shell in runtime
2. write failing tests for explicit orchestrator/worker/run identity and restart recovery
3. keep the existing delegation-loop contracts green while the shell expands
4. only then widen behavior

## Supporting Files

These companion files are execution aids for this plan:

- `docs/plans/orchestrator-next-slices/CHARTER.md`
- `docs/plans/orchestrator-next-slices/DECISIONS.md`
- `docs/plans/orchestrator-next-slices/SLICES.yaml`
- `docs/plans/orchestrator-next-slices/MAP.csv`
- `docs/plans/orchestrator-next-slices/RATCHETS.yaml`
- `docs/plans/orchestrator-next-slices/TRANSLATION_GUIDE.md`
- `docs/plans/orchestrator-next-slices/HANDOFF.md`
- `docs/plans/orchestrator-next-slices/SHIP_CHECKLIST.md`
- `docs/plans/orchestrator-next-slices/guard.sh`

They should stay aligned with this playbook. If they drift, update them in the
same change.
