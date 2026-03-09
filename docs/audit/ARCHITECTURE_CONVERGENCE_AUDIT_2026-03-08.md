# Architecture Convergence Audit

Date: 2026-03-08
Status: closed through `RW-206` and superseded for namespace debt by `NP-303`

This audit starts the post-migration convergence campaign. It supersedes the narrower March 8 "finish-line" interpretation that treated the Swift shell migration as architecturally complete.

## Mission

Converge the Swift app onto one canonical architecture by deleting transitional wrappers, tracked review artifacts, dead components, and mixed-era ownership that still lets the new shell sit on top of old-model code.

## Method

- Re-read the existing rewrite control plane in `rewrite/`.
- Ran the rewrite guard baseline.
- Diffed PR `#27` against `main` to explain the additive migration shape.
- Traced live references from `Application`, `Adapters`, `Composition`, and production views into legacy `Models` / `Features` code.
- Counted the residual seams that still bind the new shell to the old substrate.

## Measured Convergence Debt

Measured on March 8, 2026.

| Pattern | Current count | Why it matters | Ratchet |
| --- | ---: | --- | --- |
| top-level Swift files in `apps/swift/Sources/Capacitor/Models` | 20 | legacy substrate still larger than the new shell should tolerate | freeze at `<= 20`; drive to `0` or rehome out of `Models` |
| top-level Swift files in `apps/swift/Sources/Capacitor/Features` | 1 | migration-era façade layer still exists | freeze at `<= 1`; drive to `0` |
| `SetupRequirementsManager` refs from `Application` / `Composition` | 4 | new setup workflow is still a wrapper over old manager logic | freeze at `<= 4`; drive to `0` |
| `ActiveProjectResolver` refs from `Application` | 2 | activation tracking still wraps legacy resolver ownership | freeze at `<= 2`; drive to `0` |
| `ProjectIngestionWorker` refs from `Application` | 3 | project mutation still delegates to legacy ingestion worker | freeze at `<= 3`; drive to `0` |
| `SessionStateManager` refs from `Application` | 5 | runtime/session orchestration still depends on model-layer state logic | freeze at `<= 5`; drive to `0` |
| `ShellStateStore` refs from `Application` | 2 | runtime session orchestration still depends on model-layer storage state | freeze at `<= 2`; drive to `0` |
| `RuntimeClient` refs from `Adapters` / `Debug` / `Utilities` | 3 | adapter/debug code still depends on model-layer transport ownership | freeze at `<= 3`; drive to adapter-native ownership |
| `TerminalLauncher` refs from `Adapters` / `Composition` | 6 | shell activation infra still lives in `Models` instead of adapter/support ownership | freeze at `<= 6`; drive to rehome |
| tracked files under `tmp/review-package` | 25 | audit artifacts are inflating the repo and misleading future agents | drive to `0` now; keep at `0` |

## Inventory and Leverage

### High leverage

- `apps/swift/Sources/Capacitor/Composition/AppState.swift`
  Why: still the mixed-era hub where old managers/coordinators and new application state meet.
- `apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift`
  Why: canonical live composition root; the right place to pull construction/wiring out of legacy objects.
- `apps/swift/Sources/Capacitor/Composition/AppState.swift`
  Why: the final outer UI/composition state surface that replaced the old top-level `Models/AppState.swift` residency.
- `apps/swift/Sources/Capacitor/Application/*`
  Why: this is where wrapper ownership must either become real or be deleted.
- `apps/swift/Sources/Capacitor/Adapters/*`
  Why: adapter boundaries should own transport/execution infrastructure rather than reach back into `Models`.
- `apps/swift/Sources/Capacitor/Models/*`
  Why: this directory is the main vestigial reservoir and must shrink slice by slice.

### Medium leverage

- `apps/swift/Sources/Capacitor/Debug/*`
  Why: some debug surfaces are still useful, but several are transitional and should be consciously retained or deleted.
- `docs/audit/*`
  Why: historical docs are acceptable only if clearly marked historical; the latest guidance must be unambiguous.
- `apps/swift/Tests/CapacitorTests/ArchitectureBoundaryTests.swift`
  Why: strong ratchet surface, but currently too broad and transition-oriented.

### Low leverage / immediate deletion candidates

- `tmp/review-package/*`
- `apps/swift/Sources/Capacitor/Views/Components/RuntimeStatusCard.swift`
- `apps/swift/Sources/Capacitor/Views/Components/ProgressiveBlurView.swift`

These are either tracked artifacts or confirmed-unreferenced UI components.

## Hard Conclusions

1. The Swift shell migration was additive. It introduced `Application`, `Adapters`, `Composition`, and `Domain`, but did not delete the old Swift substrate in the same campaign.
2. The remaining debt is not just "dead code." The more important problem is parallel ownership: the new shell still wraps legacy managers, coordinators, stores, and transport classes.
3. `Models` and `Features` are now quarantine zones, not neutral namespaces. Their file counts must only fall from here.
4. Tracked review packages and confirmed-dead components should be deleted immediately rather than waiting for larger architectural slices.
5. The repo needs a new convergence control plane because the prior March 8 finish-line artifacts define success too loosely for an immaculate codebase.

## Proposed Slices

### RW-200: Convergence Audit + Ratchet Reset
Status: completed.

Outcome:

- reset the charter/decision surface around the stricter convergence standard
- record the measured Swift convergence debt
- freeze the current mixed-ownership seams with ratchets so they can only shrink

### RW-201: Hygiene Reset
Status: completed.

Outcome:

- delete tracked `tmp/review-package` artifacts
- delete confirmed-dead Swift components
- keep only clearly intentional debug surfaces

### RW-202: Feature Facade Deletion
Status: completed.

Outcome:

- delete `Features/ProjectFeatureCoordinator.swift`
- move navigation / idea / project feature ownership into canonical application-layer state/use-case objects
- remove direct view dependency on the migration-era feature façade

### RW-203: Setup Convergence
Status: completed.

Outcome:

- replace `SetupWorkflowState` as a wrapper over `SetupRequirementsManager` with real application-owned setup state/use cases
- delete `Models/SetupRequirements.swift`
- move shell-integration install policy out of ad hoc startup glue

### RW-204: Runtime / Activation Dependency Convergence
Status: completed.

Outcome:

- remove `ActiveProjectResolver`, `ProjectIngestionWorker`, `SessionStateManager`, and `ShellStateStore` dependencies from the application layer
- rehome `RuntimeClient` and `TerminalLauncher` ownership into canonical adapter/support surfaces

### RW-205: AppState Endgame
Status: completed.

Outcome:

- shrink `AppState` to pure outer UI aggregation state
- move remaining construction/wiring out to `AppShellContainer`
- delete or rehome residual legacy managers that only exist because `AppState` still owns them

### RW-206: Final Vestigial Sweep
Status: completed.

Outcome:

- split broad transition-era ratchets into smaller canonical tests
- delete superseded docs and remaining explicitly transitional debug/development residue
- close the convergence campaign with a truthful checkpoint

## Closed State

The closed tranche leaves one deliberate distinction in place:

- vestigial transition seams are deleted
- some canonical implementation files still physically live under `Models/`

The ratchets now prove that the new shell layers no longer depend on those legacy type names directly. If we want to remove the old path names too, that is a new namespace-purity tranche rather than unfinished convergence work.

That follow-through is now complete: `NP-303` rehomed the remaining top-level runtime implementation files out of `Models/`.
