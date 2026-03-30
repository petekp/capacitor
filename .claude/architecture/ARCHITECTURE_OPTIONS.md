> **Historical context** — This document uses "method" terminology from an earlier
> iteration of the orchestration system. As of 2026-03-29, the workflow surface
> has been extracted into the Circuit plugin (`~/Code/circuit`). The architectural
> concepts (runs, phases, checkpoints, involvement levels) remain valid; the
> implementation path is now `circuit:*` rather than `method:*`.

# Architecture Exploration: Human-Agent Work Orchestration

## Goal

Find the most elegant architecture for a local human-agent orchestration system that can:

- start from a vague or concrete idea
- select a context-appropriate **method**
- let the user choose an **involvement level**
- move through modular, swappable **phases**
- emit contextual **checkpoints** for human review
- treat **milestones** as an execution-specific checkpoint subtype
- carry durable context between coding sessions
- surface the right state and CTAs in the app without building a heavyweight workflow engine

## Problem

The system we want is broader than “background code execution” but narrower than a general-purpose workflow platform.

It needs to handle:

- ideation and shaping
- scoping and requirements
- execution and revision loops
- debugging, greenfield build, testing, and exploratory methods
- a user-controlled spectrum of involvement from highly autonomous to highly collaborative

The design challenge is to support all of that without:

- duplicating state across multiple orchestration systems
- turning prompts into the hidden source of truth
- coupling app UI too tightly to phase-specific behavior
- overbuilding a phase engine that exceeds the product’s real needs

## First Principles

These are the principles I would start from if we ignored the current implementation and asked what the cleanest system should be.

1. The durable unit is not a CLI session. It is a **run**.
2. The reusable planning unit is not a run. It is a **method template**.
3. The human interaction primitive is not “milestone.” It is **checkpoint**.
4. **Milestone** is one checkpoint kind, optimized for execution/revision work.
5. Human involvement is a **policy input**, not a phase type.
6. Sessions are **ephemeral executors**, not long-lived truth holders.
7. The runtime service should own the **live current view**; filesystem artifacts should own the **handoff content**.
8. Swapability comes from stable interfaces, not from arbitrary freedom. Modular phases must share a common contract.

## Vocabulary

- **Method** — a reusable workflow template for a task archetype
- **Phase** — a step inside a method
- **Method Instance** — the chosen method plus overrides for one run
- **Involvement Level** — how in the loop the user wants to be
- **Run** — the durable unit of progress for one delegated effort
- **Checkpoint** — a generic pause/resume packet for human input
- **Milestone** — a checkpoint kind used for execution/revision loops
- **Session** — an attached coding-agent process working on behalf of a run
- **Skill Hint** — a preferred skill/prompt policy input for a phase

## Invariants

- The authenticated local runtime service remains the live app boundary.
- Human-readable artifacts on disk remain first-class.
- The app must be able to launch work from an idea or task.
- The app must be able to show a sequence of phases and the active checkpoint.
- Methods must be swappable, compressible, and partially editable.
- Involvement level must be selectable independently of method choice.
- Skills must be attachable to phases as policy hints, not hard runtime truth.
- Checkpoints must support contextual CTAs.
- Milestones must remain a first-class execution concept, but not the only checkpoint kind.
- Sessions must be resumable/restartable without becoming the primary durable state.

## Non-Goals

- A general-purpose BPM/workflow product
- Cross-project orchestration
- Remote/cloud execution
- Arbitrary graph programming by end users in v1
- Replacing the runtime service with filesystem-only truth
- Treating every phase as equally rich or equally interactive

## Constraints

- Small team, fast iteration, low tolerance for concept sprawl
- Local-only architecture, filesystem artifacts, runtime service reads
- Low need for backward compatibility
- Strong preference for clear ownership and easy debugging
- The app should feel calm and legible, not like an ops console

## External Surfaces

- Idea capture UI in Swift
- Delegation start/resume flows in `AppState` / `DelegationLoopManager`
- Runtime mutation transport via `/runtime/delegation/mutate`
- Claude/Codex CLI session launch and resume
- Review UI in `DelegationReviewWindow`
- Filesystem artifacts under `~/.capacitor/`
- Method selection UI and involvement-level selection UI (future)

## Decision Horizon

Optimize for the next 12-24 months:

- enough structure to support multiple method families and richer app surfaces
- not so much infrastructure that we effectively build a workflow platform

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Pain |
|------|---------------|--------|---------|--------------|------|
| Idea capture | Swift idea UI | freeform text | saved idea | app UI only | no method or involvement selection yet |
| Delegation launch | `AppState` + `DelegationLoopManager` | project, idea | worktree, launch prompt, runtime start/attach | git, Claude CLI, runtime service | execution-first semantics are baked in |
| Review contract | `DelegationReviewManifest` + review UI | manifest, brief, diff | approve/request changes CTAs | JSON manifest schema | strongly milestone-shaped today |
| Resume flow | `acceptReviewDecision` + `buildResumePrompt` | decision, note, current review | decision files, resume prompt, runtime resume | session discovery, prompt builder | works well, but is tied to milestone/review assumptions |
| Runtime truth | Rust reducer + hud-hook | typed mutations | current delegation state | runtime service | good live boundary, narrow domain shape |
| Generic pipeline design | `.pipeline/` docs + scripts | missions, constraints, phases | state, events, packets | scripts + manage-codex relay | broader than current product need, unresolved authority complexity |

## Option 1: Extend the Current Delegation Relay

### Architecture Shape

Keep the current delegation root and review loop, then add:

- method metadata
- involvement level
- generic checkpoint kinds
- editable phase lists

This is the lowest-disruption path. It uses the current execution-oriented flow as the backbone and incrementally teaches it new concepts.

### Why It Might Work

- reuses the most working code
- fast to land
- good if the current architecture is already “close enough”

### Tradeoffs

- low migration cost
- highest risk of carrying forward execution-first assumptions
- elegant only if the new concepts remain thin

### Failure Modes

| Failure Mode | Warning Signal | Prevention |
|--------------|----------------|------------|
| Early conceptual phases feel bolted on | shaping/scoping checkpoints keep fighting milestone semantics | introduce generic checkpoint envelope early |
| Method support becomes metadata pasted onto an execution system | more conditionals in Swift keyed to phase names | centralize phase/method policy in one interpreter layer |
| The system inherits too much current file choreography | prompts and file names remain the hidden contract | extract explicit packet schemas |

### Disqualifiers

- wrong choice if we want a conceptually clean reset
- wrong choice if the current worker-root shape is the wrong durable unit

### Cleanup / Migration Implications

- lowest code churn
- highest chance of vestigial semantics surviving

### Unknowns

- whether the current execution-first model can gracefully absorb conceptual checkpoints

## Option 2: Run Kernel with Methods and Checkpoints

### Architecture Shape

Make **Run** the core durable object.

At run creation:

- choose a `task_archetype`
- choose a `method`
- choose an `involvement_level`
- apply overrides
- instantiate the run’s phase list

During execution:

- sessions attach to the run
- phases may emit checkpoints according to checkpoint policy
- human decisions advance, revise, or redirect the run

Core model:

- `Run`
- `MethodTemplate`
- `PhaseInstance`
- `Checkpoint`
- `Decision`
- `Session`

Runtime service owns the current run view:

- current phase
- active checkpoint
- attached session state
- run status

Filesystem owns the handoff artifacts:

- checkpoint packets
- briefs
- decisions
- prompts

Milestones become:

- `checkpoint_kind = implementation_milestone`
- optionally numbered
- repeated inside execution/revision loops

### Why It Might Work

This is the cleanest first-principles model. It makes the durable thing a run, the reusable thing a method, and the human-interaction thing a checkpoint.

### Tradeoffs

- sharper boundaries than the current system
- clean conceptual fit for contextual methods and checkpoints
- larger migration than Option 1
- still substantially simpler than a full workflow engine

### Failure Modes

| Failure Mode | Warning Signal | Prevention |
|--------------|----------------|------------|
| Run becomes an overstuffed god-object | `run.json` keeps absorbing every concern | keep run state to current view + references, not full history |
| Too much policy leaks into runtime truth | runtime starts depending on exact skill names or method internals | treat methods and skills as inputs to run instantiation, not live truth |
| Checkpoint taxonomy grows without discipline | many one-off checkpoint kinds appear | use a small closed set of checkpoint kinds with shared envelope |

### Disqualifiers

- wrong choice if we are not willing to migrate away from worker-root-first assumptions
- wrong choice if the team wants only a narrow execution improvement, not a broader architecture reset

### Cleanup / Migration Implications

- moderate migration
- strong deletion story if adopted fully
- requires explicit mapping from current delegation state to run state

### Unknowns

- whether run-rooted storage is better than worker-rooted storage for our near-term needs
- how much run history the app actually needs live

## Option 3: Declarative Method Engine

### Architecture Shape

Treat methods as declarative state machines or DAGs.

Each phase declares:

- inputs
- outputs
- checkpoint policy
- skill hints
- transition rules

A generic engine interprets the method graph and advances the run.

### Why It Might Work

This is the strongest answer if long-term flexibility and pluggable methods are the primary goal.

### Tradeoffs

- maximum modularity
- strongest swapability story
- highest concept count
- easy to overshoot the product need

### Failure Modes

| Failure Mode | Warning Signal | Prevention |
|--------------|----------------|------------|
| Engine work dominates product work | more time spent on graph semantics than UX | cap method power to ordered lists plus simple gates initially |
| Every phase becomes a plugin project | custom adapters proliferate | standardize one phase interface and one checkpoint envelope |
| The architecture becomes elegant on paper but cumbersome in use | method editing is harder than using the system | design the quick mode first, advanced editing second |

### Disqualifiers

- wrong choice if we care more about elegance-through-restraint than elegance-through-abstraction
- wrong choice if the team does not actually need user-defined workflow programming

### Cleanup / Migration Implications

- largest migration and design burden
- strongest long-term generality if it works

### Unknowns

- whether ordered-list methods plus checkpoint policy are already sufficient

## Option 4: Split Conceptual Work and Execution into Two Systems

### Architecture Shape

Admit that early conceptual work and execution are fundamentally different, and model them as two separate subsystems:

- **Concept Studio**
  - shape, explore, scope, requirements
  - emits proposal/alignment checkpoints
- **Execution Loop**
  - implement, revise, test
  - emits milestones

The handoff between them is explicit: once a conceptual flow is approved, it creates an execution packet.

### Why It Might Work

This fits the intuition that “conceptual stages feel different” and may deserve their own UX.

### Tradeoffs

- clearest UX separation between thinking and building
- least unified data model
- introduces a major seam between systems

### Failure Modes

| Failure Mode | Warning Signal | Prevention |
|--------------|----------------|------------|
| Duplicate pause/resume machinery emerges | both systems invent checkpoints, decisions, and prompts | share one checkpoint envelope even if systems differ |
| Handoff between systems becomes brittle | conceptual approval does not map cleanly into execution input | define one explicit execution packet contract |
| Users feel like they are switching products mid-flow | app UI radically changes between stages | preserve one project/run surface with different modes |

### Disqualifiers

- wrong choice if one integrated app experience matters most
- wrong choice if we want one durable abstraction for idea-to-execution work

### Cleanup / Migration Implications

- medium-high migration
- requires two coherent subsystems instead of one coherent kernel

### Unknowns

- whether the conceptual/execution distinction is strong enough to justify a system split

## Tradeoff Matrix

| Dimension | Option 1: Extend Current Relay | Option 2: Run Kernel | Option 3: Declarative Method Engine | Option 4: Split Conceptual + Execution |
|-----------|-------------------------------|----------------------|-------------------------------------|----------------------------------------|
| Simplicity | Medium — low churn, but carries current assumptions | High — one clean kernel and a small vocabulary | Low-Medium — elegant but more abstract | Medium — conceptually simple, structurally split |
| Boundary Clarity | Medium | High | High | Medium |
| Migration Difficulty | Low | Medium | High | Medium-High |
| Cleanup Burden | High — vestigial semantics likely | Medium-Low — clearer replacement boundary | Medium | Medium-High |
| Operability | Medium | High | Medium | Medium |
| Testability | Medium | High | Medium-High | Medium |
| Long-Term Flexibility | Medium | High | Highest | Medium |
| Risk of Overbuilding | Medium | Low-Medium | High | Medium |
| Product Legibility | Medium | High | Medium | High in UX, lower in architecture |

## Must-Be-True Assumptions

| Assumption | Why It Matters | How to Verify | Fastest Disproof |
|------------|----------------|---------------|------------------|
| A single integrated app experience matters more than strict separation between conceptual and execution work | favors Options 1 or 2 over 4 | review target product UX | users clearly prefer two different surfaces/modes |
| Methods can be modeled as ordered phases with simple checkpoint policies, at least initially | keeps us out of workflow-engine territory | prototype 3-4 real methods | first real methods demand branching/statechart power |
| A generic checkpoint envelope can cover both proposal checkpoints and implementation milestones | supports unified review UI and resume semantics | model two concrete examples side by side | they require incompatible packet shapes |
| The runtime only needs current run truth, not full orchestration history | keeps the kernel small | inspect intended app surfaces | app needs deep historical timelines as first-class UX |
| Sessions are best treated as ephemeral executors | supports run-first design | inspect failure/recovery cases | session identity turns out to be the real durable unit |

## Risk Register

| Risk | Option(s) Affected | Likelihood | Impact | Mitigation |
|------|--------------------|------------|--------|------------|
| Current implementation details bias the architecture too much | 1 | High | Medium | stress-test against first principles, not file reuse |
| Unified checkpoint model is too broad and becomes vague | 2, 3 | Medium | High | keep checkpoint envelope small and typed |
| Method system grows into a general workflow platform | 2, 3 | Medium | High | constrain method power deliberately |
| Conceptual and execution work really do need different systems | 2 | Medium | Medium-High | run a proof with both checkpoint kinds before committing |
| Split system creates a bad handoff seam | 4 | Medium | High | only choose 4 if the seam is clearly worth it |

## Validation Spikes

| Spike | Question Answered | Cost | Success Signal | Failure Signal |
|-------|-------------------|------|----------------|----------------|
| Design a minimal `Run` schema plus one `MethodTemplate` and two `Checkpoint` examples (`proposal_checkpoint`, `implementation_milestone`) | Can one kernel cleanly unify conceptual and execution work? | Low | the same envelope and run model fits both examples cleanly | the examples immediately fork into incompatible models |
| Prototype one `deep_debug` method and one `greenfield_build` method as ordered phase lists with checkpoint policy | Are ordered methods enough, or do we need a graph engine? | Low | both methods feel natural without branching semantics | real methods demand graph/statechart power |
| UI spike: render a generic active checkpoint panel that handles one conceptual checkpoint and one milestone | Can the app support a unified checkpoint model without awkward UX? | Low-Medium | both kinds feel natural in one frame | the UI wants separate systems |
| Recovery spike: detach and resume a session while preserving run truth and active checkpoint | Does run-first state stay cleaner than session-first state? | Low-Medium | recovery reasoning stays simple | session identity keeps leaking back into the model |

## Recommendation

**Recommended option: Option 2, Run Kernel with Methods and Checkpoints.**

## Runner-Up

**Option 4: Split Conceptual Work and Execution into Two Systems.**

## Why It Wins

Option 2 is the best balance of elegance, modularity, and restraint.

It preserves the important distinctions:

- methods are reusable templates
- involvement level is policy
- checkpoints are generic human sync points
- milestones are execution checkpoints
- sessions are ephemeral executors

And it does so without creating either:

- a heavyweight workflow engine, or
- two separate subsystems with a brittle handoff seam

From first principles, this is the cleanest object model:

- **Run** is durable progress
- **Method** is reusable structure
- **Checkpoint** is human collaboration
- **Session** is transport/execution

That is a stronger conceptual center than either the current execution-first relay or a generalized pipeline.

## Why The Runner-Up Loses

Option 4 has a real appeal: early conceptual work does feel different from execution. But the system-level cost is high. It duplicates orchestration ideas and introduces a seam exactly where we most want continuity: turning human-aligned concept work into execution.

If the app later proves that conceptual and execution flows truly need separate major surfaces, Option 4 could still become the UI presentation. But it is a worse core architecture than Option 2.

## Why The Other Options Lose

- **Option 1** loses because it over-indexes on the current implementation. It is practical, but not the most elegant.
- **Option 3** loses because it is too much engine for the current product. It maximizes theoretical modularity at the cost of concept count and migration burden.

## What Could Change The Recommendation

- Strong evidence that conceptual checkpoints and implementation milestones cannot share one checkpoint envelope
- A hard requirement for user-programmable branching methods
- A clear product direction toward separate “concept studio” and “execution studio” experiences
- A need for deep historical orchestration analytics, which would push toward a richer event model

## What Must Be Validated Before Committing

- that a unified checkpoint envelope really works for both conceptual and execution flows
- that ordered methods plus checkpoint policy are enough
- that run-first state is cleaner than session-first state in recovery scenarios

## Decision Needed

Choose whether the core durable abstraction should be:

1. the **current delegation relay**,
2. a **Run kernel with methods and checkpoints**,
3. a **declarative workflow engine**, or
4. **two separate systems for conceptual and execution work**.

My recommendation is to commit to **Run kernel with methods and checkpoints** unless the validation spikes disprove the unified checkpoint model.

## Handoff to audit-and-migrate

### Chosen Architecture

Run kernel with:

- `Run`
- `MethodTemplate`
- `PhaseInstance`
- `Checkpoint`
- `Decision`
- `Session`

where milestones are `implementation_milestone` checkpoints.

### Decision Rationale

This architecture gives the cleanest separation of durable progress, reusable workflow structure, human review points, and ephemeral execution sessions, while staying lighter than a full workflow engine.

### Invariants

- runtime service owns live current truth
- filesystem artifacts own human/session handoff content
- methods are modular and editable
- involvement level is independent of method choice
- checkpoints are generic
- milestones are execution checkpoint subtype

### Non-Goals

- general workflow platform
- cross-project orchestration
- remote/cloud execution
- arbitrary graph programming in v1

### Critical Workflows

- capture idea and choose context
- choose method
- choose involvement level
- instantiate run
- attach session to current phase
- emit checkpoint
- review checkpoint
- resume or redirect next session

### External Surfaces

- idea capture UI
- method selection UI
- involvement-level selection UI
- runtime delegation mutations
- checkpoint review UI
- CLI session launch/resume

### Known Hotspots

- `DelegationLoopManager`
- `DelegationReviewManifest`
- `DelegationReviewWindow`
- current `.pipeline/` scripts/docs
- runtime reducer surfaces around delegation state

### Leading Migration Risks

- carrying forward too much of the execution-first implementation
- under-specifying the checkpoint envelope
- allowing methods to grow into a workflow engine by accident

### Expected Deletion Zones

- `.pipeline/` concepts on the product path
- execution-only milestone assumptions in generalized UI/state
- duplicated prompt/file contracts that should move into explicit packet schemas

### Validation Spikes Already Run

- none

### What Still Needs Proof

- minimal run schema
- minimal checkpoint envelope
- method expressiveness limits
- recovery behavior for run-first state
