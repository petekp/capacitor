# Architecture Checkpoint

Date: 2026-03-06

## Executive Verdict

Verdict: `GO WITH WARNINGS`

The clean-shell migration is materially succeeding. The shell is no longer hypothetical:

- `projects` is largely shell-owned end to end
- `setup` is largely shell-owned end to end
- runtime transport and runtime automation lifecycle are now shell-owned

The codebase does not show evidence of drift back to the pre-shell shape in already-migrated areas. The strongest proof is not narrative but enforcement:

- architecture ratchets block direct project/setup/runtime bypasses
- shell-owned state and coordinator tests cover real production paths
- Swift and Rust verification are green at the checkpoint baseline

Warnings remain:

- `AppState` still owns runtime snapshot application and failure hysteresis
- `AppState` still couples dashboard reloads to runtime/session refresh behavior
- `AppState` still owns a handful of outer-shell entrypoints that should eventually move outward or inward
- setup infrastructure still contains one allowed helper-level direct hook-status read in `HookInstaller`

This is enough confidence to continue, but not enough to relax the ratchets or skip the next architecture-focused slices.

## Automated Verification Status

| Check | Result | Evidence |
|---|---|---|
| `swift test` | PASS | `337 tests, 0 failures` |
| `swift build` | PASS | completed successfully |
| `cargo check -p capacitor-core` | PASS | completed successfully |
| `cargo test -p capacitor-core clean::tests::` | PASS | `6 passed, 0 failed` |
| `cargo test -p capacitor-core ffi_` | PASS | `6 passed, 0 failed` |

Checkpoint interpretation:

- Swift shell behavior and ratchets are green
- Rust clean-shell delegation and FFI contract coverage are green
- No verification signal in this checkpoint suggests architectural regressions in migrated areas

## Shell Ownership Matrix

| Behavior | Current Shell Owner | Port / Adapter Path | Evidence | Remaining Debt |
|---|---|---|---|---|
| Project catalog reads | `ProjectWorkflowState` | `ProjectCatalogGateway` -> `LiveProjectCatalogGateway` | `ProjectWorkflowStateTests`, `ArchitectureBoundaryTests` | `AppState` still exposes `projects` / `suggestedProjects` as legacy façades |
| Project list policy | `ProjectListState` | `ProjectListPreferencesGateway` -> `LiveProjectListPreferencesGateway` | `ProjectListStateTests`, `AppStateSessionObservationTests` | Views still consume some list state through `AppState` environment |
| Project mutation / import flows | `ProjectActionState` + `ProjectMutationService` | `ProjectMutationGateway` -> `LiveProjectMutationGateway` | `ProjectActionStateTests`, `ProjectMutationServiceTests`, `ArchitectureBoundaryTests` | File-browser and drop extraction still originate in `AppState` |
| Project feature actions / navigation | `ProjectFeatureCoordinator` | app-owned coordinator seam | `ProjectFeatureCoordinatorTests`, `ArchitectureBoundaryTests` | `projectView` still lives on `AppState` as outer UI state |
| Setup startup readiness | `SetupStartupCoordinator` | `SetupGateway` -> `LiveSetupGateway` | `SetupStartupCoordinatorTests`, `ArchitectureBoundaryTests` | Shell integration install remains in `App.swift` after startup decision |
| Setup diagnostics / test / repair actions | `SetupActionState` + `SetupSupervisor` | `SetupGateway` -> `LiveSetupGateway` | `SetupActionStateTests`, `SetupSupervisorTests`, `ArchitectureBoundaryTests` | Hook server lifecycle still coordinated from `AppState` timer tick |
| Setup onboarding workflow ownership | `SetupWorkflowState` | composed `SetupRequirementsManager` | `SetupWorkflowStateTests`, `ArchitectureBoundaryTests` | `SetupRequirementsManager` still exists as a manager rather than a narrower use-case object set |
| Runtime observation transport | `RuntimeSupervisor` | `RuntimeGateway` -> `LiveRuntimeGateway` | `RuntimeSupervisorTests`, `ArchitectureBoundaryTests` | Snapshot apply/hysteresis still lives in `AppState` |
| Runtime health transport | `RuntimeSupervisor` | `RuntimeGateway` -> `LiveRuntimeGateway` | `RuntimeSupervisorTests`, `ArchitectureBoundaryTests` | Health presentation/polling cadence still coupled to outer app state |
| Runtime automation lifecycle | `RuntimeAutomationController` | shell-owned controller | `RuntimeAutomationControllerTests`, `ArchitectureBoundaryTests` | Controller is still composed inside `AppState` instead of the composition root |

## Bypass Sweep Results

### Zero-unexpected sweeps

| Query | Result | Judgment |
|---|---:|---|
| `RuntimeClient.shared.fetchRuntimeSnapshot(` in Swift sources | `0` | no direct runtime snapshot transport bypasses remain |
| `RuntimeClient.shared.fetchHealth(` in Swift sources | `0` | no direct runtime health transport bypasses remain |
| `appState.(removeProject|connectSelectedSuggestions|createClaudeMd|addProjectsFromDrop|showProjectList|showProjectDetail|showIdeaCaptureModal|captureIdea|getIdeas|generateDescription|createProjectFromIdea|fixHooks|testHooks|checkHookDiagnostic)` in Swift sources | `0` | project/setup façade drift through `AppState` is currently blocked |
| `CoreRuntime()` in startup/setup paths outside approved adapters | `0` unexpected | `App.swift`, `WelcomeView`, and setup-shell paths no longer construct runtime directly |

### Allowed exceptions and residuals

| Query | Result | Judgment |
|---|---:|---|
| `HookInstaller.ensureHooksInstalled(` in Swift sources | `1` | allowed adapter call in `Adapters/CoreBridge/LiveSetupGateway.swift` |
| `engine.checkSetupStatus|getHookStatus|getHookDiagnostic|runHookTest` in Swift sources | `1` | allowed helper-level setup infrastructure exception in `Helpers/HookInstaller.swift:37` |
| `CoreRuntime()` across all Swift sources | `8` | mostly expected adapter/default-constructor sites; one notable remaining debt in `AppState` runtime bootstrap |

### Global `CoreRuntime()` classification

- Allowed / expected adapter sites:
  - `Adapters/CoreBridge/LiveIdeaGateway.swift`
  - `Adapters/CoreBridge/LiveProjectCatalogGateway.swift`
  - `Adapters/CoreBridge/LiveProjectMutationGateway.swift`
  - `Adapters/CoreBridge/LiveSetupGateway.swift`
- Allowed support / generated sites:
  - `Bridge/capacitor_core.swift`
  - `Models/SetupRequirements.swift` default runtime factory
- Allowed debug-only site:
  - `Debug/AppDebugSupport.swift`
- Remaining architecture debt:
  - `Models/AppState.swift` runtime bootstrap closure still constructs `CoreRuntime()` directly

Checkpoint interpretation:

- No unexpected bypasses were found in already-migrated project/setup/runtime transport paths.
- The one direct setup helper read in `HookInstaller` is infrastructure-local, but it is still a detail worth eliminating later.
- The main remaining architectural concentration is not bypass drift, but residual ownership in `AppState`.

## Residual AppState Inventory

### Outer UI state that is fine to keep

- layout mode and UI appearance state
- feature-flag exposure for the view layer
- toast / error / loading state
- capture modal presentation state
- drag-hover UI state
- activation trace and runtime status presentation state
- cached project status map for rendering
- session-state observation revision counter

### Remaining orchestration that should migrate

- runtime snapshot application and stale/failure hysteresis
- dashboard reload coupling with session refresh and idea hydration
- file-browser project connect entrypoint
- drag/drop URL extraction entrypoint
- quick feedback submission flow
- terminal launch / activation coordination
- shell tracking kickoff after runtime bootstrap
- creation/activity/workstreams coordination that still hangs off outer app state

### Suspicious leftovers or dead-weight candidates

- dual navigation state shape: `projectView` plus `NavigationState`
- direct runtime bootstrap construction in `AppState`
- testing-only runtime automation flags still exposed from `AppState`
- `AppState` continues to aggregate too many shell-owned collaborators even after ownership moved inward

### Specific hotspots to track next

1. Runtime snapshot application / hysteresis
- still owned by `AppState.refreshSessionStates()` and related helpers
- strongest remaining “policy in the outer shell” area

2. Dashboard reload coupling
- `loadDashboard()` still triggers project catalog replacement, runtime refresh, and idea hydration together
- likely candidate for a narrower runtime/projects coordination seam

3. File-browser / drop entrypoints
- behavior is shell-owned after extraction, but acquisition of file URLs is still on `AppState`
- probably acceptable outer-shell work, but still centralizes too much UI integration in one object

4. Quick feedback flow
- currently an `AppState` async orchestration path rather than a dedicated shell workflow object in practice

5. Terminal launch / activation coordination
- `AppState` still coordinates active-project overrides and terminal launch side effects
- activation decision and terminal execution are not yet as cleanly separated as project/setup paths

6. Creation / activity / workstreams coupling
- project creation monitoring, activity panel state, and workstreams are still clustered around `AppState`

## Manual Smoke Checklist

User-run unless later replaced with macOS app automation.

| Scenario | Expected Outcome | Result |
|---|---|---|
| Cold launch with setup complete | app opens directly into the main shell; project list renders; no welcome loop | `TODO (user-run)` |
| Cold launch with setup incomplete or forced welcome path | welcome/setup flow appears; setup workflow renders correctly; preview/debug setup states still function in debug | `TODO (user-run)` |
| Connect project via file browser | selected project is added; project list updates; no regression in list visibility/navigation | `TODO (user-run)` |
| Drag-drop project import | dropped folders import; drag-drop tip/toast behavior still works | `TODO (user-run)` |
| List -> detail -> new idea -> list navigation | transitions and back/escape flows still work | `TODO (user-run)` |
| Hook diagnostic card test/fix flow | test action returns a result; fix action repairs when possible and refreshes the card | `TODO (user-run)` |
| Runtime refresh after launch | active project/session state appears after bootstrap; no stale-state regression on subsequent refreshes | `TODO (user-run)` |

## External Review Package Location

Local package path:

- `/Users/petepetrash/Code/capacitor/tmp/review-package/architecture-checkpoint-2026-03-06/`

Expected contents:

- `README.md`
- `REVIEW_PROMPT.md`
- copied key shell files and ratchet tests under `files/`

Purpose:

- hand current architecture state to an external reviewer without requiring them to rediscover the migration context from scratch

## Go / No-Go And Next Slices

Decision: `GO WITH WARNINGS`

Why not `STOP`:

- automated verification is fully green
- already-migrated shell paths do not show meaningful bypass drift
- ratchets are enforcing the most important boundaries we intended to establish

Why not an unconditional `GO`:

- `AppState` still owns significant runtime policy
- one setup infrastructure helper still reads hook status directly
- runtime bootstrap ownership is cleaner, but not yet fully composed at the app shell root

Recommended next slices:

1. Runtime session-refresh policy extraction
- move snapshot apply/hysteresis and shell-state application out of `AppState`

2. Dashboard/runtime coupling reduction
- separate dashboard loading from runtime/session refresh concerns

3. Outer-shell entrypoint reduction
- decide what should remain on `AppState` as harmless UI-edge work versus what should move into smaller application objects

4. Setup infrastructure cleanup
- eliminate the remaining helper-level direct hook-status read in `HookInstaller`
