# Hook Runtime Pre-Migration Design Package

Status: Proposed  
Date: 2026-03-09  
Authoring mode: Clean Architecture first pass, followed by stress-test hardening

## Purpose

This package defines the target architecture for Capacitor's Claude/runtime tracking system before any migration work begins.

The goal is to prevent the current hook system from quietly dictating the next architecture. We want a target that is:

1. Truthful to the product.
2. Clean at the boundaries.
3. Resilient to Claude contract changes.
4. Safe to migrate toward in small slices.

## Why We Are Doing This First

The current system has a real contract mismatch: Capacitor installs HTTP hooks for some events that Claude currently documents as command-only.

That means "cleaning up the existing design" is not enough. If we start migrating without first agreeing on a target model, we risk preserving the wrong assumptions in a nicer shape.

## Inputs

This proposal is shaped by four sources:

1. Current rewrite invariants in [rewrite/CHARTER.md](/Users/petepetrash/Code/capacitor/rewrite/CHARTER.md).
2. Accepted runtime authority decision in [ADR-003](/Users/petepetrash/Code/capacitor/docs/architecture-decisions/003-sidecar-architecture-pattern.md).
3. Rewrite governance in [rewrite/PLAYBOOK.md](/Users/petepetrash/Code/capacitor/rewrite/PLAYBOOK.md).
4. Current external Claude hook contract in [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks), checked on 2026-03-09.

## Relationship To Existing Rewrite Decisions

Most of this package is aligned with the rewrite program:

1. Rust still owns domain semantics.
2. Swift still owns rendering and macOS side effects.
3. Adapters stay thin.
4. Acceptance still relies on replay, smoke, and deletion discipline.

One part is not automatically aligned:

1. [rewrite/DECISIONS.md](/Users/petepetrash/Code/capacitor/rewrite/DECISIONS.md) currently locks `D-001: No Daemon Core`.
2. [ADR-003](/Users/petepetrash/Code/capacitor/docs/architecture-decisions/003-sidecar-architecture-pattern.md) also frames the current model as having no separate runtime process boundary.

This package intentionally reopened that question at the blank-slate level.

That question is now resolved:

1. [D-013 in `rewrite/DECISIONS.md`](/Users/petepetrash/Code/capacitor/rewrite/DECISIONS.md) selects the dedicated local runtime service as the target foundation.
2. [ADR-004](/Users/petepetrash/Code/capacitor/docs/architecture-decisions/004-dedicated-local-runtime-service.md) records the rationale and guardrails for that choice.

## Executive Recommendation

Build the next version of this system around a dedicated local runtime service and a canonical observation journal.

Specifically:

1. The runtime service, not the Swift UI and not the hook adapters, should be the application boundary.
2. The canonical source of truth should be an append-only observation journal plus deterministic read models, not a single mutable snapshot file.
3. The system should use a capability-matrix-driven mixed transport model:
   - HTTP hooks for events Claude supports over HTTP
   - command hooks only for events Claude exposes as command-only
4. Command hooks must be forwarding adapters only. They should not contain business logic.
5. Shell signals, passive reconciliation, and Claude hook events should all enter the system as the same domain concept: observations.
6. Rust should remain the owner of normalization, state derivation, attribution policy, and explainability.
7. Swift should remain the owner of presentation, user intent capture, and macOS-only side effects.

This keeps the rewrite's core architecture decisions intact while replacing the fragile parts of the current ingress model.

## Architectural Fork: Process Model

Status note: this fork has now been resolved in favor of Option A. Option B remains useful as migration scaffolding, but it is no longer the target architecture.

There are two valid ways to implement the target architecture.

### Option A: Dedicated runtime service

This is the cleanest blank-slate design.

Advantages:

1. Tracking can continue while the visible UI restarts.
2. All ingress sources talk to the same runtime boundary.
3. The UI becomes a true client of the runtime instead of a host plus client hybrid.

Costs:

1. This supersedes `D-001` and partially supersedes ADR-003.
2. We reintroduce process lifecycle management and local IPC as a deliberate architectural choice.

### Option B: In-app runtime host with the same domain design

This is the migration-conservative variant.

Advantages:

1. Preserves the current rewrite's no-daemon direction longer.
2. Lets us adopt the observation journal, capability matrix, and thin adapters without immediately changing the process boundary.

Costs:

1. Runtime continuity remains tied to UI lifecycle.
2. We defer, rather than solve, the question of whether the runtime should outlive the visible app process.

### Decision Outcome

We are now committing to Option A as the target architecture.

For the migration slices, we can still implement the transition in an Option B-compatible way where useful:

1. Build the domain, journal, projectors, capability matrix, and adapters behind ports.
2. Keep the host in-process at first if that reduces migration risk.
3. Make the process split a composition-root change instead of a domain rewrite, then finish the cutover to the dedicated service boundary.

## Core Product Thesis

Capacitor's job is not to "receive hooks."

Capacitor's job is to present a trustworthy answer to these questions:

1. Which project is Claude actively working in?
2. What lifecycle state is that work in right now?
3. Where should the user be routed back to?
4. How confident are we in that answer?
5. If the answer is degraded, why?

From first principles, that means we should model truth around observations and derived state, not around any single upstream delivery mechanism.

## Design Principles

### Product principles

1. Trustworthy visible state beats minimal setup complexity.
2. A degraded answer must be explainable.
3. Missing or stale evidence must never masquerade as certainty.

### Architectural principles

1. Source dependencies point inward only.
2. Adapters are thin and replaceable.
3. Domain semantics live in one place only.
4. Every externally-derived state must be replayable from persisted input.
5. Runtime health is a first-class domain concern, not an afterthought.

### Migration principles

1. No parallel policy paths.
2. Transitional adapters need owning slices and deletion targets.
3. Confidence comes from replay, contract tests, shadow comparison, and smoke checks.

## Non-Goals

1. Preserving the exact shape of the current hook installer.
2. Treating the current `hud-hook` binary as an architectural requirement.
3. Maintaining compatibility with old internal command-hook contracts if they are not part of the chosen target.
4. Letting the current snapshot-file implementation dictate the next persistence model.

## The Target System

## 1. Deployables

### A. `capacitor-runtime`

A long-lived local background service. This is the real application runtime.

Responsibilities:

1. Receive observations from all ingress sources.
2. Validate observations against the current capability matrix.
3. Persist the observation journal.
4. Run deterministic projectors and maintain read models.
5. Expose typed read/query APIs to the UI.
6. Compute integration health and repair plans.

It should be able to continue operating when the visible UI is not focused, hidden, or restarted.

Recommended local boundary:

1. Unix domain socket when possible.
2. Localhost loopback plus an ephemeral auth token only if socket ergonomics materially hurt the implementation.

The exact transport is an infrastructure decision. The important architectural rule is that the runtime boundary is local, authenticated, and replaceable.

### B. `capacitor-ui`

The Swift app becomes a client of the runtime service.

Responsibilities:

1. Query typed read models.
2. Apply presentation-only hysteresis and freshness display rules.
3. Capture user actions.
4. Trigger setup, repair, and activation use cases.
5. Perform macOS-specific side effects.

### C. `capacitor-setup`

A setup and repair boundary that computes and applies a desired integration plan.

Responsibilities:

1. Read current external integration state.
2. Compare it to a desired plan.
3. Apply deltas safely.
4. Report drift in user-facing terms.

### D. Optional `capacitor-submit`

A tiny forwarding helper only if shell or command-hook reliability requires one.

Responsibilities:

1. Accept raw hook stdin or shell signal arguments.
2. Forward them to the runtime service.
3. Optionally spool if the runtime is temporarily unavailable.

It must never interpret lifecycle state.

If we choose the in-app runtime-host variant first, this helper may remain unnecessary for a while. The domain model should not depend on its existence.

## 2. Domain Model

The system should revolve around these core domain concepts.

### Observation

The canonical input record.

Fields:

1. `observation_id`
2. `source_kind`
3. `source_event_type`
4. `occurred_at`
5. `received_at`
6. `session_hints`
7. `project_hints`
8. `routing_hints`
9. `payload`
10. `raw_payload_hash`
11. `trust_level`
12. `idempotency_key`
13. `contract_version`

### Evidence

A typed piece of information derived from an observation.

Examples:

1. Claude session lifecycle signal
2. Shell cwd signal
3. tmux identity signal
4. transcript-derived project hint
5. explicit session end signal

### Session Fact

Derived, not raw.

Examples:

1. `session_id = X is currently working`
2. `session_id = X last tool activity at T`
3. `session_id = X ended with confidence high`

### Routing Fact

Derived, not raw.

Examples:

1. `project_path P currently maps to tty Y`
2. `tmux session S is the strongest activation target`
3. `routing confidence is degraded because shell signal is stale`

### Integration Health

The health of the tracking system itself.

Examples:

1. config valid / invalid
2. ingress live / unreachable
3. observation lag
4. projector lag
5. drift from desired setup plan

### Capability Matrix

The explicit contract between Capacitor and Claude.

This is a versioned policy artifact, not scattered conditionals.

It answers:

1. Which Claude events exist?
2. Which transport types are legal for each event?
3. Which fields are required?
4. Which events Capacitor depends on for product truth?
5. Which fallbacks are allowed if a signal disappears?

## 3. Clean Architecture Layers

| Layer | Owns | Must Not Know |
|------|------|---------------|
| Domain | Observation model, evidence, state semantics, attribution rules, health rules | HTTP, shell, SwiftUI, JSON hook format details |
| Application | Use cases, ports, orchestration, repair planning | Web servers, launch agents, file formats |
| Interface Adapters | Claude HTTP translation, Claude command translation, shell translation, presenters | Domain policy internals beyond ports |
| Infrastructure | SQLite, launchd/login item, sockets, file I/O, shell mutation, telemetry transport | Product semantics |
| UI | Rendering, user actions, macOS integration | External hook contract details |

## 4. Use Cases

The application layer should expose small, explicit use cases.

### Ingestion

1. `SubmitObservation`
2. `SubmitBatchObservations`
3. `AcknowledgeIngressFailure`

### State and queries

1. `QueryDashboardState`
2. `QueryProjectState`
3. `QueryRoutingState`
4. `ExplainCurrentState`
5. `QueryIntegrationHealth`

### Repair and setup

1. `ComputeIntegrationPlan`
2. `ApplyIntegrationPlan`
3. `VerifyIntegrationPlan`
4. `RepairDrift`

### Maintenance

1. `ReplayObservations`
2. `RebuildReadModels`
3. `RunPassiveReconciliation`

## 5. Ports

The core should depend on ports, not implementations.

### Required ports

1. `ObservationJournalPort`
2. `ReadModelStorePort`
3. `CapabilityMatrixPort`
4. `ClockPort`
5. `IdentityResolutionPort`
6. `ConfigMutationPort`
7. `ProcessLivenessPort`
8. `RuntimeHealthPort`
9. `TelemetryPort`

### Nice-to-have ports

1. `ObservationSpoolPort`
2. `PassiveArtifactScanPort`
3. `ActivationPlanExecutionPort`

## 6. Ingress Architecture

All ingress paths terminate in the same use case: `SubmitObservation`.

### A. Claude HTTP adapter

Responsibilities:

1. Authenticate request.
2. Parse payload.
3. Translate to `SubmitObservationRequest`.
4. Return the correct external response shape.

It must not:

1. infer lifecycle state
2. mutate read models directly
3. own reducer logic

### B. Claude command adapter

Responsibilities:

1. Read stdin from Claude.
2. Forward raw payload to runtime.
3. Return the exact exit code / JSON contract Claude expects.

It should be intentionally dumb. If possible, it should be a generic forwarder, not a product-specific reducer.

Important product boundary:

Capacitor's tracking subsystem should not rely on Claude hook decision-control as part of its core product behavior.

If we ever want hooks that actively influence Claude behavior, that should be modeled as a separate bounded capability with its own risk analysis. Otherwise command adapters will accumulate policy logic that does not belong in tracking.

### C. Shell signal adapter

Responsibilities:

1. Accept cwd, tty, pid, terminal identity, tmux info.
2. Translate to observation form.
3. Submit observation.

Shell signals are first-class observations, not a side-channel.

### D. Passive reconciliation adapter

Responsibilities:

1. Read transcripts, project artifacts, runtime leftovers, or other local files.
2. Emit lower-trust observations.
3. Repair state drift or fill gaps.

Passive reconciliation should never silently override a stronger live signal.

## 7. Persistence Model

Blank slate, the canonical store should be SQLite under `~/.capacitor/runtime/runtime.db`.

### Why SQLite

1. Atomic writes and transactions.
2. Cheap local indexing.
3. Append-only journal plus read-model tables in one place.
4. Easier replay and diff tooling.
5. Better fit for idempotency and shadow migration than a single mutable JSON file.

### Canonical tables

1. `observations`
2. `observation_spool`
3. `session_facts`
4. `routing_facts`
5. `integration_health`
6. `projection_checkpoints`
7. `shadow_comparisons`

### Derived artifacts

If useful for compatibility or debugging, we may still export a typed snapshot file, but it should be a derived artifact, not the canonical store.

## 8. Projection Model

Projectors are deterministic consumers of the observation journal.

### Projectors

1. `SessionLifecycleProjector`
2. `RoutingAttributionProjector`
3. `ProjectPresenceProjector`
4. `IntegrationHealthProjector`

### Rules

1. Projectors read observations and prior facts.
2. Projectors emit new facts plus reason codes.
3. Every derived state must carry evidence metadata.
4. Projectors must be replayable from zero.

### Important separation

1. Observed state is domain truth.
2. Display state is presentation truth.

Swift can smooth display state. Swift must not invent observed state.

## 9. Setup and Repair Architecture

Setup should become a plan/diff problem.

### Desired artifact: `IntegrationPlan`

The plan should include:

1. target runtime endpoint
2. event -> transport mapping
3. hook config entries to create
4. shell integration entries to create
5. health checks to satisfy
6. managed-entry signatures

Because Claude settings do not give us a rich namespaced metadata layer, managed-entry identity needs to be designed deliberately.

Preferred signatures:

1. A dedicated Capacitor endpoint path for HTTP hooks, not just a shared root URL.
2. A dedicated executable path or explicit stable argument marker for command hooks.
3. Exact-match validation rather than substring heuristics.

### Plan generation inputs

1. current Claude capability matrix
2. Capacitor product policy
3. user policy constraints
4. local environment capabilities

### Plan application rules

1. Mutate only Capacitor-managed entries.
2. Never infer health from partial presence.
3. Validate actual state against the same matrix used to install.
4. Report drift as structured issues, not one-off string heuristics.

## 10. Recommended Transport Strategy

We should explicitly choose "maximum product truth with minimal adapter logic."

That means:

1. Mixed transport is acceptable.
2. Mixed policy ownership is not acceptable.

### Proposed transport policy

1. Use HTTP hooks where Claude supports HTTP.
2. Use command hooks only where Claude exposes command-only events.
3. Keep command handlers as forwarders, not reducers.
4. Keep shell signals as a separate source because they solve a different problem than Claude lifecycle hooks.

This preserves product truth without reintroducing the old "many places compute state" failure mode.

## 11. The Binary Question

Blank slate, I would not define the architecture in terms of a "hook binary."

I would define it in terms of adapters and runtimes:

1. The runtime service is the application.
2. Command forwarding is an adapter.
3. HTTP receipt is an adapter.
4. Shell submission is an adapter.

If, at implementation time, the cheapest reliable command adapter is a tiny local executable, that is acceptable.

What is not acceptable is trapping product logic in that executable.

## 12. Runtime Ownership

The runtime should be independent from the visible UI lifecycle.

Recommended model:

1. `capacitor-runtime` runs as a launchd helper or login item helper.
2. `capacitor-ui` connects to it over a local authenticated boundary.
3. If the UI restarts, state continuity remains intact.

This is a better fit for a system whose main job is to observe other long-running tools.

## 13. Explainability Requirements

Every user-visible state should be explainable through a structured explanation API.

For any project/session, we should be able to answer:

1. What signals led to this state?
2. Which signal won?
3. Which stronger signal is missing or stale?
4. How fresh is the evidence?
5. What repair action would improve confidence?

This should be part of the runtime model, not an ad hoc debug overlay.

## 14. Recommended Decisions To Lock Before Migration

These should become explicit decisions before slice work starts.

### Decision A

The runtime service, not the UI and not the hook adapters, is the application boundary.

### Decision B

The canonical store is an append-only observation journal with derived read models.

### Decision C

The external Claude capability matrix is versioned and checked into the repo.

### Decision D

Mixed transport is allowed when required by Claude's contract.

### Decision E

No adapter may own lifecycle or attribution semantics.

### Decision F

All migration work is proven by shadow comparison plus replay-diff and smoke tests.

### Decision G

If we adopt a dedicated runtime service, that decision must be recorded explicitly as a superseding rewrite decision rather than slipping in as an implementation detail.

## 15. Migration Strategy

The target architecture is intentionally ambitious. We should migrate toward it in controlled slices.

### Slice 0: Decision lock

1. Lock the target decisions.
2. Check in the capability matrix.
3. Add contract tests for event -> allowed transport.

### Slice 1: Introduce observation model

1. Add observation domain types and ports.
2. Add journal schema.
3. Keep old runtime path active.

### Slice 2: Build runtime service shell

1. Create the new runtime helper/process.
2. Wire local auth, health, and query endpoints.
3. Keep it dark or shadow-only.

### Slice 3: Shadow ingest

1. Feed current ingress into both current reducer flow and the new observation journal.
2. Build comparison tooling.
3. Store diff results, do not cut over.

### Slice 4: Projector parity

1. Build lifecycle and routing projectors.
2. Replay corpora against old and new outputs.
3. Resolve all unacceptable divergences.

### Slice 5: HTTP cutover

1. Move HTTP-capable events to the new runtime service ingress.
2. Keep command-only events on thin forwarders.

### Slice 6: Command-only event cutover

1. Replace legacy command behavior with pure forwarding.
2. Remove any remaining product semantics from adapters.

### Slice 7: UI read cutover

1. Point Swift to the new runtime read/query surface.
2. Preserve only presentation-layer smoothing in Swift.

### Slice 8: Delete legacy

1. Remove obsolete snapshot-authority paths.
2. Remove obsolete migration shims.
3. Freeze denylist patterns.

## 16. Acceptance Criteria For The New System

The target system is ready only when all of the following are true:

1. Event-to-transport mapping is validated against the checked-in capability matrix.
2. Replay from the observation journal reproduces current accepted behavior or approved behavior changes.
3. UI state can be explained from structured evidence.
4. Setup health is computed from plan-vs-actual diff, not from existence heuristics.
5. Runtime continuity survives UI restart.
6. Command adapters are thin and contain no product semantics.
7. Deletion targets for superseded paths are removed in the same slice that replaces them.

## 17. What This Means For The Current System

This proposal does not say the current rewrite was wrong.

It says the next step should tighten the architecture further:

1. Keep Rust as the owner of domain semantics.
2. Keep Swift as the owner of presentation and macOS effects.
3. Move from "hook adapter writes canonical snapshot" to "runtime service ingests canonical observations and projects state."

That is consistent with the rewrite's direction. It just gives us a stronger runtime boundary and a safer migration story.

## 18. Recommended Next Step

Before implementation:

1. Review this package.
2. Review the capability matrix appendix.
3. Review the stress-test appendix.
4. Convert the locked decisions into explicit rewrite decisions.
5. Create the first migration slices from those decisions.

Related docs:

1. [Capability Matrix Appendix](/Users/petepetrash/Code/capacitor/docs/plans/2026-03-09-hook-runtime-capability-matrix.md)
2. [Stress-Test Appendix](/Users/petepetrash/Code/capacitor/docs/plans/2026-03-09-hook-runtime-stress-test.md)
3. [Current hook integration audit](/Users/petepetrash/Code/capacitor/docs/audits/2026-03-09-claude-hook-integration-audit.md)
