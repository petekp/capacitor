# Capacitor Orchestrator Design (Revised)

> Doc role: `historical-design-spec`
> Status: Historical migration design. Current architecture lives in `.claude/docs/architecture-primer.md`, `docs/ARCHITECTURE.md`, `docs/architecture-decisions/004-dedicated-local-runtime-service.md`, and `AGENT_CHANGELOG.md`.
> Date: 2026-03-16
> Supersedes: `2026-03-15-orchestrator-design.md`
> Historical execution companion: `docs/historical/orchestrator-next-slices/AGENT_EXECUTION_PLAYBOOK.md`

## Summary

This document captures the orchestrator target that guided the runtime-core migration. It is preserved as design history, not as the canonical current-state spec.

Capacitor should evolve toward a project-level orchestrator: one persistent
interactive Claude session per project that coordinates substantial async work
without forcing the user to micromanage a fleet of agents.

The key architectural correction is:

- the filesystem remains the durable artifact store
- the authenticated local runtime service remains the authoritative orchestration boundary

This preserves the product feel while fixing the original draft's control-plane,
identity, and recovery problems.

## Product Vision

The product bet is not "better agent fleet management UI."
The product bet is that as model capability improves, the user should need less
visible machinery, not more.

Capacitor should therefore feel like a "sous chef" for each project:

- one conversational face
- substantial async work delegated to isolated workers
- only decisions, reviews, and completions surfaced back to the user
- low-signal activity kept in the background

Capacitor should remain a thin layer over Claude Code and lean into native
primitives that Claude Code already provides well:

- interactive sessions
- subagents
- `claude -p`
- worktrees
- MCP

## Decision Frame

### Goal

Give each project one persistent orchestration experience that can:

- translate user intent into parallelizable work
- keep substantial async work moving in the background
- surface only high-signal reviews and decisions
- recover cleanly across app restarts, worker exits, and session churn

### Problem

Capacitor already routes the user back to the right terminal/tmux context well.
What it does not yet have is a trustworthy control plane for long-running,
multi-step async delegation with explicit ownership, identity, and recovery.

### Invariants

1. The authenticated local runtime service remains the live application boundary.
2. Rust/runtime owns orchestration state reduction and typed read models.
3. Swift owns presentation, macOS side effects, and local composition-root concerns.
4. Human-readable files remain first-class durable artifacts for humans and agents.
5. Durable project identity is based on normalized project path and workspace identity, not display name.
6. One project has at most one active orchestrator conversation at a time.
7. Workers execute in git worktrees, but lifecycle truth does not depend on the worktree alone.
8. Recovery must be deterministic after app restart or worker process exit.

### Non-Goals

- cross-project orchestration
- remote/cloud execution
- replacing Claude Code's native subagents or task model
- building a kanban board or dependency editor
- treating the review UI as a second full application surface

## Product Posture

### Single Face

The user talks to one entity per project: the orchestrator.
Workers are implementation details.

### Decisions And Completions, Not Narration

The orchestrator should surface:

- what is done
- what needs review
- what decision is needed
- what strong next step it recommends

It should not narrate every internal step.

### Proactive, But Not Noisy

The orchestrator should usually:

- recommend one strong direction
- ask questions only when the answer materially changes execution
- suggest next steps after work completes
- batch low-signal updates

It should not usually:

- dump internal agent chatter
- ask broad blank-slate questions when it could propose a concrete read
- present large menus of equally weighted options unless ambiguity is genuinely irreducible

### ADHD-Friendly Interaction

When the user must decide, prefer:

- one recommended path
- a few concrete options
- predictive pivots rather than blank-slate questioning
- artifact-backed review rather than long prose

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Pain |
|------|---------------|--------|---------|--------------|------|
| Runtime truth | `hud-hook` + `capacitor-core` | hook events, shell signals | authenticated `/runtime/*` reads | local runtime service | no orchestration reducer yet |
| Project identity | runtime/pathing layers | normalized project paths | project storage and routing keys | filesystem paths, workspace identity | cannot safely downgrade to display-name identity |
| Human-editable project state | `~/.capacitor/projects/...` idea storage and local files | user edits, agent edits | durable artifacts | file watchers, atomic writes | current pattern does not yet cover worker lifecycles |
| Terminal/worktree operations | Swift app | user clicks, git state | routing side effects, worktree create/remove | tmux, AppleScript, git | no worker orchestration contract |

## Architecture Choice

### Rejected: File-Authoritative Orchestration

Workers and orchestrator write raw files directly, and Capacitor reconstructs
state from those files alone.

Why rejected:

- files are a good durability layer
- files are a poor sole authority for lifecycle transitions that require identity, ordering, replay, and typed failure handling

### Chosen: Runtime-Owned Orchestration With Filesystem Artifacts

The runtime service owns orchestration commands, events, state transitions, and
typed read models. The filesystem remains the durable artifact store for
human-readable context and review artifacts.

This preserves the existing repo architecture while enabling the product vision.

## Core Principle

**The filesystem is the durable artifact store. The runtime service is the authoritative orchestration reducer.**

That means:

- humans and agents read and write durable context and artifact files
- the runtime service owns typed orchestration state and queries
- the UI does not reconstruct worker/orchestrator lifecycle by parsing ad hoc files

## System Overview

Four actors participate:

- **Orchestrator**: the interactive Claude Code session for one project
- **Workers**: headless `claude -p` conversations for substantial independent tasks
- **Runtime service**: the authoritative orchestration control plane and read-model owner
- **Capacitor app**: the UI, worktree/process side-effect layer, and local transport host

### Communication Flow

```text
User <-> Orchestrator session
            | typed orchestration tool surface
     Capacitor transport adapter
            | typed commands / queries
        Runtime orchestration layer
         |                    |
         |                    +--> read models for UI
         |
         +--> spawn / resume / cancel workers via app-side executors
                          |
                          +--> workers write durable artifacts
                          |
                          +--> hook activity feeds runtime state
```

The asymmetry is intentional:

- commands and state transitions flow through the runtime service
- artifacts and narrative context live on disk

## Ownership Boundaries

### Runtime Service Owns

- project orchestration state machines
- worker/orchestrator registry and identity
- append-only orchestration journal
- read models for project cards, worker state, review state, and milestone queues
- validation of machine-readable contracts

### Swift App Owns

- launching and focusing terminals
- spawning local worker processes on behalf of the runtime service
- creating and removing git worktrees
- presenting the review surface
- transport/composition-root concerns

### Orchestrator Owns

- the conversational experience
- reading and writing durable project context
- deciding when to use subagents vs workers
- requesting orchestration actions through the runtime-facing tool surface

### Workers Own

- code changes inside their assigned worktree
- progress/status reporting artifacts
- milestone artifacts for review

## Identity Model

### Project Identity

Projects are keyed by:

- `project_path`
- `workspace_id`
- `project_key`

Storage uses the encoded-path convention under `~/.capacitor/projects/{encoded_project_path}/`.
Display name remains presentation only.

### Orchestrator Identity

An orchestrator record needs:

- project identity
- session identity
- registration time
- liveness state
- reconnect metadata

The orchestrator becomes authoritative only after explicit registration.
Capacitor must not infer orchestrator identity from loose terminal state alone.

### Worker Identity

A worker has three distinct identities:

- `worker_id`: Capacitor's durable identity for the delegated unit of work
- `session_id`: the Claude conversation identity used for `--resume`
- `run_id`: one concrete launched or resumed process episode

This separation is essential because one worker may span many runs over one
conversation identity.

## Orchestration State Model

The long-term model should explicitly represent:

- orchestrator lifecycle
- worker lifecycle
- milestone publication
- pending review state
- submitted decisions
- restart recovery from journaled events

The current delegation-loop state is a validated slice, not the final model.

## Filesystem Layout

Filesystem artifacts remain durable and human-readable.
Examples include:

- project context files
- worker milestone briefs
- worker manifests
- review decision artifacts

But these files are not, by themselves, the authoritative lifecycle model.

## Review Flow

### UX Invariant

The user experiences one face: the orchestrator's voice.

### Control-Plane Invariant

The runtime service mediates decisions because an interactive Claude session
cannot be programmatically injected at arbitrary times.

### High-Level Sequence

1. A worker publishes milestone artifacts.
2. The runtime service validates the milestone and creates a typed review read model.
3. Capacitor shows review-needed state.
4. The review surface renders the runtime-owned review payload.
5. The user submits a decision.
6. The runtime service records the decision, updates orchestration state, and resumes the worker if needed.
7. The orchestrator discovers the resulting state on its next read.

## Project Card Modes

The card should become the main project entry point, but each mode should be
runtime-derived:

- `default`
- `active`
- `review_needed`
- `stale_orchestrator`

The card should not infer orchestration lifecycle from raw files or PID guesses
in Swift.

## Orchestrator Mode

### ON

The full experience:

- project-level orchestrator
- runtime-owned orchestration state
- worker lifecycle management
- milestone review flow
- durable project context

### OFF

The lightweight terminal-router posture:

- project cards route to terminals
- no orchestrator registration
- no worker orchestration
- no milestone review surface

This remains a first-class mode for users who want Capacitor as a fast terminal
switcher and nothing more.

## Validation And Rollout

### Immediate Bridge Strategy

The current validated delegation loop should be preserved and re-homed under
this architecture, not discarded or forked into a parallel system.

### Recommended Slice Order

1. foundation hardening and spec convergence
2. runtime orchestration core
3. orchestrator registration and reconnect
4. re-home the validated delegation loop under the new control plane
5. improve review iteration quality
6. add controlled concurrency

Historical execution details live in `docs/historical/orchestrator-next-slices/AGENT_EXECUTION_PLAYBOOK.md`.

## What Must Stay True

- the orchestrator remains the project's single conversational face
- workers remain the mechanism for substantial independent tasks
- worktrees remain the isolation unit
- review remains artifact-backed and high-signal
- the product continues betting on delegation over micromanagement
