## Handoff — 2026-03-08

### Changed
- Started a new post-migration convergence campaign on top of the closed `RW-112` finish-line control plane.
- Added a new convergence audit, reference guide, stricter charter language, and fresh ratchets for measured Swift mixed-ownership seams.
- Completed `RW-201` hygiene reset by deleting tracked review-package artifacts and confirmed-dead Swift components.
- Completed `RW-202` by deleting `ProjectFeatureCoordinator`, routing navigation directly through `NavigationState`, and introducing `ProjectPresentationState` as the canonical application-owned detail/idea/project-creation presentation surface.
- Completed `RW-203` by moving setup lifecycle state and preview behavior into `Application/Setup/SetupWorkflowState.swift`, deleting `Models/SetupRequirements.swift`, deleting the manager-specific setup test file, and moving shell-integration install decisions into `SetupStartupCoordinator`.
- Completed `RW-204` by deleting `ActiveProjectResolver.swift` and `ProjectIngestionWorker.swift`, routing application runtime/session flows through canonical ports, and moving adapter/composition transport naming onto `RuntimeSnapshotReader` and `ShellActivationExecutor`.
- Completed `RW-205` by moving AppState collaborator assembly into `Composition/AppStateServices.swift`, having composition/test helpers install and start the graph explicitly, and deleting the last local AppState assembly/startup path.
- Completed `RW-206` by deleting the temporary debug surfaces, splitting the broad architecture ratchet monolith into smaller canonical suites, and rewriting the stale March 8 checkpoint into a truthful tranche-closure document.
- Started the namespace-purity tranche with `NP-300` and completed `NP-301` by rehoming eight low-risk leaf files out of `Models/` into `Application/Setup`, `Application/Runtime`, and `Support`.
- Completed `NP-302` by rehoming `ProjectDetailsManager`, `ProjectCreationCoordinator`, and `HookServerManager` out of `Models/`, updating the path-sensitive ratchets/docs, and lowering the `Models` budget from `9` to `6`.
- Completed `NP-303` by rehoming `RuntimeClient`, `SessionStateManager`, `ShellStateStore`, `TerminalLauncher`, `WorkstreamsManager`, and `AppState` out of `Models/`, updating the path-sensitive ratchets/docs, and lowering the top-level `Models` budget from `6` to `0`.
- Retargeted agent-facing docs, the runtime reliability guard, and the replay fixture corpus to the live post-rehome paths; correcting those stale paths exposed one real `HookServerManager` startup `waitUntilExit()` call, so the reliability ratchet is now calibrated to a truthful `1`.
- Started the true-ending tranche with `TE-400`, keeping the existing control plane authoritative and freezing the remaining finish-line debt: nested `WindowAnchoring/*` namespace residue, historical checkpoint `TODO (user-run)` tables, and the remaining nonzero live reliability budgets.
- Completed `TE-401` by converting the March 6 and March 7 checkpoints into explicit archive stubs, deleting their actionable TODO residue, and keeping the current March 8 checkpoint authoritative.
- Completed `TE-402` by rehoming the final Swift `Models/WindowAnchoring/*` subtree into `Support/WindowAnchoring/*`, lowering the residual nested `Models` budget from `3` to `0`.
- Completed `TE-403` by removing the live `HookServerManager.waitUntilExit()` startup probe, switching to async termination-callback discovery, and proving stop/probe race behavior with focused tests.
- Completed `TE-404` by removing the remaining live subprocess debt in `ProjectDetailsManager`, `TerminalLauncher`, and `WorktreeService`, and lowering those three runtime-reliability budgets to `0`.
- Completed `TE-405` by making the explicit decision that `Composition/AppState.swift` remains the intentional SwiftUI shell-environment hub rather than further splitting it for cosmetic reasons.
- Completed `TE-406` by making the explicit end-state decision that `rewrite/` remains the permanent architecture-governance surface.
- Completed `DC-500` by auditing the post-finish-line repo for dead artifacts and separating confirmed dead files from merely unreferenced manual utilities.
- Completed `DC-501` by deleting the confirmed dead audit scaffolds, the unreferenced `test-agent-observe.sh` harness, and stray `.DS_Store` metadata files.
- Completed `DC-502` by deleting the unreferenced `fetch-cc-docs.ts` utility and documenting `apply-icon-mask.swift` so the retained manual utility set is explicit rather than orphaned.

### Now True
- The rewrite control plane no longer treats the March 8 "finish line" as the final architectural standard for Swift.
- `tmp/review-package` is a forbidden path, not a tracked artifact bucket.
- `Models` and `Features` are explicitly ratcheted debt surfaces that can only shrink.
- `scripts/rewrite/check_rewrite_guards.sh --status` passes with the new convergence budgets, and `cd apps/swift && swift test` passes after the hygiene deletions.
- `apps/swift/Sources/Capacitor/Features` now has a zero-file budget, and `ProjectFeatureCoordinator` is guarded at zero production references.
- `apps/swift/Sources/Capacitor/Models/SetupRequirements.swift` is deleted, and `SetupRequirementsManager` is guarded at zero application/composition references.
- `Application`, `Adapters`, `Composition`, and `Utilities` are now guarded at zero non-canonical references to `ActiveProjectResolver`, `ProjectIngestionWorker`, `SessionStateManager`, `ShellStateStore`, `RuntimeClient`, and `TerminalLauncher`.
- `apps/swift/Sources/Capacitor/Models/*.swift` is now at a `0` top-level-file baseline.
- `AppState` no longer assembles collaborators or starts bootstrap/creation workflows locally; that now happens explicitly in composition.
- The declared convergence tranche (`RW-200` through `RW-206`) is closed, with no pending or in-progress slices in the current control plane.
- The namespace-purity tranche is closed through `NP-303`.
- Canonical runtime/support/composition files now live at:
  - `Support/RuntimeClient.swift`
  - `Support/TerminalLauncher.swift`
  - `Application/Runtime/SessionStateManager.swift`
  - `Application/Runtime/ShellStateStore.swift`
  - `Application/Projects/WorkstreamsManager.swift`
  - `Composition/AppState.swift`

### Remains
- `AppState` still owns a broad set of installed services and UI-facing references, even though it no longer assembles them.
- The only remaining Swift files under `Models/` are the nested `WindowAnchoring/*` implementation files.
- `scripts/ci/runtime-reliability-guard.sh` now points at the live support/application/composition files instead of silently checking deleted paths.
- `scripts/rewrite/check_rewrite_guards.sh` now freezes the last nested `Models/WindowAnchoring/*` subtree and the remaining historical checkpoint TODO rows.
- `scripts/rewrite/check_rewrite_guards.sh` now passes with `swift_models_window_anchoring_files: 0/0` and `historical_checkpoint_user_run_todos: 0/0`.
- `scripts/ci/runtime-reliability-guard.sh` now records `WorktreeService.waitUntilExit()` as explicit debt and lowers the stale `AppState dragdrop group.leave` budget to `0`.
- `scripts/ci/runtime-reliability-guard.sh` now passes with `HookServer waitUntilExit: 0/0`.
- `scripts/ci/runtime-reliability-guard.sh` now also passes with `ProjectDetails waitUntilExit: 0/0`, `Terminal outputData append: 0/0`, and `WorktreeService waitUntilExit: 0/0`.
- Historical docs that remain are intentionally archived or explicitly marked historical.
- `Composition/AppState.swift` is explicitly retained as the shell environment hub, and `rewrite/` is explicitly retained as permanent governance.
- the unlinked audit scaffolds (`00-analysis-plan`, `01-system-context`, `02-container-diagram`, `03-core-components`) are gone
- stray `.DS_Store` metadata is gone from `scripts/` and `.claude/`
- the remaining manual utility scripts are now explicitly intentional:
  - `scripts/release/release.sh`
  - `scripts/utils/apply-icon-mask.swift`
The finish-line tranche is closed, and the first pristine-sweep dead-code tranche is also closed. The remaining nonzero budgets in runtime-reliability are retained migration-regression guards, not open finish-line debt.

### Next Steps
1. Run `scripts/rewrite/check_rewrite_guards.sh --status` and `scripts/ci/runtime-reliability-guard.sh --status` to confirm the closed pristine-sweep baseline.
2. Treat `docs/audit/TRUE_ENDING_AUDIT_2026-03-08.md` and `docs/audit/DEAD_CODE_SWEEP_AUDIT_2026-03-08.md` as the canonical closure documents for the migration and pristine sweep.
3. The remaining utility scripts are intentional; future cleanup should be treated as product/tooling decisions, not dead-code recovery.
