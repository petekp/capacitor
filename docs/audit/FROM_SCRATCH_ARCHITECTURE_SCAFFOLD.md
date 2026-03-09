# From-Scratch Architecture Scaffold

Date: 2026-03-06

This document is the shell-level module map for a from-scratch Capacitor.
It is intentionally structural rather than behavioral. The goal is to lock
down dependency direction, seams, and composition before migrating logic.

## Core Architectural Judgment

If Capacitor were rebuilt from scratch, the center of gravity would be:

- a modular monolith
- one authoritative local runtime snapshot
- explicit use cases around bounded contexts
- SwiftUI as an outer delivery mechanism, not the policy core
- narrow adapters for AppleScript, AX, tmux, hook ingress, persistence, and telemetry

The shell added in this branch stages that target alongside the existing app:

- Rust gets a non-public `contexts/` namespace so UniFFI contracts stay stable.
- Swift gets new `Composition`, `Application`, `Domain`, and `Adapters` namespaces
  inside the existing executable target so behavior does not change.

## Dependency Rules

These rules are the point of the scaffold. If later code violates them, the
architecture has drifted.

### Rust Core

1. `contexts/kernel`
   Shared identities and value objects. Imports nothing else from the project.
2. `contexts/<context>/domain`
   Domain records and invariants for one bounded context. May depend only on `contexts/kernel`.
3. `contexts/<context>/ports`
   Application-owned interfaces. May depend only on `contexts/kernel` and that context's `domain`.
4. `contexts/<context>/application`
   Use cases and service orchestration. May depend only on `contexts/kernel`, that context's `domain`, and that context's `ports`.
5. `contexts/<context>/infrastructure`
   Adapters over current storage/config/runtime helpers. May depend on current crate infrastructure plus that context's ports/domain.
6. `contexts/composition`
   The only place allowed to wire concrete adapters into use cases.

### Swift App Shell

1. `Domain`
   App-owned policy/value types. No SwiftUI, no FFI-specific details.
2. `Application/Ports`
   Protocols owned by use cases and supervisors.
3. `Application/<context>`
   State holders and use-case shells that depend only on `Domain` and `Application/Ports`.
4. `Adapters`
   Wrappers over `CoreRuntime`, `RuntimeClient`, `TerminalLauncher`, worker services, and OS-facing helpers.
5. `Composition`
   The place that assembles live adapters and application services.
6. `Views`
   Existing SwiftUI layer remains outermost and will eventually consume the composed shell.

## Bounded Context Map

### 1. Runtime

Responsibility:
- accept hook observations
- maintain authoritative projection inputs
- refresh runtime projections for the app shell
- report runtime health

Rust shell:
- `contexts/runtime/domain`
- `contexts/runtime/ports`
- `contexts/runtime/application`
- `contexts/runtime/infrastructure`

Primary use cases:
- `RefreshRuntimeProjection`
- `RecordRuntimeObservation`
- `ReadRuntimeHealth`

### 2. Setup

Responsibility:
- evaluate readiness
- install and repair hook integration
- expose explicit setup plans instead of implicit startup behavior

Rust shell:
- `contexts/setup/domain`
- `contexts/setup/ports`
- `contexts/setup/application`
- `contexts/setup/infrastructure`

Primary use cases:
- `CheckSetupReadiness`
- `BuildSetupPlan`
- `InstallHookBundle`

### 3. Activation

Responsibility:
- decide terminal routing targets
- activate a project in the chosen terminal surface
- expose routing decisions as explicit contracts

Rust shell:
- `contexts/activation/domain`
- `contexts/activation/ports`
- `contexts/activation/application`
- `contexts/activation/infrastructure`

Swift shell:
- `Application/Activation`
- `Adapters/Shell`

Primary use cases:
- `ResolveActivationDecision`
- `ActivateProjectTerminal`

### 4. Projects

Responsibility:
- manage the project catalog
- connect/suggest/sort projects
- expose project workflow state to the UI

Rust shell:
- `contexts/projects/domain`
- `contexts/projects/ports`
- `contexts/projects/application`
- `contexts/projects/infrastructure`

Swift shell:
- `Application/Projects`
- `Application/Navigation`

Primary use cases:
- `RefreshProjectCatalog`
- `ConnectProject`
- `SuggestProjects`

### 5. Ideas

Responsibility:
- capture ideas
- translate ideas into workstreams/project creation flows
- isolate idea persistence from presentation

Rust shell:
- `contexts/ideas/domain`
- `contexts/ideas/ports`
- `contexts/ideas/application`
- `contexts/ideas/infrastructure`

Swift shell:
- `Application/Ideas`

Primary use cases:
- `CaptureIdea`
- `LoadIdeaBacklog`
- `CreateProjectFromIdea`

### 6. Feedback

Responsibility:
- submit user feedback
- record telemetry through a shared contract
- keep reporting concerns out of UI/application policy

Rust shell:
- `contexts/feedback/domain`
- `contexts/feedback/ports`
- `contexts/feedback/application`
- `contexts/feedback/infrastructure`

Swift shell:
- `Application/Feedback`
- `Adapters/Feedback`

Primary use cases:
- `SubmitQuickFeedback`
- `RecordTelemetryEvent`

## Composition Roots

### Rust

`CoreRuntime` remains the UniFFI façade for now.
The staged composition root lives at:

- `core/capacitor-core/src/contexts/composition.rs`

That root wires current storage/config seams into bounded-context services
without changing the exported FFI surface.

### Swift

The staged app-shell composition root lives at:

- `apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift`

It will eventually replace direct `AppState()` construction, but not in this shell-first slice.

## Shell-First Migration Slices

The scaffold is intentionally ahead of implementation. The next migration slices should be:

1. Route `CoreRuntime` method bodies through `contexts/composition`.
2. Replace direct `AppState()` assembly with `Composition/AppShellContainer`.
3. Move `AppState` responsibilities into:
   - `RuntimeSupervisor`
   - `ProjectWorkflowState`
   - `NavigationState`
   - `SetupSupervisor`
   - `ActivateProjectTerminalUseCase`
4. Add architecture ratchet tests for:
   - file-backed production runtime construction
   - telemetry schema parity
   - no global snapshot bypasses outside the runtime boundary
