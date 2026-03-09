# Namespace Purity Audit

Date: 2026-03-08
Status: closed through `NP-303`

This audit starts the post-convergence namespace-purity tranche.

## Mission

Reduce naming/location debt by moving canonical implementation files out of `apps/swift/Sources/Capacitor/Models/` into namespaces that match their actual role, while preserving the already-converged architecture and keeping all behavior stable.

## Why This Is A New Tranche

The convergence tranche (`RW-200` through `RW-206`) already removed the real mixed-ownership seams. What remains is not a second architecture. It is that several files still live under `Models/` even though they are:

- setup policy/presentation helpers
- runtime value types
- support/windowing helpers
- shell AX helpers

That hurts readability and onboarding, but it is a different problem than the one the convergence tranche solved.

## Measured Namespace Debt

Measured on March 8, 2026 after `RW-206`.

| Pattern | Current count | Why it matters | Ratchet |
| --- | ---: | --- | --- |
| top-level Swift files in `apps/swift/Sources/Capacitor/Models` | 17 | namespace debt reservoir after seam deletion | freeze at `<= 17`; drive down slice by slice |
| low-risk leaf files still under `Models` | 8 | easiest wins with near-zero behavioral risk | delete/rehome all 8 in first slice |

Low-risk leaf candidates:

- `HookDiagnosticPresentation.swift`
- `HookPresentationPolicy.swift`
- `SetupStepCatalog.swift`
- `SetupReadinessCoordinator.swift`
- `RuntimeStatus.swift`
- `WindowFrameStore.swift`
- `GhosttyAXReader.swift`
- `ShellSetupInstructions.swift`

Higher-risk later tranche targets:

- `ProjectDetailsManager.swift`
- `ProjectCreationCoordinator.swift`
- `HookServerManager.swift`
- `SessionStateManager.swift`
- `ShellStateStore.swift`
- `RuntimeClient.swift`
- `TerminalLauncher.swift`
- `WorkstreamsManager.swift`
- `AppState.swift`

## Hard Conclusions

1. The next best step is a low-risk leaf rehome slice, not another runtime refactor.
2. `Models/*.swift` should now be treated as a shrinking quarantine namespace.
3. We should not start by moving `RuntimeClient` or `TerminalLauncher`; those are blast-radius-heavy and can wait for a dedicated slice.

## Proposed Slices

### NP-300: Namespace Purity Audit + Budget Freeze

Outcome:

- record the namespace-purity mission and low/high-risk inventory
- freeze the current `Models/*.swift` file count
- define the first low-risk rehome slice

### NP-301: Leaf Model Rehome

Outcome:

- move the 8 low-risk leaf files out of `Models/`
- lower the `Models/*.swift` budget from `17` to `9`
- prove no behavior change with the full Swift suite and architecture guard

Status: completed.

Closed state after NP-301:

- `Models/*.swift` count is now `9`
- the 8 low-risk leaf files are rehomed under `Application/Setup`, `Application/Runtime`, and `Support`
- the next namespace-purity slice is medium-risk rehomes

### NP-302: Medium-Risk Model Rehome

Outcome:

- move `ProjectDetailsManager`, `ProjectCreationCoordinator`, and `HookServerManager`

Status: completed.

Closed state after NP-302:

- `Models/*.swift` count is now `6`
- project details, project creation, and hook server process control now live under `Application/Projects` or `Support`
- the next namespace-purity slice is the high-blast-radius runtime implementation rehome

### NP-303: Runtime Implementation Rehome

Outcome:

- move the remaining canonical runtime implementation files out of `Models/`

Status: completed.

Closed state after NP-303:

- top-level `Models/*.swift` count is now `0`
- `RuntimeClient` and `TerminalLauncher` now live under `Support`
- `SessionStateManager` and `ShellStateStore` now live under `Application/Runtime`
- `WorkstreamsManager` now lives under `Application/Projects`
- `AppState` now lives under `Composition`
- the old top-level `Models/*.swift` paths are denylisted at `0`
- the only remaining Swift files under `Models/` are the nested `WindowAnchoring/*` implementation files, which are now a separate subnamespace decision rather than leftover top-level migration debt
