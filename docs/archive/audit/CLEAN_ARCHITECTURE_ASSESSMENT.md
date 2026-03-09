# Clean Architecture Assessment

Date: 2026-03-06

This assessment applies Clean Architecture from first principles:

- Dependencies should point inward toward policy.
- Business rules should be isolated from frameworks and delivery mechanisms.
- Use cases should be explicit, narrow, and testable.
- Boundaries should be real, not ceremonial.
- External systems should be hidden behind adapters.

## Executive Judgment

Capacitor is directionally aligned with Clean Architecture, but only in its core runtime path.

The strongest part of the codebase is the Rust-side runtime pipeline:

- hook ingest is a thin adapter
- reducer logic is centralized
- snapshot persistence forms a clear system boundary
- the Swift app mostly consumes runtime state rather than re-deriving it from raw hooks

The weakest part is everything around that core:

- the FFI surface is too broad
- Swift application state is overly centralized
- several boundaries are conceptually present but not enforced in code
- some integration seams have drifted into contradictory contracts

If scored from first principles, this codebase is:

- Strong on: adapter seams, local-first architecture, reducer test coverage
- Mixed on: dependency direction, boundary enforcement, framework isolation
- Weak on: use-case isolation, component cohesion in Swift, domain-centric structure

Overall score: 5.5/10

## Category Assessment

| Category | Score | Judgment |
|---|---:|---|
| Dependency Direction | 5/10 | Good intent, inconsistent enforcement |
| Entity Design | 6/10 | Rust domain is reasonably pure, but mostly anemic |
| Use Case Isolation | 4/10 | Major orchestration objects combine many workflows |
| Component Cohesion | 4/10 | Swift components change for too many reasons at once |
| Boundary Definition | 6/10 | Snapshot seam is real, but several boundaries leak |
| Interface Adapters | 6/10 | Some strong adapters, some overgrown ones |
| Framework Isolation | 5/10 | Rust is fairly isolated; Swift policy and UI are intertwined |
| Testing Architecture | 8/10 | Runtime path is well tested, boundary invariants less so |

## First-Principles Read

### 1. Dependency Direction

Clean Architecture asks whether dependencies point toward policy or toward mechanisms.

What is good:

- `capacitor-hook` is a thin ingress adapter into `capacitor-core`, not a second policy engine. See [core/capacitor-hook/src/main.rs](/Users/petepetrash/Code/capacitor/core/capacitor-hook/src/main.rs) and [core/capacitor-hook/src/handle.rs](/Users/petepetrash/Code/capacitor/core/capacitor-hook/src/handle.rs).
- Core runtime types are plain records and enums, which is the right shape for boundary crossing. See [core/capacitor-core/src/domain/types.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/domain/types.rs).
- `RuntimeClient` is an adapter over snapshot/file access, not raw UI code reaching into persistence. See [apps/swift/Sources/Capacitor/Support/RuntimeClient.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Support/RuntimeClient.swift).

What is wrong:

- `CoreRuntime` violates inward dependency discipline at the object level by mixing runtime policy, setup/config mutation, project catalog logic, plugin discovery, and idea services in one façade. See [core/capacitor-core/src/lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs).
- The default `CoreRuntime()` constructor is in-memory while `capacitor-hook` uses file-backed storage, which means the same abstraction points at different realities depending on who calls it. See [core/capacitor-core/src/lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs#L276) and [core/capacitor-hook/src/runtime_client.rs](/Users/petepetrash/Code/capacitor/core/capacitor-hook/src/runtime_client.rs#L101).
- `check_hook_health()` reads global snapshot state rather than the runtime instance’s storage abstraction, so the abstraction boundary is nominal rather than real. See [core/capacitor-core/src/lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs#L782).

Assessment:

- The system-level dependency rule is partially satisfied.
- The module graph is cleaner than the object graph.

### 2. Entity Design

Clean Architecture wants enterprise rules in stable entities, not spread across delivery layers.

What is good:

- Rust domain objects are framework-light and serializable.
- Identity and workspace logic are centralized in domain/path logic rather than smeared across UI code. See [core/capacitor-core/src/domain/identity.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/domain/identity.rs).

What is weak:

- Most core types are data carriers, not rich entities with explicit invariants.
- Important rules live in procedural reducers and managers rather than in cohesive domain objects. The real behavioral center is [core/capacitor-core/src/reduce/mod.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs), not the domain layer.

Assessment:

- Better than a framework-driven CRUD model.
- Not yet a rich domain model. It is a disciplined state machine plus DTOs.

### 3. Use Case Isolation

A clean system has one workflow per use case, with narrow orchestration units.

What is wrong:

- `AppState` owns runtime bootstrap, polling, feature gating, project ingestion, navigation, activation, feedback, and orchestration. See [apps/swift/Sources/Capacitor/Composition/AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Composition/AppState.swift).
- `ProjectDetailsManager` mixes idea loading, file change watching, title generation, description generation, persistence ordering, and git context gathering. See [apps/swift/Sources/Capacitor/Application/Projects/ProjectDetailsManager.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Application/Projects/ProjectDetailsManager.swift).
- `TerminalLauncher` mixes routing policy, terminal detection, AppleScript execution, tmux behavior, AX fallback logic, and telemetry emission. See [apps/swift/Sources/Capacitor/Support/TerminalLauncher.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Support/TerminalLauncher.swift).

Assessment:

- This is the codebase’s biggest bounded-context weakness.
- The system has workflows, but not first-class use-case objects.

### 4. Component Cohesion

Components should group code that changes together for one reason.

What is wrong:

- `AppState` is a classic multi-reason-to-change component.
- `CoreRuntime` is also multi-purpose: runtime, setup, diagnostics, catalog, idea API.
- `NavigationContainer` duplicates navigation state already present in `projectView`, which means navigation behavior is split across more than one component. See [apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift).

What is good:

- The Rust side at least separates ingest, reduce, query, identity, and setup into modules.

Assessment:

- Cohesion is acceptable in Rust modules.
- Cohesion is poor in the Swift orchestration layer.

### 5. Boundary Definition

Boundaries matter only if crossing them changes what code is allowed to know.

What is good:

- The runtime snapshot is a meaningful architectural boundary.
- `capacitor-hook` is a real adapter boundary, not just a folder name.
- Optional ingest worker is outside the core runtime truth path.

What is wrong:

- The `CoreRuntime` constructor split means the snapshot boundary is not consistently authoritative.
- Hook health reads outside the runtime instance.
- The telemetry contract between Swift and the ingest worker is inconsistent, which means that integration boundary is under-specified. See [apps/swift/Sources/Capacitor/Utilities/TelemetryRoutingPolicy.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Utilities/TelemetryRoutingPolicy.swift) and [services/ingest-worker/src/index.js](/Users/petepetrash/Code/capacitor/services/ingest-worker/src/index.js).

Assessment:

- The codebase has one genuinely strong boundary: persisted runtime snapshot.
- Several other boundaries are aspirational rather than enforced.

### 6. Interface Adapters

Adapters should hide infrastructure and translate boundary data.

What is good:

- `RuntimeClient` is a solid interface adapter.
- `capacitor-hook` is a solid ingress adapter.
- The worker normalizes inbound telemetry/feedback before persistence. See [services/ingest-worker/src/lib.js](/Users/petepetrash/Code/capacitor/services/ingest-worker/src/lib.js).

What is weak:

- `TerminalLauncher` knows too much about every external system it touches.
- `ProjectFeatureCoordinator` is more of a closure-forwarding façade than a real use-case boundary. See [apps/swift/Sources/Capacitor/Features/ProjectFeatureCoordinator.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Features/ProjectFeatureCoordinator.swift).

Assessment:

- Adapters exist, but some are under-factored and policy-heavy.

### 7. Framework Isolation

Frameworks should sit at the edge, not define the policy core.

What is good:

- The Rust runtime core is largely framework-agnostic apart from serialization and FFI.
- The system is not architected around Next.js or SwiftUI abstractions.

What is weak:

- SwiftUI and application-policy state are intertwined in the Swift layer. `AppState` imports `SwiftUI` and directly owns application workflow logic. See [apps/swift/Sources/Capacitor/Composition/AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Composition/AppState.swift).
- The Swift package structure is mostly `Models`, `Views`, `Utilities`, `Support`, which screams implementation shape more than domain. See the directory layout under [apps/swift/Sources/Capacitor](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor).

Assessment:

- Framework isolation is decent in Rust and weak in Swift.

### 8. Testing Architecture

Tests are part of the architecture because they reveal what the system considers stable.

What is good:

- The runtime reducer and ingest path are heavily tested.
- Integration coverage exists for the hook server and worker behavior.
- Replay-diff testing is exactly the kind of architectural lock a reducer-based system should have.

What is missing:

- There are not enough explicit tests for architectural boundary invariants such as:
  - all production `CoreRuntime` construction must be file-backed
  - telemetry allowlists must match across app and worker
  - manual active-project override must yield to newer runtime activity

Assessment:

- Test coverage for behavior is strong.
- Test coverage for architecture contracts is incomplete.

## Clean Architecture Verdict By Layer

### Best-aligned layer

`capacitor-hook` -> `capacitor-core` reducer -> snapshot persistence

Why:

- single responsibility
- minimal adapter logic
- simple data crossing the boundary
- strong tests

### Most problematic layer

Swift application orchestration

Why:

- `AppState` is too large
- use cases are implicit
- UI state and infrastructure supervision are mixed
- view refresh and navigation rely on side channels

### Most misleading abstraction

`CoreRuntime`

Why:

- its name suggests a narrow runtime engine
- its implementation is actually a god façade for runtime, setup, catalog, and idea services

## Refactor Direction From Clean Architecture Principles

If you want this repo to become clean by construction rather than clean by convention, the next structural moves should be:

1. Split `CoreRuntime` into narrower FFI façades.
   Suggested seams:
   - `RuntimeEngine`
   - `SetupService`
   - `ProjectCatalogService`
   - `IdeaService`

2. Make the persisted snapshot the only production runtime truth.
   - no in-memory production constructor
   - no global snapshot bypasses for diagnostics

3. Break `AppState` into explicit application services.
   Suggested seams:
   - `RuntimeSupervisor`
   - `ProjectWorkflowState`
   - `NavigationState`
   - `ActivationUseCase`

4. Turn major workflows into explicit use cases.
   Examples:
   - Resolve active project
   - Refresh runtime projection
   - Activate project terminal
   - Capture idea
   - Create project from idea
   - Add/connect project

5. Add architecture ratchet tests.
   Examples:
   - production runtime constructor must be file-backed
   - telemetry event allowlist parity
   - no-op FFI APIs forbidden unless explicitly marked deprecated

## Bottom Line

From a Clean Architecture perspective, Capacitor is not a mess. It has a real core and a defensible primary boundary.

But it is not yet clean in the strict sense, because the code that should be application policy is still concentrated in broad façade objects, especially `CoreRuntime` and `AppState`. The codebase’s next leap in quality is not another round of local cleanup. It is turning those implicit workflows and soft boundaries into explicit architectural units.
