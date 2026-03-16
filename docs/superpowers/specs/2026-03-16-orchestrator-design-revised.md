# Capacitor Orchestrator Design (Revised)

**Date:** 2026-03-16
**Status:** Draft
**Supersedes:** `2026-03-15-orchestrator-design.md`

## Summary

Capacitor should still evolve toward a project-level "sous chef" that coordinates
substantial async work with minimal micromanagement. The important correction is
architectural: the filesystem remains the durable artifact store, but the local
runtime service remains the authoritative orchestration boundary.

This preserves the product vision while fixing the original draft's boundary,
identity, and recovery problems.

## Vision

The ADE space is drifting toward interfaces where the user micromanages a small
fleet of agents. Capacitor should make the opposite bet: as model capability
improves, the user should not need to manage the machinery directly.

Instead, each project gets a "sous chef": one persistent orchestrating agent
that interprets the user's intent, coordinates background work, and surfaces
only the moments that deserve attention.

Capacitor should still feel like a thin layer over Claude Code. It should lean
into Claude Code's strengths, not replace them:

- subagents for short bounded work
- `claude -p` for independent workers
- worktrees for isolation
- MCP for tool integration
- native Claude capabilities wherever they already solve the problem well

The architectural correction in this document should not change the desired
product feel. To the user, Capacitor should still feel like an extension of the
orchestrator's reach: the part that remembers, watches, routes, and presents.

## Decision Frame

### Goal

Give each project one persistent orchestration experience that can:

- translate user intent into parallelizable work
- keep substantial async work moving in the background
- surface only high-signal reviews and decisions
- recover cleanly across app restarts, worker exits, and session churn

### Problem

Capacitor today is excellent at routing the user back to the right terminal/tmux
context, but it does not yet provide a durable control plane for long-running,
multi-step async delegation. The missing piece is not "more UI." It is a
trustworthy orchestration model with explicit ownership, identity, and recovery.

### Invariants

1. The authenticated local runtime service remains the live application boundary.
2. Rust/runtime owns orchestration state reduction and typed read models.
3. Swift owns presentation, macOS side effects, and transport/composition-root work.
4. Human-readable files remain first-class artifacts for humans and agents.
5. Durable project identity is based on normalized project path and workspace identity, not display name.
6. One project has at most one active orchestrator conversation at a time.
7. Workers execute in git worktrees, but lifecycle truth does not depend on the worktree alone.
8. Recovery must be deterministic after app restart or worker process exit.

### Non-Goals

- Cross-project orchestration
- Remote/cloud execution
- Replacing Claude Code's native subagents or task model
- Building a kanban board or visible dependency editor
- Making the review UI a second full application surface

## Product Posture

These are product constraints, not optional polish. They should shape the
runtime contracts as much as the UI.

### Single face

The user talks to one entity per project: the orchestrator. Workers are an
implementation detail. Capacitor may mediate state and decisions behind the
scenes, but the experience presented to the user remains in the orchestrator's voice.

### Decisions and completions, not narration

The orchestrator should not narrate every step. It should surface:

- what is done
- what needs review
- what decision is needed
- what strong next step it recommends

### Proactive, but not noisy

The orchestrator should usually:

- recommend one strong direction
- ask questions only when the answer materially changes execution
- suggest next steps after work completes
- batch low-signal updates and interrupt only for meaningful reviews or choices

The orchestrator should not usually:

- dump internal agent chatter
- ask broad "what did you mean?" questions when it could propose a concrete read
- present a long menu of equally weighted options unless ambiguity is genuinely irreducible

### ADHD-friendly interaction

When the user needs to decide, Capacitor should prefer:

- one recommended path
- 2-4 concrete options
- predictive pivots rather than blank-slate questioning
- strong artifact-backed review rather than long prose

### Capacitor as orchestrator extension

Architecturally, the runtime service is the authority. Experientially, Capacitor
should feel like the orchestrator's extension into the filesystem, the review
surface, and the terminal environment.

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Pain |
|------|---------------|--------|---------|--------------|------|
| Runtime truth | `hud-hook` + `capacitor-core` | hook events, shell signals | authenticated `/runtime/*` reads | local runtime service | no orchestration reducer yet |
| Project identity | runtime/pathing layers | normalized project paths | project storage and routing keys | filesystem paths, workspace identity | cannot safely downgrade to display-name identity |
| Human-editable project state | `~/.capacitor/projects/...` idea storage and local files | user edits, agent edits | markdown artifacts | file watchers, atomic writes | current pattern does not yet cover worker lifecycles |
| Terminal/worktree operations | Swift app | user clicks, git state | routing side effects, worktree create/remove | tmux, AppleScript, git | no worker orchestration contract |

## Option Set

### Option A: File-Authoritative Orchestration

Workers and orchestrator write raw files directly. Capacitor watches them and
derives UI state from the filesystem.

**Why not chosen:** This reintroduces a split control plane. Files are excellent
durable artifacts, but they are a poor sole authority for lifecycle transitions
that require identity, ordering, replay, and typed failure handling.

### Option B: Runtime-Service-Owned Orchestration with Filesystem Artifacts

The runtime service owns orchestration state, journals transitions, and exposes
typed read models. Orchestrator/worker artifacts remain on disk in human-readable
form. MCP and UI are thin clients.

**Chosen:** This preserves Capacitor's current architecture while enabling the
desired async delegation UX.

### Option C: Lightweight Async Delegation Without Persistent Orchestrator

Add only review overlays and worker status lines to project cards.

**Why not chosen:** Lower risk, but it leaves the core product bet unfulfilled.
The value here is the project-level orchestrator experience, not just background jobs.

## Chosen Architecture

### Core Principle

**The filesystem is the durable artifact store. The runtime service is the
authoritative orchestration reducer.**

That means:

- humans and agents read and write durable context and review artifacts on disk
- the runtime service owns typed orchestration commands, events, state transitions, and queries
- the UI never reconstructs worker/orchestrator lifecycle by parsing ad hoc files

## System Overview

Four actors participate:

- **Orchestrator**: the interactive Claude Code session for one project
- **Workers**: headless `claude -p` conversations for substantial independent tasks
- **Runtime service**: the authoritative orchestration control plane and read model owner
- **Capacitor app**: the UI, terminal/worktree side-effect layer, and MCP transport host if needed

### Communication Flow

```text
User <-> Orchestrator session
            | MCP tools
     Capacitor MCP transport (thin adapter)
            | typed commands/queries
        Runtime service orchestration layer
         |                    |
         |                    +--> typed read models for UI
         |
         +--> spawn/resume/kill workers via app-side executors
                          |
                          +--> Workers write durable artifacts to disk
                          |
                          +--> Hook activity feeds runtime service
```

The important asymmetry is intentional:

- commands and state transitions flow through the runtime service
- artifacts and narrative context live on disk

## Ownership Boundaries

### Runtime service owns

- project orchestration state machines
- worker/orchestrator registry and identity
- append-only orchestration journal
- read models for project cards, worker state, milestone queues, and review state
- validation of machine-readable contracts

### Swift app owns

- launching and focusing terminals
- spawning local worker processes on behalf of the runtime service
- creating/removing git worktrees
- serving or presenting the review UI
- hosting the MCP transport if that is the simplest composition-root choice

### Orchestrator owns

- the conversational experience
- reading/writing durable project context
- deciding when to use subagents vs workers
- requesting orchestration actions through MCP tools

### Workers own

- code changes inside their assigned worktree
- progress/status reporting artifacts
- milestone artifacts for review

## Identity Model

### Project identity

Projects are keyed by:

- `project_path`: normalized absolute repo path
- `workspace_id`: existing workspace identity derived from the path
- `project_key`: the durable storage and API key derived from the normalized path

Storage directories use the existing encoded-path convention, not project name:

```text
~/.capacitor/projects/{encoded_project_path}/
```

Display name remains presentation only.

### Orchestrator identity

An orchestrator record has:

- `orchestrator_id`: durable ULID for Capacitor's own bookkeeping
- `project_key`
- `claude_session_id`: the Claude conversation ID
- `terminal_handle`: terminal app specific routing handle
- `state`: `launching | active | stale | closed`
- `last_seen_at`

The orchestrator becomes authoritative only after an explicit registration
handshake through MCP. Capacitor does not infer orchestrator identity from
process-tree inspection plus Claude metadata alone.

### Worker identity

A worker has three separate identities:

- `worker_id`: Capacitor's durable worker ULID
- `claude_session_id`: Claude's durable conversation identity across resumes
- `run_id`: one specific `claude -p` process invocation

`pid` is process metadata, not identity.

This separation matters because a worker may execute many runs over one Claude
conversation, and each run may have a different process ID.

## Orchestration State Model

### Worker lifecycle states

- `requested`
- `launching`
- `running`
- `waiting_for_review`
- `waiting_for_decision`
- `resuming`
- `completed`
- `failed`
- `cancelled`

These states are reduced from typed events, not guessed from raw files.

### Orchestration journal

Each project gets an append-only machine journal, written by the runtime service
with atomic append semantics:

```text
~/.capacitor/projects/{encoded_project_path}/runtime/orchestration-journal.jsonl
```

Representative events:

- `OrchestratorRegistered`
- `OrchestratorHeartbeatObserved`
- `WorkerRequested`
- `WorkerRunStarted`
- `WorkerRunExited`
- `WorkerHookActivityObserved`
- `WorkerStatusUpdated`
- `WorkerMilestonePublished`
- `MilestoneActionsGenerated`
- `MilestoneDecisionSubmitted`
- `WorkerCompleted`
- `WorkerFailed`
- `WorkerCancelled`

The journal is machine-local and authoritative. It is the replay source after restart.

## Filesystem Layout

```text
~/.capacitor/projects/{encoded_project_path}/
├── context/                              # sync-safe, human-readable
│   ├── memory.md
│   ├── daily/
│   │   └── 2026-03-16.md
│   ├── tasks.md
│   └── briefing/
│       └── template.md
├── artifacts/                            # sync-safe, human-readable review output
│   └── workers/
│       └── {worker_id}/
│           ├── briefing.md
│           ├── status.md
│           ├── milestones/
│           │   └── 01/
│           │       ├── brief.md
│           │       ├── manifest.json
│           │       ├── actions.json
│           │       └── artifacts/
│           └── decisions/
│               └── 01/
│                   ├── decision.json
│                   └── decision.md
└── runtime/                              # machine-local, authoritative
    ├── orchestration-journal.jsonl
    ├── read-model.json
    └── process-registry.json
```

### Sync policy

- `context/` and `artifacts/` are sync-safe and useful cross-machine.
- `runtime/` is machine-local and must not be treated as cross-machine truth.
- A second machine may render synced context/artifacts, but it may not adopt a
  live orchestrator or live worker without a future explicit handoff design.

## File Contract Rules

### Human-facing files

These are designed for humans and agents to read/edit naturally:

- `memory.md`
- daily logs
- `briefing.md`
- `status.md`
- milestone `brief.md`
- `decision.md`

The runtime service treats these as narrative artifacts, not lifecycle truth.

### Machine-facing files

These are versioned contracts:

- `manifest.json`
- `actions.json`
- `decision.json`
- `process-registry.json`
- `read-model.json`

Rules:

1. Every machine file carries a `schema_version`.
2. All writes are atomic temp-file-plus-rename writes.
3. Parsers are defensive and yield typed degradation states rather than crashing the control plane.
4. UI state depends only on runtime-service read models, never on direct ad hoc file parsing in SwiftUI.

### Markdown with machine significance

`tasks.md` is the only markdown file that may materially affect visible UI state.
If Capacitor reads it structurally, it must do so through an explicitly versioned
section format rather than arbitrary prose parsing.

## MCP and Runtime Surface

The MCP surface is a thin adapter over runtime-service commands and queries.

### Orchestrator-facing tools

- `capacitor_register_orchestrator(project_key, terminal_handle)`
- `capacitor_get_project_orchestration_state(project_key)`
- `capacitor_spawn_worker(project_key, briefing, worktree_policy, allowed_tools)`
- `capacitor_get_worker(worker_id)`
- `capacitor_list_workers(project_key)`
- `capacitor_resume_worker(worker_id, message)`
- `capacitor_cancel_worker(worker_id)`
- `capacitor_submit_task_update(project_key, task_patch)`
- `capacitor_project_status(project_key)`

If the MCP transport is hosted by the Swift app, it still forwards these calls
into the runtime service. The transport host is not the state owner.

## Session Bootstrap

When the user clicks a project card in orchestrator mode:

1. Capacitor resolves the stable `project_key`.
2. Capacitor reads durable context artifacts from `context/`.
3. Capacitor queries the runtime service for orchestration state for that project.
4. Capacitor assembles the system prompt from context artifacts plus runtime read models.
5. Capacitor launches or routes to a Claude Code session.
6. The first required orchestrator action is `capacitor_register_orchestrator(...)`.

If registration does not occur, Capacitor treats the session as an ordinary Claude
session in that project, not as the project orchestrator.

### Mise en place

At launch, Capacitor should prepare the station before handing control to the user:

1. Gather workflow context from `context/`
2. Gather live orchestration state from the runtime service
3. Gather project state such as git status, recent commits, PRs, and CI status
4. Assemble the orchestrator briefing from the editable template
5. Launch or reconnect to the project's orchestrator session
6. Let the orchestrator greet the user with a small set of prioritized next actions

The opening interaction should feel digestible and concrete, not like a blank terminal.

## Briefing Template

The orchestrator's behavior should remain mostly a briefing problem, not a hardcoded logic problem.

The template lives at:

```text
~/.capacitor/projects/{encoded_project_path}/context/briefing/template.md
```

It is editable by the user. Capacitor fills template slots at launch from durable
context plus runtime-service read models.

### Minimum viable template slots

```markdown
# Orchestrator Briefing — {{project_name}}

## Who You Are
You are the orchestrator for this project. You are the user's single point of
contact. Workers are implementation details. Present work in your voice.

## Workflow State
{{memory_md}}

## What Happened Recently
{{recent_daily_logs}}

## Active Tasks
{{tasks_md}}

## Project State
{{project_status}}

## Active Workers
{{worker_summary}}

## Behavioral Preferences
- Proactivity: suggest next steps after completing work
- Options: present 2-4 concrete choices when a decision is needed
- Review cadence: surface milestones as they arrive, batch minor updates
- Tone: confident, concise, collaborative
```

The important design idea is that orchestrator personality and operating style
should be customizable without changing orchestration code.

## Orchestrator Liveness and Reconnect

The authoritative signal is explicit orchestrator registration plus subsequent
heartbeats/activity observations recorded by the runtime service.

Signals, in priority order:

1. Explicit MCP registration for the project key
2. Recent hook activity for the registered Claude session
3. Runtime-service heartbeat age
4. Terminal/process inspection as a recovery hint, not as the source of truth

This avoids brittle identity inference from reused tabs or unrelated manual Claude sessions.

## Worker Execution Model

### Two-tier task model

- **Subagents** remain the default for short bounded tasks inside the orchestrator session.
- **Workers** are for tasks that need a separate context window, independent execution, or review checkpoints.

The determining factor is scope and autonomy, not raw algorithmic complexity. If
the task fits cleanly inside the orchestrator's current context window and does
not need independent execution, it should stay a subagent. If it needs its own
working memory, checkpointed review, or long-running isolation, it should become
a worker.

### Worktree policy

Each worker gets its own managed worktree under:

```text
{repo}/.capacitor/worktrees/{worker_id-or-slug}
```

The runtime service records:

- `worker_id`
- `project_key`
- `worktree_path`
- `base_commit`
- `branch_name`
- `claude_session_id`
- latest `run_id`

Worktrees isolate the default execution environment. They do not replace the need
for explicit worker identity, journaled lifecycle, or runtime-owned state.

## Worker Reporting Model

Workers still write:

- `status.md` for short human-readable progress
- milestone briefs and artifacts for review

But the authoritative lifecycle flow is:

1. Runtime service requests worker spawn.
2. Swift/app executor launches the worker process and reports `WorkerRunStarted`.
3. Hook activity is attributed to the worker's current run and appended to the journal.
4. Milestone artifacts appear on disk with a versioned `manifest.json`.
5. Runtime service ingests the milestone and emits `WorkerMilestonePublished`.
6. Worker exit becomes `WorkerRunExited`.
7. The reducer decides whether that means `waiting_for_decision`, `completed`, or `failed`.

This is the key correction to the original design: worker status is reduced from
typed events plus validated artifacts, not from the existence of one stale PID.

### Worker briefing convention

Workers are still briefed in natural language, but the runtime system should give
them a stable reporting contract.

The generated worker briefing should include:

- the task to complete
- scope boundaries
- files or directories to avoid
- the absolute artifact directory for progress and milestones
- the expectation that human-readable progress goes to `status.md`
- the expectation that review checkpoints publish milestone artifacts plus a machine `manifest.json`

Minimum shape:

```markdown
# Task
{{task_description}}

## Reporting

Write short progress updates to:
{{status_md_path}}

When you reach a meaningful checkpoint or need user input, publish a milestone under:
{{milestones_root}}

Each milestone must include:
- `brief.md` for humans
- `manifest.json` for the runtime service
- `artifacts/` for review materials

## Constraints
{{constraints}}

## Project Context
{{relevant_context}}
```

This is worth calling out explicitly because it is one of the most important
human factors in the system: the worker should know how to communicate progress
without the user needing to inspect raw Claude transcripts.

## Worker Health Monitoring

The orchestrator should still be able to reason about worker health, but it
should do so from runtime read models rather than improvised file inspection.

Useful signals include:

- elapsed time
- time since meaningful progress
- recent file activity
- tool-call error rate
- current lifecycle state
- latest short status update

The orchestrator can then decide whether to let the worker continue, ask the
user for guidance, or recommend cancellation/retry.

## Milestone Review Flow

### UX invariant

The user experiences one face: the orchestrator's voice.

### Control-plane invariant

The runtime service is the actual decision mediator because an interactive
Claude session cannot be programmatically injected at arbitrary times.

### Review sequence

1. A worker publishes milestone artifacts and a versioned milestone manifest.
2. The runtime service validates the milestone, appends a journal event, and
   creates a typed review read model.
3. Capacitor shows the project card in review-needed mode.
4. Clicking the card opens a local review surface on a separate trust boundary.
5. The review surface renders sanitized content and typed actions from the
   runtime-owned read model.
6. User action calls `submit_milestone_decision(...)` against the runtime service.
7. The runtime service:
   - appends `MilestoneDecisionSubmitted`
   - writes `decision.json` and `decision.md`
   - updates project orchestration state
   - resumes the worker if the action requires continuation
   - marks the decision discoverable to the orchestrator on its next state read

This keeps the orchestrator as the user-visible persona while making the control
path explicit and correct.

### Option generation

The review surface should still present smart, concrete next actions rather than
generic approve/reject buttons whenever possible.

Capacitor should generate these actions with a short headless Claude call using:

- the milestone `brief.md`
- the milestone artifact manifest and file paths
- project `tasks.md`
- project `memory.md`
- current worker summary from the runtime read model

Expected output is a small typed action set such as:

- one recommended path
- one or two predictive pivots
- one request-changes path
- one discuss/fallback path

If generation fails, Capacitor falls back to a generic but safe action set and
still renders the review surface.

## Review Surface Trust Boundary

The milestone review UI remains on a separate local origin from the runtime service.

Rules:

- worker-authored HTML is always sandboxed
- markdown is sanitized before rendering
- the review surface receives only the minimum typed review payload it needs
- the runtime service bearer-protected endpoints remain inaccessible to worker-authored content

## Project Card Modes

The project card continues to become the main project entry point, but every mode
is backed by a runtime-service read model:

- `default`: route to orchestrator or offer launch
- `active`: summarize orchestrator/worker state at the decisions-and-completions level
- `review_needed`: route to the review surface
- `stale_orchestrator`: offer reconnection/relaunch

The card no longer infers these modes from raw markdown or PID files in Swift.

## Orchestrator Mode

### ON

This is the full product experience:

- project-level orchestrator
- runtime-owned orchestration state
- worker lifecycle management
- milestone review flow
- durable project context

### OFF

This is the lightweight terminal-router posture:

- project cards route to terminals
- no orchestrator registration
- no worker orchestration
- no milestone review surface

This should remain a first-class mode for users who want Capacitor as a fast
terminal switcher and nothing more.

## Cost Controls

- Max concurrent workers per project: default 3
- No automatic infinite retry loops
- One action-generation run per project at a time
- Timeouts and stale-heartbeat policies are reducer-driven and visible in diagnostics

## Validation Spike

Before broad feature work, land a narrow proof slice that demonstrates the risky seams:

1. Launch an orchestrator and require explicit registration.
2. Spawn one worker into a worktree.
3. Publish one milestone with validated manifest/artifacts.
4. Submit one decision through the review surface.
5. Resume the worker and finish the task.
6. Restart Capacitor mid-flight and prove the runtime service reconstructs the same state from the journal.
7. Repeat with two repos that share the same display name and prove isolation.

If that spike fails, stop and reopen the architecture decision before building more UI.

## Verification Plan

### Automated

- reducer tests for orchestrator and worker state machines
- replay tests from orchestration journal fixtures
- contract tests for machine-readable milestone/decision files
- integration tests for restart recovery and same-name project isolation
- Swift tests for project-card mode projection using typed orchestration read models

### Manual

- open a project with an active orchestrator and verify reconnect without duplicate sessions
- kill Capacitor while a worker is running and verify clean recovery
- submit a milestone decision and verify the worker resumes without losing the decision record
- inspect the review UI with hostile HTML artifacts and verify sandbox containment

## Phased Rollout

### Phase 0: Validation spike

Prove identity, journal, milestone decision routing, and restart recovery.

### Phase 1: Runtime-service orchestration core

Add typed commands, journal, reducer, and read models behind feature flags.

### Phase 2: MCP adapter and orchestrator registration

Expose the thin orchestration tool surface and make project cards route through the new read models.

### Phase 3: Worker lifecycle and milestone review

Add spawn/resume/cancel, validated milestone ingestion, and the review surface.

### Phase 4: Orchestrator UX polish

Tune briefings, option generation, batching, and suggestion quality after the control plane is proven.

## What Stays from the Original Vision

- the orchestrator is still the project's conversational "single face"
- workers are still the mechanism for substantial independent tasks
- git worktrees are still the isolation unit
- review still happens through a rich local artifact surface
- the product still bets on delegation over micromanagement

## Open Questions

- Should the MCP transport live in Swift or be hosted directly by the runtime-service shell?
- How much of `tasks.md` should be structurally parsed versus treated as pure narrative context?
- Do we want a future explicit cross-machine worker handoff protocol, or is read-only continuity enough?
