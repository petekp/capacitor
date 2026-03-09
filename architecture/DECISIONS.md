# Architecture Decisions Log

This file records architecture decisions that are locked for the architecture.

## D-001: No Daemon Core
- Date: 2026-02-28
- Status: accepted
- Decision: Remove daemon IPC as the primary runtime path; use a single UniFFI-exposed Rust runtime.
- Why: Eliminates duplicate state ownership, transport complexity, and schema drift.

## D-002: Strangler with Hard Gates
- Date: 2026-02-28
- Status: accepted
- Decision: Migrate capability-by-capability with strict per-slice deletion and CI enforcement.
- Why: Prevents partial migration drift and vestigial remnants.

## D-003: Replay-Diff + E2E Smoke as Acceptance Oracle
- Date: 2026-02-28
- Status: accepted
- Decision: Functional parity is proven by replay-diff corpus plus scenario smoke checks.
- Why: Provides deterministic confidence across sessions and context compaction.

## D-004: Rust Owns Domain Semantics
- Date: 2026-02-28
- Status: accepted
- Decision: Rust is canonical for path/workspace identity, session/project state derivation, and activation planning.
- Why: Prevents cross-language policy duplication.

## D-005: No Legacy Compatibility Constraint
- Date: 2026-02-28
- Status: accepted
- Decision: Breaking internal API changes are allowed when they reduce complexity and improve architecture.
- Why: Single-user product with explicit architecture intent.

## D-006: Project Model Mirrors Are Cleanup Debt, Not Compatibility Policy
- Date: 2026-03-07
- Status: accepted
- Decision: Treat `ProjectWorkflowState.legacyProjects`, `legacySuggestedProjects`, and `selectedLegacySuggestedProjects` as vestigial Swift-side migration bridges to delete, while preserving explicit user-data/settings migration bridges and keeping `ProjectCatalogBridge` as a boundary anti-corruption adapter until the upstream UniFFI/core DTO boundary becomes shell-native.
- Why: The shell already owns project catalog policy. The remaining `legacy*` mirrors only duplicate shell DTOs inside Swift and keep views/helpers coupled to legacy types longer than necessary, while `ProjectCatalogBridge` still serves a real boundary-conversion role at the FFI edge.

## D-007: AppShellContainer Owns Live Composition; AppState Keeps Only Local Outer-Layer Wiring
- Date: 2026-03-07
- Status: accepted
- Decision: Treat `AppShellContainer` as the sole live composition root in production, with `AppStateTestSupport` as the test-only construction helper. `AppState` may retain local collaborator wiring for outer-layer services that close over `AppState`-owned UI/composition state, but it must not grow new convenience constructors, live dependency factories, or direct live gateway/supervisor construction.
- Why: The meaningful architecture boundary is choosing the live world, and that now happens outside `AppState`. Moving the remaining closure-heavy collaborator wiring into a second assembler would mostly relocate self-referential setup without deleting policy or meaningfully reducing coupling.

## D-008: No Parallel Rust Ownership Inside `CoreRuntime`
- Date: 2026-03-08
- Status: accepted
- Decision: For each bounded context in `capacitor-core`, production behavior must either route through the `contexts/*` service layer or the unused scaffold must be deleted. `CoreRuntime` may remain the UniFFI façade, but it must not permanently keep direct legacy helper ownership beside dormant bounded-context application services.
- Why: The remaining finish-line debt is not another Swift shell problem. It is parallel ownership inside the Rust core. Leaving both direct `runtime_*` / config / setup-helper paths and scaffold-only context services in place preserves ambiguity, blocks deletion, and prevents the repo from ever reaching one canonical architecture.

## D-009: Rust Plans Activation; Swift Executes Terminal Side Effects
- Date: 2026-03-08
- Status: accepted
- Decision: Finish-line activation ownership will be singular: Rust owns activation planning and returns the activation decision contract, while Swift owns execution of terminal, AX, AppleScript, tmux, and app-focus side effects. `TerminalLauncher` should shrink toward an executor over Rust-provided actions rather than remain the planner of record.
- Why: The repo already contains a large tested pure activation planner in `core/capacitor-core/src/runtime_activation`, while production activation still routes through `LiveActivationGateway` + `TerminalLauncher` in Swift. Deleting the Rust activation path would throw away the more explicit planning model and contradict the architecture charter. The cleaner finish line is to promote that planner into production via FFI and stop duplicating planning policy in Swift.

## D-010: Production Activation Ownership Remains Swift-Owned
- Date: 2026-03-08
- Status: accepted
- Decision: Supersede D-009 for the finish-line campaign. Production activation planning/execution remains Swift-owned, and the dormant Rust activation bounded context shell plus the test-only `runtime_activation` planner are deleted instead of promoted through FFI.
- Why: Production activation already lives entirely in Swift (`LiveActivationGateway` + `TerminalLauncher`), while the Rust activation path is non-production scaffold/test-only logic. Promoting Rust would require a larger FFI/bindings and Swift executor redesign campaign. The lowest-risk finish-line move is one production owner in Swift plus deletion of the unused Rust path.

## D-011: Project Catalog FFI Boundary Is Now Shell-Native
- Date: 2026-03-08
- Status: accepted
- Decision: The app-facing FFI project/catalog boundary now exports shell-native DTOs (`ShellProjectCatalogEntry`, `ShellProjectStats`, `ShellSuggestedProjectCandidate`) directly. Swift keeps only thin ergonomics/extensions around those generated types and deletes `ProjectCatalogBridge`.
- Why: The earlier bridge existed only because the UniFFI/core boundary was still legacy-shaped. Once the Rust core exports shell-native catalog DTOs directly, keeping a second Swift catalog type system would reintroduce needless translation and vestigial architecture.

## D-012: The Real Finish Line Is Zero Transitional Swift Ownership
- Date: 2026-03-08
- Status: accepted
- Decision: Supersede the narrower interpretation of the March 8 finish-line checkpoint for Swift. The codebase is not considered converged while `Application`, `Adapters`, or `Composition` still wrap legacy `Models` / `Features` ownership, while tracked review artifacts remain in-tree, or while confirmed-dead migration debris is retained.
- Why: A migration is not actually complete when the new architecture sits on top of the old substrate. That state still imposes extra reading cost, ambiguous ownership, and future agent drift.

## D-013: Mixed-Ownership Seams Must Be Ratcheted Numerically
- Date: 2026-03-08
- Status: accepted
- Decision: Freeze the measured Swift convergence seams with numeric CI budgets: top-level file counts in `Models` / `Features`, and references from new shell layers to legacy types such as `SetupRequirementsManager`, `ActiveProjectResolver`, `ProjectIngestionWorker`, `SessionStateManager`, `ShellStateStore`, `RuntimeClient`, and `TerminalLauncher`. These counts may only decrease.
- Why: Agents are good at adding architecture and poor at deleting substrate. Numeric ratchets turn "this still feels transitional" into a deterministic pass/fail signal.

## D-014: Namespace Purity Is A New Tranche, Not Unfinished Convergence
- Date: 2026-03-08
- Status: accepted
- Decision: After `RW-206`, the remaining `Models/` debt is treated as naming/location debt rather than mixed-ownership debt. Continuing to remove those legacy path names is a new namespace-purity tranche, not unfinished convergence work.
- Why: The convergence tranche eliminated the actual transitional seams. What remains is that several canonical implementations still physically live under `Models/`, which hurts readability but no longer creates parallel ownership in the new shell layers.

## D-015: Namespace Purity Starts With Low-Risk Leaf Rehomes
- Date: 2026-03-08
- Status: accepted
- Decision: The namespace-purity tranche begins by rehoming low-risk leaf files out of `Models/` before touching high-blast-radius runtime/activation implementations. First targets are pure presentation/setup/runtime value files and isolated helpers such as `HookPresentationPolicy`, `HookDiagnosticPresentation`, `SetupStepCatalog`, `SetupReadinessCoordinator`, `RuntimeStatus`, `WindowFrameStore`, `GhosttyAXReader`, and `ShellSetupInstructions`.
- Why: This lowers the `Models/*.swift` budget quickly without risking runtime regressions, and it creates a clean pattern for later, higher-risk moves.

## D-016: The Existing Architecture Control Plane Remains Canonical Through The True Ending
- Date: 2026-03-08
- Status: accepted
- Decision: Continue the finish-line work inside the existing `architecture/CHARTER.md`, `architecture/DECISIONS.md`, `architecture/SLICES.yaml`, `architecture/MAP.csv`, and `architecture/HANDOFF.md` artifacts rather than opening a parallel migration ledger.
- Why: A second ledger would split authority, break ratchet continuity, and recreate the drift problems the control plane exists to prevent.

## D-017: The True Ending Requires Truthful Ratchets, Truthful Docs, And Zero Accidental Namespace Debt
- Date: 2026-03-08
- Status: accepted
- Decision: The codebase is not considered finished while any of these remain: ratchets pointing at deleted paths or inflated budgets, actionable-looking historical checkpoint docs, or residual Swift namespace debt such as the nested `Models/WindowAnchoring/*` subtree. The finish line also includes an explicit decision on whether `architecture/` remains permanent governance or is archived.
- Why: After convergence and namespace purity, the remaining risk is no longer structural confusion between old and new architecture. It is misleading operational residue that makes the repo look cleaner than it is.

## D-018: Window Anchoring Is Support Infrastructure, Not Model-Layer Code
- Date: 2026-03-08
- Status: accepted
- Decision: `WindowAnchoringController`, `WindowBoundsProvider`, and their anchor-support types belong under `Support/WindowAnchoring/`, not under `Models/`.
- Why: The subsystem is AppKit/window-management infrastructure. Keeping it under `Models/` is pure namespace debt with no architectural upside.

## D-019: AppState Remains The Intentional SwiftUI Shell Environment Hub
- Date: 2026-03-08
- Status: accepted
- Decision: `Composition/AppState.swift` remains the single top-level SwiftUI shell environment object and may aggregate references to canonical application/support/composition collaborators, as long as it does not resume owning construction, duplicate policy, or duplicated lifecycle state.
- Why: The remaining `AppState` surface is broad but intentional. The file is now small, builds nothing, and mainly exposes already-canonical state objects to views/tests. Further splitting would mostly relocate references without deleting meaningful complexity.

## D-020: Architecture Control Plane Becomes Permanent Governance, Not Archived Migration Debris
- Date: 2026-03-08
- Status: accepted
- Decision: Keep `architecture/CHARTER.md`, `architecture/DECISIONS.md`, `architecture/SLICES.yaml`, `architecture/MAP.csv`, `architecture/HANDOFF.md`, and their guard scripts as the repo’s ongoing architecture-governance surface rather than archiving them after the finish-line tranche.
- Why: The ratchets and decision history still provide durable value after migration. Archiving them while they remain the source of CI truth would split authority and recreate drift.

## D-021: Unlinked Audit Scaffolds And Orphaned Metadata Files Are Dead Code
- Date: 2026-03-08
- Status: accepted
- Decision: Delete analysis-stage audit scaffolds and stray Finder metadata files when they have zero inbound references from current docs, code, CI, or architecture governance. Keep unreferenced but plausibly intentional manual utilities as review-only until their role is explicitly retired.
- Why: A repo can be migration-complete and still not be pristine if it carries orphaned analysis artifacts and filesystem cruft. Those files consume attention without serving a live purpose.

## D-022: Migration-Shaped Names Must Be Renamed Or Archived
- Date: 2026-03-08
- Status: accepted
- Decision: The repo is not pristine while active code or governance still carries migration-era namespace names like `contexts/` and `architecture/`. Live Rust bounded contexts must move to a permanent namespace, and the repo-level governance surface must adopt a permanent architecture name.
- Why: Even when the behavior is correct, migration-shaped names keep advertising an intermediate state instead of the steady-state system.

## D-023: Rust `contexts/` Becomes `contexts/`
- Date: 2026-03-08
- Status: accepted
- Decision: Rename `core/capacitor-core/src/clean` to `core/capacitor-core/src/contexts`, and rename `CleanArchitectureShell` to a neutral service/composition name.
- Why: The subsystem is live production code, not a temporary bounded-context experiment. `contexts/` is a durable name for bounded-context services without prescribing a specific dogma.

## Change Control
1. New decisions must be appended with a unique ID.
2. Reversals require a superseding decision entry, not silent edits.
3. Any decision change must reference affected slices in `architecture/SLICES.yaml`.
