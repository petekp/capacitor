## Handoff — 2026-03-05

### Changed
- Ratified holistic control plane artifacts:
  - `.claude/migration/CHARTER.md`
  - `.claude/migration/SLICES.yaml`
  - `.claude/migration/MAP.csv`
  - `.claude/migration/guard.sh`
  - `.claude/migration/DECISIONS.md`
  - `.claude/migration/HOLISTIC_PLAN.md`
- Completed all Phase 1 high-severity Rust slices:
  - `r1-1`: removed ambient cwd fallback from `HookInput::resolve_cwd` and added regression tests.
  - `r1-2`: enforced body-size caps for chunked/no-`Content-Length` requests and added integration coverage.
  - `r1-3`: replaced unsupported `handle` verification probe with supported CLI surface validation (`--help` + `serve`/`cwd`).
- Completed all Phase 1 high-severity Swift slices:
  - `s1-1`: replaced onboarding `fatalError` with recoverable setup initialization error state and surfaced UI message.
  - `s1-2`: applied stale-generation guard atomically across session + shell state commits.
  - `s1-3`: changed metadata fallback from global rollback to held-path scoped fallback.
  - `s1-4`: synchronized terminal output aggregation and added cancellation + timeout process termination.
  - `s1-5`: refactored drop URL extraction to deterministic grouped loaders with lock-protected accumulation.
- Completed Phase 2 slice `s2-1`:
  - tracked creation session/completion monitor tasks by creation ID in `AppState`
  - cancelled monitor tasks whenever a creation enters a terminal state
  - blocked late session-discovery callbacks from reviving cancelled/failed/completed creations
- Completed Phase 2 slice `s2-2`:
  - removed the main-actor-blocking `waitUntilExit()` stop path from `HookServerManager`
  - added explicit lifecycle generation and tracked health-check cancellation so late failures cannot restart after stop
  - validated pidfile adoption against the expected hook binary before adopting, and terminate adopted pid ownership on stop
- Completed Phase 2 slice `r2-1`:
  - tightened hook-health grace to require active session states plus recent activity
  - stopped runtime snapshot conversion from fabricating `is_alive = true`
  - added Rust regressions for stale/ready/dead session handling and snapshot liveness mapping
- Completed Phase 2 slice `r2-2`:
  - replaced directory-mtime project ordering with latest non-agent session-file activity
  - aligned project sort order with the existing `last_active` signal
  - added a regression proving appended session activity outranks a newer Claude project directory
- Completed Phase 2 slice `s2-3`:
  - moved sensemaking git subprocess execution behind a detached loader path
  - collapsed three main-actor git waits into one shared git runner off the main actor
  - added a regression proving the main actor stays responsive while git context loading is artificially blocked
- Added/updated tests:
  - `core/hud-hook/src/hook_types.rs` tests for cwd fallback behavior.
  - `core/hud-hook/tests/serve_integration.rs` oversized no-length/chunked payload rejection test.
  - `core/capacitor-core/src/runtime_setup.rs` unsupported CLI shape verification test.
  - `apps/swift/Tests/CapacitorTests/SetupRequirementsManagerTests.swift` recoverable init failure test.
  - `apps/swift/Tests/CapacitorTests/AppStateSessionObservationTests.swift` stale snapshot shell-state guard test.
  - `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift` held-path metadata isolation test.
  - `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` cancellation promptness test.
  - `apps/swift/Tests/CapacitorTests/AppStateDropTests.swift` async mixed loader collection test.
  - `apps/swift/Tests/CapacitorTests/AppStateCreationTests.swift` cancellation/reactivation regressions for creation monitors.
  - `apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift` stop intent, late health failure, and pid adoption coverage.
  - Rust `lib.rs` tests for grace-window active-session semantics.
  - Rust `runtime_state/snapshot.rs` test proving persisted snapshots keep `is_alive` unknown.
  - Rust `runtime_projects.rs` test proving sort order follows latest session file activity.
  - `apps/swift/Tests/CapacitorTests/ProjectDetailsManagerObservationTests.swift` regression proving git context loading does not block the main actor.
- Appended Decisions 13–25 in `DECISIONS.md`.
- Added new holistic ratchets and tightened budgets to zero where fixed (`fatalError` path, `arg("handle")`, env cwd fallback, global metadata fallback).

### What Is Now True
- Phase 1 (all high-severity findings from Rust+Swift audits) is complete in the slice ledger.
- Guard baseline is green:
  - `bash .claude/migration/guard.sh --status` passes.
- Verified test commands executed successfully:
  - `cargo test -p hud-hook`
  - `cargo test -p capacitor-core`
  - `swift test --filter SetupRequirementsManagerTests`
  - `swift test --filter AppState`
  - `swift test --filter HookServer`
  - `swift test --filter AppStateSessionObservationTests`
  - `swift test --filter TerminalLauncherTests`
  - `swift test --filter AppStateDropTests`
  - targeted `SessionStateManagerTests/testIdleHoldOnlyPreservesMetadataForHeldProject`
- Guard ratchet improved:
  - `HookServer waitUntilExit` budget is now `0`, and current count is `0`.
  - `ProjectDetails waitUntilExit` budget is now `2`, and current count is `2`.
- Known pre-existing time-dependent failures in `SessionStateManagerTests` remain (tracked for `t4-1`) and were not introduced by these slices.

### What Remains
- Phase 2 medium-severity lifecycle/liveness slices are complete.
- Phase 3 architectural simplification slices are open:
  - `a3-1` to `a3-5`
- Phase 4 regression shield + operational readiness slices are open:
  - `t4-1` to `t4-4`

### Exact Next Steps
1. Start `a3-1` in `.claude/migration/SLICES.yaml`.
2. Define the first extraction boundary inside `AppState` (runtime projection, lifecycle supervision, or feature creation flow) and add behavior-preserving tests around that seam.
3. Extract the chosen service module with explicit ownership and dependency injection, keeping `AppState` as orchestration only.
4. Run:
   - `swift test --filter AppState`
   - `bash .claude/migration/guard.sh --status`
5. Close `a3-1` in `SLICES.yaml` and `MAP.csv`, append decision notes for the chosen ownership boundary.

## Handoff — 2026-03-05
### Changed
- Completed `a3-1` by extracting the project-creation subsystem from `AppState` into `apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift`.
- Reduced `apps/swift/Sources/Capacitor/Models/AppState.swift` to a composition-root facade for creation behavior, with thin shims delegating to the coordinator.
- Recorded Decision 26 in `DECISIONS.md` and closed the `a3-1` rows in `MAP.csv` and `SLICES.yaml`.

### Now True
- `AppState` no longer owns creation persistence, prompt/file generation, Claude launch/resume orchestration, or creation monitor task state directly.
- `ProjectCreationCoordinator` is the explicit owner of the project-creation workflow and its async monitor lifecycle.
- Focused AppState regression coverage still passes after the extraction:
  - `swift test --filter AppState`

### Remains
- Phase 3 simplification slices still open:
  - `a3-2` to `a3-5`
- `a3-2` is now unblocked and is the next highest-confidence architectural slice.
- Known pre-existing time-dependent failures in `SessionStateManagerTests` remain tracked for `t4-1`.

### Exact Next Steps
1. Run:
   - `swift test`
   - `bash .claude/migration/guard.sh --status`
2. Start `a3-2` in `.claude/migration/SLICES.yaml`.
3. Write the first behavior-preserving tests around activation-owner selection across Rust activation planning, Swift launch path, and bridge boundaries.
4. Remove or quarantine the non-owner activation path in the same slice, then tighten any affected ratchets/denylist patterns.

## Handoff — 2026-03-05
### Changed
- Completed `a3-2` by choosing Swift `TerminalLauncher` as the single production activation owner.
- Removed the exported UniFFI activation planner surface from `core/capacitor-core/src/lib.rs` and regenerated:
  - `apps/swift/bindings/capacitor_core.swift`
  - `apps/swift/bindings/capacitor_coreFFI.h`
  - `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift`
  - `apps/swift/Sources/Capacitor/Bridge/capacitor_coreFFI.h`
- Quarantined `core/capacitor-core/src/runtime_activation/` behind `#[cfg(test)]` so production builds no longer compile the duplicate planner.
- Recorded Decision 27 and closed `a3-2` in `SLICES.yaml` and `MAP.csv`.

### Now True
- There is no production Rust/UniFFI activation planner API for Swift to call.
- `TerminalLauncher.performUnifiedActivation` remains the only production activation decision path.
- Slice smoke verification passed:
  - `swift test --filter Terminal`
  - `cargo test -p capacitor-core`

### Remains
- Phase 3 simplification slices still open:
  - `a3-3` to `a3-5`
- Known full-suite Swift failures remain outside this slice in `SessionStateManagerTests` (tracked for `t4-1`).

### Exact Next Steps
1. Run `bash .claude/migration/guard.sh --status`.
2. Start `a3-3` in `.claude/migration/SLICES.yaml`.
3. Extract the setup/check/install/verify path into an explicit lifecycle state machine centered on `SetupRequirements.swift` and `HookServerManager.swift`.
4. Preserve behavior with focused `swift test --filter Setup` coverage before deleting ad hoc transition branches.

## Handoff — 2026-03-05
### Changed
- Completed `a3-3` by introducing `SetupLifecycleState` in `apps/swift/Sources/Capacitor/Models/SetupRequirements.swift`.
- Refactored `SetupRequirementsManager` into a thinner orchestrator that feeds dependency, hook, and shell observations into that reducer.
- Introduced `HookServerLifecycleState` in `apps/swift/Sources/Capacitor/Models/HookServerManager.swift` so ready/restart/stop transitions are centralized instead of spread across health-check branches.
- Added direct lifecycle transition coverage in:
  - `apps/swift/Tests/CapacitorTests/SetupRequirementsManagerTests.swift`
  - `apps/swift/Tests/CapacitorTests/HookServerManagerTests.swift`
- Recorded Decision 28 and closed `a3-3` in `SLICES.yaml` and `MAP.csv`.

### Now True
- Setup onboarding transitions for initialization, checks, hook install, and shell instructions are explicit and directly testable.
- Hook-server lifecycle transitions for startup health, failure-threshold restart, and stop dominance are explicit and directly testable.
- Verification passed:
  - `swift test --filter 'Setup|HookServer'`
  - `bash .claude/migration/guard.sh --status`

### Remains
- Phase 3 simplification slices still open:
  - `a3-4` to `a3-5`
- Known full-suite Swift failures remain outside this slice in `SessionStateManagerTests` (tracked for `t4-1`).

### Exact Next Steps
1. Start `a3-4` in `.claude/migration/SLICES.yaml`.
2. Identify the highest-churn feature-specific branching still living in `AppState.swift`.
3. Extract those in-development feature flows behind explicit feature/module boundaries without removing the features.
4. Re-run `swift test` selectively around the touched feature surfaces plus `bash .claude/migration/guard.sh --status`.

## Handoff — 2026-03-05
### Changed
- Completed `a3-4` by introducing `apps/swift/Sources/Capacitor/Features/ProjectFeatureCoordinator.swift`.
- Moved project-facing feature-policy branching for project detail navigation, idea capture, idea polling/mutation, description generation, and idea-driven project creation behind that coordinator.
- Reduced `apps/swift/Sources/Capacitor/Models/AppState.swift` to thin delegating shims that inject feature flags, UI-state sinks, and service callbacks into the coordinator.
- Added focused coordinator regression coverage in `apps/swift/Tests/CapacitorTests/ProjectFeatureCoordinatorTests.swift`.
- Recorded Decision 29 and closed `a3-4` in `SLICES.yaml` and `MAP.csv`.

### Now True
- `AppState` no longer owns the bulk of project-facing feature-policy branching for in-development idea/project flows.
- `ProjectFeatureCoordinator` is the explicit boundary for deciding whether feature-gated project views/actions are available and where those calls route.
- Focused verification passed:
  - `swift test --filter 'ProjectFeature|AppState'`
  - `bash .claude/migration/guard.sh --status`

### Remains
- Phase 3 simplification slice still open:
  - `a3-5`
- Known full-suite Swift failures remain outside this slice in `SessionStateManagerTests` (tracked for `t4-1`).

### Exact Next Steps
1. Start `a3-5` in `.claude/migration/SLICES.yaml`.
2. Inventory the current debug/tuning surfaces that still leak into production-facing view/runtime paths.
3. Extract those surfaces behind an explicit debug-only boundary under `apps/swift/Sources/Capacitor/Debug/`, deleting any implicit production coupling in the same slice.
4. Re-run focused Swift coverage for the touched debug/view seams plus `bash .claude/migration/guard.sh --status`.

## Handoff — 2026-03-05
### Changed
- Completed `a3-5` by moving `GlassConfig` from `apps/swift/Sources/Capacitor/Views/Debug/UITuningPanel/GlassConfig.swift` to `apps/swift/Sources/Capacitor/Theme/GlassConfig.swift` without changing the shared live observable instance.
- Added explicit debug wrappers in `apps/swift/Sources/Capacitor/Debug/`:
  - `AppDebugSupport.swift`
  - `ProjectListDiagnosticsSection.swift`
  - `SetupDebugScenarioPicker.swift`
- Reduced direct debug ownership in:
  - `apps/swift/Sources/Capacitor/App.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
  - `apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift`
- Extended `.claude/migration/guard.sh` with denylist checks that keep concrete debug windows/cards and the old debug-owned `GlassConfig.swift` path out of production files.
- Recorded Decision 30 and closed `a3-5` in `SLICES.yaml` and `MAP.csv`.

### Now True
- The UI tuning panel still updates production visuals live because it continues to mutate the same shared `GlassConfig.shared` instance now owned from a production theme path.
- Production app/view files no longer directly own the concrete debug menu/window wiring, project diagnostics cards, or setup preview scenario picker logic.
- Focused verification passed:
  - `swift test --filter 'SetupPreviewScenario|SetupRequirementsManager|AppState|ProjectFeature'`
  - `bash .claude/migration/guard.sh --status`

### Remains
- Phase 3 architectural simplification is now complete.
- Known full-suite Swift failures remain outside this phase in `SessionStateManagerTests` (tracked for `t4-1`).

### Exact Next Steps
1. Start `t4-1` in `.claude/migration/SLICES.yaml`.
2. Replace fixed-date staleness assertions with an injectable clock in `SessionStaleness.swift` and thread that clock through `SessionStateManager`.
3. Prove the three currently failing `SessionStateManagerTests` with deterministic time control before touching broader regression coverage.
4. Re-run the focused session-state tests plus `bash .claude/migration/guard.sh --status`.

## Handoff — 2026-03-05
### Changed
- Completed `t4-1` by introducing `SessionClock` in `apps/swift/Sources/Capacitor/Utilities/SessionStaleness.swift`.
- Threaded merge-time clock resolution through `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` so working-staleness normalization no longer depends on ambient wall clock during tests.
- Reworked `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift` to use deterministic fixture-time helpers instead of fixed `2026-02-28` literals, and corrected the held-active expectation that had been masked by stale working-to-ready conversion.
- Tightened `.claude/migration/guard.sh` by dropping the `Session tests fixed 2026 dates` ratchet from `4` to `0`.
- Recorded Decision 31 and closed `t4-1` in `SLICES.yaml` and `MAP.csv`.

### Now True
- The previously failing `SessionStateManagerTests` cluster is deterministic and passing.
- Full Swift package verification now passes:
  - `swift test`
- The fixed-date ratchet for `SessionStateManagerTests` is now `0/0`.
- Migration guard passes cleanly:
  - `bash .claude/migration/guard.sh --status`

### Remains
- `t4-2` is now the next reliability slice: add missing regression tests for the audited edge cases across Swift, Rust, and hook layers.

### Exact Next Steps
1. Start `t4-2` in `.claude/migration/SLICES.yaml`.
2. Translate the remaining audit findings into missing regression cases, prioritizing the highest-severity uncovered behaviors first.
3. Add tests before code only where a gap still exists; do not reopen slices already closed by behavior coverage.
4. Re-run targeted suites plus `bash .claude/migration/guard.sh --status` after each added regression cluster.

## Handoff — 2026-03-05
### Changed
- Advanced `t4-2` without closing it.
- Added Swift regression coverage in:
  - `apps/swift/Tests/CapacitorTests/ProjectCreationCoordinatorTests.swift`
  - `apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift`
- Hardened Swift behavior in:
  - `apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift`
  - `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`
- Added Rust/core regression coverage and fixes in:
  - `core/capacitor-core/src/runtime_validation.rs`
  - `core/capacitor-core/src/runtime_setup.rs`
  - `core/capacitor-core/src/runtime_projects.rs`
- Added hook end-to-end regression coverage in:
  - `core/hud-hook/tests/serve_integration.rs`
- Recorded Decisions 32 and 33 and updated the `t4-2` ledger entries in `SLICES.yaml` and `MAP.csv`.

### Now True
- New-project session attribution is deterministic: when multiple new Claude session files appear, the newest file wins with a stable filename tiebreak.
- Cargo metadata extraction no longer leaks across TOML sections; `[dependencies] name = ...` cannot override `[package].name`.
- Direct-match session arbitration no longer lets stale-working metadata beat a newer ready session.
- Hook-server request-path behavior is covered end-to-end for:
  - missing `cwd` skip on non-delete events
  - missing `cwd` delete on `SessionEnd`
  - valid chunked bodies without `Content-Length`
- `verify_hook_binary()` is covered on the actual `--help` shape-check branch in both positive and negative directions.
- Project ordering and `last_active` are explicitly guarded against `agent-*.jsonl` transcripts.
- Verification passed:
  - `swift test`
  - `cargo test -p capacitor-core -p hud-hook`
  - `bash .claude/migration/guard.sh --status`

### Remains
- `t4-2` is still open.
- Highest-confidence uncovered audit gaps still remaining:
  - Swift: repeated runtime snapshot/fetch failures do not degrade or clear stale UI activity in `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - Rust/core: no public contract test yet proves `check_hook_health()` grace semantics end-to-end at the production API boundary

### Exact Next Steps
1. Keep `t4-2` as `in_progress` in `.claude/migration/SLICES.yaml`.
2. Add a failing Swift regression around repeated runtime refresh failures leaving stale activity pinned, then implement explicit degradation/clear semantics.
3. Add a Rust/core contract test around `check_hook_health()` using persisted snapshot + heartbeat fixtures to prove stale ready/dead sessions do not extend grace while recent active sessions do.
4. Re-run `swift test`, `cargo test -p capacitor-core -p hud-hook`, and `bash .claude/migration/guard.sh --status`.

## Handoff — 2026-03-05
### Changed
- Completed `t4-2`.
- Added AppState runtime failure hysteresis coverage and behavior in:
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift`
  - `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`
  - `apps/swift/Tests/CapacitorTests/AppStateSessionObservationTests.swift`
- Added public `check_hook_health()` grace contract coverage in:
  - `core/capacitor-core/src/lib.rs`
- Recorded Decision 34 and closed `t4-2` in `SLICES.yaml` and `MAP.csv`.

### Now True
- All previously selected audited edge cases for `t4-2` are covered by regression tests.
- Runtime-derived session/shell UI state now survives one fresh snapshot failure and clears on the second consecutive fresh failure, resetting after any successful fresh snapshot.
- Runtime bootstrap cancellation is now meaningful, which makes the AppState test harness deterministic.
- Public hook-health grace semantics are covered end-to-end at `CoreRuntime.check_hook_health()`.
- Verification passed:
  - `swift test` (`274` tests)
  - `cargo test -p capacitor-core -p hud-hook`
  - `bash .claude/migration/guard.sh --status`

### Remains
- `t4-2` is complete.
- Next slice is `t4-3`: align docs/comments with the post-migration ownership and behavior.

### Exact Next Steps
1. Start `t4-3` in `.claude/migration/SLICES.yaml`.
2. Update stale architectural docs/comments, especially any file headers that still claim Swift state logic is only a passthrough to Rust.
3. Reconcile `CLAUDE.md`/migration docs with the new ownership boundaries and regression-shielded behavior.
4. Re-run targeted docs consistency review plus `bash .claude/migration/guard.sh --status`.

## Handoff — 2026-03-05
### Changed
- Completed `t4-3` and `t4-4`, closing the remaining migration slices.
- Updated ownership docs and comments in:
  - `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`
  - `CLAUDE.md`
  - `README.md`
  - `CONTRIBUTING.md`
  - `docs/ARCHITECTURE.md`
  - `docs/SESSION_STATE_RELEASE_MATRIX.md`
  - `docs/PRE_RELEASE_CHECKLIST.md`
  - `docs/architecture-decisions/003-sidecar-architecture-pattern.md`
- Added the operational reliability wrapper:
  - `scripts/ci/runtime-reliability.sh`
- Wired operational verification into:
  - `.github/workflows/ci.yml`
  - `.github/workflows/hem-shadow-nightly.yml`
- Extended `.claude/migration/guard.sh` to enforce the runtime-reliability wiring and nightly schedule trigger.
- Recorded Decision 35 and closed the remaining ledger rows in `SLICES.yaml` and `MAP.csv`.

### Now True
- All migration slices in `.claude/migration/SLICES.yaml` are `done`.
- Top-level architecture guidance now matches the implemented ownership model:
  - Rust owns ingest/reduce/query truth and persisted runtime state.
  - Swift owns projection, hysteresis, lifecycle orchestration, and feature/debug coordinators.
- Session-state reliability has one operational entrypoint:
  - pre-merge: `bash scripts/ci/runtime-reliability.sh ci`
  - nightly: `CAPACITOR_BENCH_DRY_RUN_ONLY=1 bash scripts/ci/runtime-reliability.sh nightly <report-path>` for dry-run validation, or without the env override for the real soak benchmark
- Guard ratchets now fail if CI/nightly stop calling the wrapper, if the wrapper stops invoking the migration guard/replay gate/soak bench, or if the nightly workflow loses its schedule trigger.
- Verification passed:
  - `swift test`
  - `cargo test -p capacitor-core -p hud-hook`
  - `bash .claude/migration/guard.sh --status`
  - `bash scripts/ci/runtime-reliability.sh ci`
  - `CAPACITOR_BENCH_DRY_RUN_ONLY=1 bash scripts/ci/runtime-reliability.sh nightly /tmp/capacitor-runtime-reliability-nightly-dry-run.json`

### Remains
- No open migration slices remain in `.claude/migration/SLICES.yaml`.
- Residual non-blocking note: `cargo test` still emits a dead-code warning for `ActivationAction::Skip` in the test-only Rust activation module. This did not fail verification and is outside the closed migration slices.

### Exact Next Steps
1. Treat the migration program as closed; future changes should start a new slice only if they introduce new architectural or reliability work.
2. If desired, clean up the remaining `ActivationAction::Skip` dead-code warning in a separate small slice or routine maintenance change.

## Handoff — 2026-03-05
### Changed
- Performed a post-migration production-readiness sweep focused on dead code and warning-only drift.
- Removed the dead `ActivationAction::Skip` variant from `core/capacitor-core/src/runtime_activation/mod.rs`.
- Replaced the clippy-disallowed `get(...).is_none()` test shape in `core/capacitor-core/src/reduce/mod.rs`.
- Made ignored hook-server lifecycle transitions explicit in `apps/swift/Sources/Capacitor/Models/HookServerManager.swift`, eliminating release-build Swift warnings.
- Moved `core/capacitor-core/tests/common.rs` to `core/capacitor-core/tests/common/mod.rs` so Cargo no longer builds an empty standalone `common` integration-test target by default.
- Marked the `uniffi-bindgen` binary target as `test = false` in `core/capacitor-core/Cargo.toml`.
- Updated `scripts/release/verify-app-bundle.sh` so the verifier accepts either `Assets.car` or the raw `Assets.xcassets` resource-catalog layout produced by the current SwiftPM bundle.

### Now True
- `cargo clippy --all-targets --all-features -- -D warnings` passes cleanly.
- `cargo machete` reports no unused Rust dependencies.
- Full Rust and Swift test suites still pass after the cleanup.
- The pre-merge runtime reliability gate still passes on the cleaned tree.
- `bash scripts/release/build-distribution.sh --skip-notarization` is warning-clean.
- `bash scripts/release/verify-app-bundle.sh` now finishes with `All checks passed! Safe to release.`

### Remains
- No confirmed dead code was found beyond the removed `ActivationAction::Skip` variant during this sweep.
- No new migration slice was opened; this was a post-close hardening pass on the completed migration state.

### Exact Next Steps
1. If you want even higher confidence, the next leverage move is an external review pass or manual release checklist execution, not more local refactoring.
