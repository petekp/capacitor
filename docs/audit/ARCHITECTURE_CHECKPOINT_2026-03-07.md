# Architecture Checkpoint

Date: 2026-03-07

## Executive Verdict

Verdict: `GO`

The Swift clean-shell migration is effectively complete.

The important distinction versus the March 6, 2026 checkpoint is that the remaining `AppState` surface is no longer where application policy lives. The shell now owns the behaviors that mattered:

- project catalog, list policy, mutation, import, feature navigation
- setup startup, diagnostics, repair, and onboarding orchestration
- runtime observation transport, health transport, session refresh, bootstrap, and automation cadence
- terminal activation, active-project tracking, quick feedback orchestration, project creation state, import ingress, dashboard/loading state, and status caching

`AppState` still exists, but it now behaves like an outer UI shell object:

- feature flags and simple UI presentation state
- modal/drag/toast/error state
- shell collaborator references composed into the UI layer
- a small amount of debug/test-only forwarding
- layout persistence and a few harmless outer-edge helpers

That is qualitatively different from the previous god-object shape.

## Automated Verification Status

| Check | Result | Evidence |
|---|---|---|
| `swift test` | PASS | `366 tests, 0 failures` |
| `swift build` | PASS | completed successfully |
| `cargo check -p capacitor-core` | PASS | completed successfully |
| `cargo test -p capacitor-core clean::tests::` | PASS | `6 passed, 0 failed` |
| `cargo test -p capacitor-core ffi_` | PASS | `6 passed, 0 failed` |

## Architecture Enforcement Snapshot

Current enforcement signal:

- `ArchitectureBoundaryTests.swift` is now 284 lines of shell ratchets
- `AppState.swift` is down to 591 lines
- direct runtime snapshot transport bypasses in Swift: `0`
- direct `appState.*` project/setup/runtime action façade usage in Swift views: `0`
- helper-level direct setup reads in `HookInstaller.swift`: `0`

The remaining `HookInstaller.ensureHooksInstalled(...)` call is the allowed adapter call in `LiveSetupGateway.swift`.

## AppState Assessment

What `AppState` still owns, and why that is acceptable:

- layout mode persistence
- error / toast / drag-hover / capture-modal UI state
- debug activation trace
- top-level references to shell-owned state/coordinator objects for SwiftUI environment access
- debug-only forwarding into runtime refresh and project-creation test hooks

What `AppState` no longer owns:

- runtime bootstrap composition
- runtime automation cadence policy
- runtime health refresh policy
- runtime session refresh coordination
- active-project resolution policy
- project status cache
- dashboard loading state
- quick feedback workflow
- project creation state
- project import ingress
- terminal activation policy
- duplicate navigation state
- live gateway/supervisor construction details

## Residual Cleanup

These are now cleanup items, not blockers:

1. Decide whether any remaining debug/test-only forwarding on `AppState` should move to narrower test harnesses.
2. Decide whether additional collaborator construction currently done inside `AppState.commonInit(...)` should be hoisted fully into composition for readability.
3. Replace the user-run smoke checklist with app automation if desired.

None of those residuals change the architectural verdict.

## Manual Smoke Checklist

User-run unless replaced with app automation.

| Scenario | Expected Outcome | Result |
|---|---|---|
| Cold launch with setup complete | app opens directly into the main shell; project list renders; no welcome loop | `TODO (user-run)` |
| Cold launch with setup incomplete or forced welcome path | welcome/setup flow appears; setup workflow renders correctly; preview/debug setup states still function in debug | `TODO (user-run)` |
| Connect project via file browser | selected project is added; project list updates; no regression in list visibility/navigation | `TODO (user-run)` |
| Drag-drop project import | dropped folders import; drag-drop tip/toast behavior still works | `TODO (user-run)` |
| List -> detail -> new idea -> list navigation | transitions and back/escape flows still work | `TODO (user-run)` |
| Hook diagnostic card test/fix flow | test action returns a result; fix action repairs when possible and refreshes the card | `TODO (user-run)` |
| Runtime refresh after launch | active project/session state appears after bootstrap; no stale-state regression on subsequent refreshes | `TODO (user-run)` |

## Conclusion

The migration objective for Swift app orchestration is met:

- SwiftUI is now an outer delivery layer over shell-owned state and services
- Rust/Swift shell services own policy
- `AppState` is no longer the policy center of the application

Further work from here is refinement, not rescue.
