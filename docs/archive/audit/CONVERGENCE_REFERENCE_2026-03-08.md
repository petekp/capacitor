# Convergence Reference

Date: 2026-03-08

This reference supports the convergence campaign by capturing the translation targets, edge cases, and small code-shape examples that later slices should follow.

## Translation Guide

| Current pattern | Target pattern |
| --- | --- |
| `Application/*` object wrapping a `Models/*Manager` or `Models/*Coordinator` | move the behavior into application-owned state/use-case objects and delete the wrapped manager/coordinator |
| `Application/*` object wrapping `ActiveProjectResolver`, `ProjectIngestionWorker`, `SessionStateManager`, or `ShellStateStore` | inline the policy into canonical application/domain services or move the dependency to an adapter/support boundary |
| `Adapters/*` reaching into transport/executor code that still lives under a legacy namespace | rehome the transport/executor type into `Adapters` or `Support`, then let the adapter own it natively |
| `Views/*` calling `appState.projectFeatureCoordinator` | expose canonical application-owned navigation / idea / mutation state directly from the shell container and delete the façade |
| `SetupWorkflowState` forwarding to `SetupRequirementsManager` | give `SetupWorkflowState` its own state/use-case collaborators and delete the manager |
| tracked checkpoint or review artifacts under `tmp/` | delete them in the same slice that makes them obsolete and add a denylist so they cannot come back |

## Edge Cases and Gotchas

- `AppState` currently closes over a lot of UI state. Do not replace that with a service locator. Move live-world construction into `AppShellContainer` and inject narrow callbacks or state objects.
- `TerminalLauncher` mixes decision logic with side-effect execution. Rehoming it is not a rename-only slice; keep an eye on planner vs executor boundaries.
- `RuntimeClient` is safe to rehome only if generated bridge and debug surfaces still compile. Delete dead direct callers in the same slice rather than creating another shim.
- Some debug views are transitional but still wired into the debug window or project list. Treat them as product decisions: keep intentionally, or delete explicitly. Do not leave them in a "temporary" state indefinitely.
- Historical docs can remain, but they must stop pretending to be the latest truth. Always add a superseding note or update the summary index.

## Code Pattern Examples

### 1. Replace wrapper-state with application-owned behavior

Before:

```swift
@Observable
final class SetupWorkflowState {
    private(set) var manager: SetupRequirementsManager

    func runChecks() async {
        await manager.runChecks()
    }
}
```

Target shape:

```swift
@Observable
final class SetupWorkflowState {
    private let runChecksUseCase: RunSetupChecksUseCase
    private(set) var steps: [SetupStep] = []

    func runChecks() async {
        steps = await runChecksUseCase.execute()
    }
}
```

### 2. Let adapters own their transport dependency

Before:

```swift
struct LiveRuntimeGateway: RuntimeGateway {
    private let runtimeClient: RuntimeClient = .shared
}
```

Target shape:

```swift
struct LiveRuntimeGateway: RuntimeGateway {
    private let snapshotSource: RuntimeSnapshotSource

    init(snapshotSource: RuntimeSnapshotSource = LiveRuntimeSnapshotSource()) {
        self.snapshotSource = snapshotSource
    }
}
```

### 3. Keep the composition root as the only live-world constructor

Before:

```swift
let appState = AppState(...)
appState.configureCollaborators(...)
```

Target shape:

```swift
let navigationState = NavigationState()
let projectFlows = ProjectFlows(...)
let setupFlow = SetupWorkflowState(...)
let appState = AppState(navigationState: navigationState, projectFlows: projectFlows, setupFlow: setupFlow)
```

The point is not shorter code. The point is that ownership becomes obvious and replaceable.
