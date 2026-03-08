# Rewrite Decisions Log

This file records architecture decisions that are locked for the rewrite.

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
- Why: Single-user product with explicit rewrite intent.

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
- Decision: For each bounded context in `capacitor-core`, production behavior must either route through the `clean/*` service layer or the unused scaffold must be deleted. `CoreRuntime` may remain the UniFFI façade, but it must not permanently keep direct legacy helper ownership beside dormant clean-shell application services.
- Why: The remaining finish-line debt is not another Swift shell problem. It is parallel ownership inside the Rust core. Leaving both direct `runtime_*` / config / setup-helper paths and scaffold-only clean services in place preserves ambiguity, blocks deletion, and prevents the repo from ever reaching one canonical architecture.

## D-009: Rust Plans Activation; Swift Executes Terminal Side Effects
- Date: 2026-03-08
- Status: accepted
- Decision: Finish-line activation ownership will be singular: Rust owns activation planning and returns the activation decision contract, while Swift owns execution of terminal, AX, AppleScript, tmux, and app-focus side effects. `TerminalLauncher` should shrink toward an executor over Rust-provided actions rather than remain the planner of record.
- Why: The repo already contains a large tested pure activation planner in `core/capacitor-core/src/runtime_activation`, while production activation still routes through `LiveActivationGateway` + `TerminalLauncher` in Swift. Deleting the Rust activation path would throw away the more explicit planning model and contradict the rewrite charter. The cleaner finish line is to promote that planner into production via FFI and stop duplicating planning policy in Swift.

## D-010: Production Activation Ownership Remains Swift-Owned
- Date: 2026-03-08
- Status: accepted
- Decision: Supersede D-009 for the finish-line campaign. Production activation planning/execution remains Swift-owned, and the dormant Rust clean activation shell plus the test-only `runtime_activation` planner are deleted instead of promoted through FFI.
- Why: Production activation already lives entirely in Swift (`LiveActivationGateway` + `TerminalLauncher`), while the Rust activation path is non-production scaffold/test-only logic. Promoting Rust would require a larger FFI/bindings and Swift executor redesign campaign. The lowest-risk finish-line move is one production owner in Swift plus deletion of the unused Rust path.

## D-011: Project Catalog FFI Boundary Is Now Shell-Native
- Date: 2026-03-08
- Status: accepted
- Decision: The app-facing FFI project/catalog boundary now exports shell-native DTOs (`ShellProjectCatalogEntry`, `ShellProjectStats`, `ShellSuggestedProjectCandidate`) directly. Swift keeps only thin ergonomics/extensions around those generated types and deletes `ProjectCatalogBridge`.
- Why: The earlier bridge existed only because the UniFFI/core boundary was still legacy-shaped. Once the Rust core exports shell-native catalog DTOs directly, keeping a second Swift catalog type system would reintroduce needless translation and vestigial architecture.

## Change Control
1. New decisions must be appended with a unique ID.
2. Reversals require a superseding decision entry, not silent edits.
3. Any decision change must reference affected slices in `rewrite/SLICES.yaml`.
