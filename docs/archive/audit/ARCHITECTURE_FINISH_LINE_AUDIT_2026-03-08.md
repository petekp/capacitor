# Architecture Finish-Line Audit

Historical note: this document records the narrower Rust/FFI finish-line campaign that closed on March 8, 2026. The current Swift convergence standard is tracked in [ARCHITECTURE_CONVERGENCE_AUDIT_2026-03-08.md](/Users/petepetrash/Code/capacitor/docs/audit/ARCHITECTURE_CONVERGENCE_AUDIT_2026-03-08.md).

Date: 2026-03-08

This audit started the follow-on campaign required to reach the actual finish line after the Swift shell migration closed on March 7, 2026. It now tracks the remaining finish-line position after `RW-107` through `RW-110`.

The important distinction is scope:

- the Swift shell migration is complete
- the overall architecture direction is unchanged
- the remaining finish-line work is concentrated in Rust and the UniFFI boundary

## Mission

Finish the bounded-context architecture by eliminating the remaining parallel ownership inside `capacitor-core`, slimming the UniFFI boundary to shell-native contracts, and deleting transitional bridges that only exist because Rust and Swift still meet on partially legacy DTOs.

## What Is Already True

High-confidence completed work:

- daemon IPC is gone as the primary runtime path
- `capacitor-hook` ingests directly into `capacitor-core`
- `hud-core` is deleted
- Swift is on the outer-shell architecture and no longer competes with the Rust core for application policy
- replay-diff, FFI contract coverage, architecture guards, and architecture ratchets are already in place

This matters because the finish-line campaign is not a rescue. It is a convergence campaign.

## Inventory and Leverage

### High leverage

- `core/capacitor-core/src/lib.rs`
  Why: still the broad public UniFFI façade; most finish-line deletion or convergence flows through here
- `core/capacitor-core/src/contexts/composition.rs`
  Why: intended canonical composition root for bounded contexts
- `core/capacitor-core/src/contexts/*/application.rs`
  Why: these files define whether each bounded context becomes a real canonical path or remains dead scaffold
- `core/capacitor-core/tests/ffi_contract.rs`
  Why: best place to lock boundary behavior while the DTO cutover happens
- `core/capacitor-core/tests/replay_diff.rs`
  Why: strongest regression oracle for keeping Rust semantics stable through core convergence

### Medium leverage

- `core/capacitor-core/src/runtime_setup.rs`
- `core/capacitor-core/src/runtime_storage.rs`
- `core/capacitor-core/src/runtime_projects.rs`
- `core/capacitor-core/src/runtime_ideas.rs`
  Why: these are still valuable implementation modules, but they should sit behind clear ownership instead of being called directly from the broad FFI façade forever

### Low leverage / deletion candidates

- scaffold-only `todo!("Shell scaffold only")` application methods under `core/capacitor-core/src/clean`
- Swift-side [ProjectCatalogBridge.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Adapters/CoreBridge/ProjectCatalogBridge.swift) once the upstream DTO boundary becomes shell-native
- any direct `CoreRuntime` helper/bypass path in `lib.rs` that survives after the corresponding bounded context is made real

## Measured Remaining Seam

Measured on March 8, 2026.

| Pattern | Current count | Why it matters | Ratchet |
| --- | ---: | --- | --- |
| `todo!("Shell scaffold only")` in `core/capacitor-core/src/contexts/*/application.rs` | 2 | only feedback bounded-context scaffold remains | freeze at `<= 2` now; drive to `0` |
| `runtime_ideas::` call sites in `core/capacitor-core/src/lib.rs` | 0 | idea behavior no longer bypasses the bounded-context service layer | keep at `0` |
| direct project/config helper calls in `core/capacitor-core/src/lib.rs` (`load_hud_config_with_storage`, `save_hud_config_with_storage`, `load_projects_with_storage`, `runtime_projects::try_resolve_encoded_path`, `validate_project_path`, `create_claude_md`) | 0 | project/catalog behavior no longer bypasses the bounded-context service layer | keep at `0` |
| `setup_checker(` call sites in `core/capacitor-core/src/lib.rs` | 0 | setup mutation no longer bypasses the bounded-context service layer | keep at `0` |
| `ProjectCatalogBridge` hits in Swift production sources | 0 | the temporary Swift anti-corruption seam is deleted | keep at `0` |

Residual design debt that is real but not yet ratcheted numerically:

- `CoreRuntime::new()` in `core/capacitor-core/src/lib.rs` still creates an in-memory runtime, which keeps production-truth semantics blurrier than they should be
- production activation remains Swift-owned, so the remaining finish-line work is now FFI DTO cutover plus dead-code cleanup rather than another Rust bounded-context convergence slice

## Intentional Bridges To Keep For Now

These are not blockers to the finish-line campaign unless we explicitly choose a breaking-change compatibility sweep:

- legacy hook config migration in `core/capacitor-core/src/runtime_setup.rs`
- legacy path/storage fallback in `core/capacitor-core/src/runtime_storage.rs`
- `CapacitorConfig.legacyURL` in Swift config migration
- `ProjectOrdering` defaults-key migration

## Hard Conclusions

1. The remaining architecture debt is not “Swift still owns policy.” That part is already solved.
2. The main unfinished problem is parallel ownership inside the Rust core: `CoreRuntime` still exposes direct helper paths while the `contexts/*` bounded-context shell exists beside it.
3. The finish line requires a hard choice per bounded context: route production behavior through the contexts service layer, or delete the scaffold. Parallel ownership is not an acceptable steady state.
4. The highest-value deletion lever is the project/catalog boundary, because that is what ultimately removes Swift’s `ProjectCatalogBridge`.
5. Compatibility bridges in `runtime_setup`, `runtime_storage`, and config migration are not finish-line blockers by themselves. They only become targets if we choose a separate breaking-change compatibility purge.

## Proposed Finish-Line Slices

### RW-106: Rust Finish-Line Audit + Boundary Freeze

Outcome:

- capture the measured Rust/FFI residual seam
- define the remaining slices explicitly
- add guard ratchets so the seam can only shrink

### RW-107: Rust Projects Boundary Convergence

Status: completed.

Outcome:

- direct project/config helper count in `lib.rs` is now `0`
- `contexts/projects/application.rs` no longer contains scaffold todos
- `CoreRuntime` routes project catalog, suggestion, add/remove, validation, and CLAUDE.md bootstrap through the projects bounded context path

### RW-108: Rust Ideas Boundary Convergence

Status: completed.

Outcome:

- direct `runtime_ideas::` count in `lib.rs` is now `0`
- `contexts/ideas/application.rs` no longer contains scaffold todos
- the canonical markdown helper bug around description replacement was fixed while converging the path

### RW-109: Rust Setup Boundary Convergence

Status: completed.

Outcome:

- direct `setup_checker(` count in `lib.rs` is now `0`
- `contexts/setup/application.rs` no longer contains scaffold todos
- setup mutation is converged on the setup bounded context service without deleting intentional runtime_setup compatibility semantics

### RW-110: Rust Activation Boundary Convergence

Status: completed.

Outcome:

- production activation ownership is explicitly Swift-owned
- the dormant Rust activation bounded context shell is deleted
- the test-only `runtime_activation` planner is deleted
- the finish-line campaign is narrowed to real production convergence instead of preserving non-production activation ideas

### RW-111: FFI DTO Cutover + Swift Bridge Deletion

Status: completed.

Outcome:

- Rust exports shell-native project/catalog DTOs directly through UniFFI
- `DashboardData.projects` is now shell-native at the boundary
- `getSuggestedProjects()` returns shell-native suggestion DTOs directly
- Swift deletes `ProjectCatalogBridge` and keeps only thin convenience/extensions around the generated shell-native DTOs

### RW-111: FFI DTO Cutover + Swift Bridge Deletion

Goal:

- make the upstream project/catalog DTO boundary shell-native so Swift can delete `ProjectCatalogBridge`

Primary targets:

- `core/capacitor-core/src/lib.rs`
- UniFFI-exposed project/catalog DTOs
- `apps/swift/Sources/Capacitor/Adapters/CoreBridge/ProjectCatalogBridge.swift`
- `apps/swift/Sources/Capacitor/Adapters/CoreBridge/LiveProjectCatalogGateway.swift`
- `apps/swift/Sources/Capacitor/Application/Projects/DashboardLoader.swift`

Acceptance:

- `ProjectCatalogBridge` is deleted
- Swift consumes shell-native project/catalog DTOs directly from the FFI boundary

### RW-112: Finish-Line Dead Code Sweep + Final Checkpoint

Goal:

- remove any scaffold, wrapper, docs, bindings, or helper paths made dead by RW-107 through RW-111
- write the final architecture checkpoint

Acceptance:

- no scaffold-only contexts application service remains
- no deleted-boundary names are reintroduced
- docs describe one canonical architecture, not a transition

## Translation Guide

This maps old finish-line patterns to their target ownership.

| Current pattern | Target pattern |
| --- | --- |
| `CoreRuntime` method body directly calling `runtime_ideas::*` | `CoreRuntime` delegates to `contexts/ideas` service or the unused scaffold is deleted |
| `CoreRuntime` method body directly calling `load_hud_config_with_storage` / `save_hud_config_with_storage` / `load_projects_with_storage` | `CoreRuntime` delegates to `contexts/projects` service |
| `CoreRuntime` method body directly calling `SetupChecker` mutators | `CoreRuntime` delegates to `contexts/setup` service |
| Swift using `ProjectCatalogBridge` to reshape legacy project DTOs | Rust exports shell-native DTOs so Swift deletes the bridge |
| bounded-context `application.rs` with `todo!("Shell scaffold only")` | bounded-context service owns production behavior, or the dead scaffold is deleted |

## Immediate Next Step

Next highest-leverage slice is none.

At this point the finish-line campaign is down to:

1. no pending slices remain in the current campaign
