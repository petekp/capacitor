# Architecture Endgame Plan

Date: 2026-03-07
Status: completed on 2026-03-07

This document started as the remaining-slices plan for the March 7 cleanup push. It now records the closed end state so later agents do not reopen already-deleted seams.

## Mission Outcome

The Swift clean-architecture migration is complete at the app layer:

1. SwiftUI is an outer delivery layer over shell-owned state and services.
2. `AppState` is thin outer UI/composition glue, not a policy center.
3. The old Swift-side `Project` / `SuggestedProject` mirror seam is gone.
4. The remaining legacy bridges are explicit compatibility or boundary adapters, not migration leftovers.

## Intentional Bridges To Keep

These are still deliberate:

- `CapacitorConfig.legacyURL` in `apps/swift/Sources/Capacitor/Support/Config/CapacitorConfig.swift`
- legacy Claude hook config migration in `core/capacitor-core/src/runtime_setup.rs`
- legacy path/storage fallback in `core/capacitor-core/src/runtime_storage.rs`
- legacy defaults-key migration in `apps/swift/Sources/Capacitor/Utilities/ProjectOrdering.swift`
- `ProjectCatalogBridge` as the anti-corruption adapter while UniFFI/core still returns legacy `Project` / `SuggestedProject` DTOs
- `ProjectPathProviding` compatibility conformances for path-bearing project values
- local collaborator wiring inside `AppState.configureCollaborators(...)`, because those closures bind `AppState`-owned UI state to shell services while live-world construction stays in `AppShellContainer`

## Vestigial Bridges Deleted

These cleanup seams are now gone:

- `ProjectWorkflowState.legacyProjects`
- `ProjectWorkflowState.legacySuggestedProjects`
- `ProjectWorkflowState.selectedLegacySuggestedProjects`
- project-only helper signatures in the runtime/session/status/list/detail activation path that only needed shell DTOs or paths
- legacy `Project` reconstruction in terminal activation
- `AppState` convenience initializers
- `AppStateDependencies.live(...)`
- dead `AppState` profile/tracking flags
- duplicate `layoutMode` persistence inside `AppState`

## Final Slice Closeout

### RW-103: Shell Project Consumer Cutover

Completed.

Outcome:

- non-view runtime/model/application helpers now consume shell catalog entries, shell references, or raw paths
- active-project resolution, session lookup, status caching, list ordering, and detail-side helpers no longer depend on `ProjectWorkflowState` legacy mirrors

### RW-104: Project Workflow + SwiftUI Cutover

Completed.

Outcome:

- SwiftUI project list/detail/card/drop/navigation surfaces now read shell-native DTOs
- `legacyProjects`, `legacySuggestedProjects`, and `selectedLegacySuggestedProjects` are absent from Swift source
- `ProjectCatalogBridge` remains boundary-scoped instead of leaking into views or coordinators

### RW-105: AppState Endgame Shrink

Completed.

Outcome:

- `AppState` no longer exposes migration-era convenience/live construction
- live-world assembly is confined to `AppShellContainer`
- test-only explicit construction is confined to `AppStateTestSupport`
- duplicate `layoutMode` persistence was removed from `AppState`; `App.swift` is the single persistence owner
- `AppState` still performs local collaborator wiring through `configureCollaborators(...)`, but that wiring is now explicit outer-layer glue rather than hidden live-world construction

## Ratchets In Force

The repo now freezes the end state with source-level guards:

- zero-budget guards on `legacyProjects`, `legacySuggestedProjects`, and `selectedLegacySuggestedProjects`
- live gateway construction allowlisted to `AppShellContainer.swift` for the `AppState` live world
- `AppState(` construction in production sources confined to `AppShellContainer.swift`
- `AppState(` construction in tests confined to `AppStateTestSupport.swift`
- `AppState` convenience initializer budget fixed at `0`
- `AppStateDependencies.swift` may not construct the live world
- terminal activation may not reconstruct legacy `Project` values
- `AppState` may not reintroduce local `layoutMode` persistence

## What Would Count As A New Slice

The main remaining Swift-side boundary is intentional:

- `ProjectCatalogBridge` can only disappear after an upstream UniFFI/core DTO slice makes the boundary shell-native

That is not unfinished RW-105 work. It is a separate boundary change.
