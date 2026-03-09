# CAPACITOR_CORE_SNAPSHOT Usage Audit

Date: 2026-03-09  
Scope: Runtime artifact path selection, runtime health/diagnostics, observability tooling, tests, and adjacent architecture docs

## System Decomposition

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Runtime service persistence bootstrap | `core/hud-hook/src/serve.rs`, `core/capacitor-core/src/lib.rs`, `core/capacitor-core/src/storage/mod.rs` | FS read/write, runtime initialization | High |
| 2 | Hook health and diagnostic side-channel | `core/capacitor-core/src/runtime_state/snapshot.rs`, `core/capacitor-core/src/lib.rs`, `apps/swift/Sources/Capacitor/Models/AppState.swift` | FS read, UI-visible diagnostics | High |
| 3 | Agent/dev observability tooling | `scripts/dev/agent-observe.sh`, `scripts/transparent-ui-server.mjs`, `scripts/ci/test-agent-observe.sh` | FS read, HTTP server, agent debugging surface | High |
| 4 | Test harnesses and fixture isolation | `core/hud-hook/tests/common/mod.rs`, `core/capacitor-core/tests/ffi_contract.rs` | Process env, temp FS state | Medium |
| 5 | User/developer-facing architecture docs | `README.md`, `CLAUDE.md`, ADR-003/ADR-004 references | Context-setting, operational guidance | Medium |

## Executive Conclusion

`CAPACITOR_CORE_SNAPSHOT` should **not** be excised wholesale yet.

It still has one legitimate responsibility:

1. Selecting the persisted runtime artifact path for the local runtime service process and its isolated test harnesses.

But it is currently overloaded with responsibilities that no longer fit the dedicated runtime-service architecture:

1. Live hook health and hook diagnostics still bypass the runtime service and read the snapshot file directly.
2. Canonical observability tooling still treats the snapshot file as the primary runtime boundary.
3. User/developer docs still teach the snapshot architecture as the current system.

The right cleanup is:

1. **Keep** a storage-path override for the service process and tests.
2. **Remove or replace** all app-facing and tooling-facing direct reads that use `CAPACITOR_CORE_SNAPSHOT` as a live runtime boundary.
3. **Rename** the remaining override to reflect what it actually is: a runtime artifact path, not the application boundary.

## Findings

### [Hook Diagnostics] Finding 1: Live hook health still bypasses the runtime service

**Severity:** High  
**Type:** Design flaw  
**Location:** [core/capacitor-core/src/runtime_state/snapshot.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs):80-145, [core/capacitor-core/src/lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs):786-930, [apps/swift/Sources/Capacitor/Models/AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift):624-707

**Problem:**  
Capacitor’s hook diagnostic and hook test paths still compute runtime liveness by reading the snapshot file through `CAPACITOR_CORE_SNAPSHOT`, not by querying the authenticated runtime service. That means the app’s setup/repair UI is still coupled to a direct file side-channel even though RW-111/RW-112 established the runtime service as the application boundary.

**Evidence:**  
- `sessions_snapshot()` and `runtime_health()` load `AppSnapshot` directly from `CAPACITOR_CORE_SNAPSHOT` or `~/.capacitor/runtime/app_snapshot.json` in [runtime_state/snapshot.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs):80-145.  
- `check_hook_health()` uses `runtime_state::snapshot::sessions_snapshot()` to extend heartbeat grace in [lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs):797-801.  
- `run_hook_test()` uses `test_state_file_io()` which resolves to `runtime_state::snapshot::runtime_health()` in [lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs):911-930.  
- Swift surfaces those results through `engine.getHookDiagnostic()` and `engine.runHookTest()` in [AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift):624-653.

**Recommendation:**  
Move hook-health and hook-diagnostic reads onto the runtime service. If hook health needs access to persisted runtime state, inject that through the runtime service or a storage abstraction owned by the service, not through an env-var-driven file lookup inside app-facing diagnostics.

### [Observability] Finding 2: Canonical agent tooling still treats the snapshot file as the runtime boundary

**Severity:** High  
**Type:** Stale docs / design flaw  
**Location:** [scripts/dev/agent-observe.sh](/Users/petepetrash/Code/capacitor/scripts/dev/agent-observe.sh):6-23,61-170, [scripts/transparent-ui-server.mjs](/Users/petepetrash/Code/capacitor/scripts/transparent-ui-server.mjs):7-190, [README.md](/Users/petepetrash/Code/capacitor/README.md):48-60, [CLAUDE.md](/Users/petepetrash/Code/capacitor/CLAUDE.md):42-90

**Problem:**  
The repo’s primary debugging tools and docs still frame the runtime snapshot file as the live source of truth. That is context poison now that the runtime service is the application boundary. Agents and humans using these tools will reason about a stale artifact path instead of the live authenticated service.

**Evidence:**  
- `agent-observe.sh` describes itself as “direct-core mode” and derives `health` from snapshot presence/parseability in [agent-observe.sh](/Users/petepetrash/Code/capacitor/scripts/dev/agent-observe.sh):17-23 and 160-169.  
- `transparent-ui-server.mjs` reads `CAPACITOR_CORE_SNAPSHOT` directly and synthesizes a fake health block instead of querying `/health` in [transparent-ui-server.mjs](/Users/petepetrash/Code/capacitor/scripts/transparent-ui-server.mjs):7-10 and 145-183.  
- `README.md` still says “Hook events are written directly into the Rust runtime snapshot” in [README.md](/Users/petepetrash/Code/capacitor/README.md):52.  
- `CLAUDE.md` still teaches “Runtime Snapshot Architecture” and “Hooks → hud-hook → capacitor-core snapshot → Swift reads runtime snapshot” in [CLAUDE.md](/Users/petepetrash/Code/capacitor/CLAUDE.md):42-68.

**Recommendation:**  
Update observability tools to query the runtime service first:

1. `/health` for runtime health
2. `/runtime/snapshot` for live state

Keep direct snapshot-file reads only as explicit artifact-debug or fixture paths. Update README/CLAUDE to describe the service boundary as current reality.

### [Configuration] Finding 3: `CAPACITOR_CORE_SNAPSHOT` now means “artifact path,” but its name still encodes the old architecture

**Severity:** Medium  
**Type:** Stale naming / design drift  
**Location:** [core/hud-hook/src/serve.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/serve.rs):19-33, [core/capacitor-core/src/runtime_state/snapshot.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs):11-145, [scripts/dev/agent-observe.sh](/Users/petepetrash/Code/capacitor/scripts/dev/agent-observe.sh):4-11

**Problem:**  
The env var’s current surviving production responsibility is just “choose where the runtime artifact file lives.” But the name still encodes the pre-service mental model: a “core snapshot” as the runtime boundary. That mismatch encourages new call sites to use it as a general runtime selector or debugging surface.

**Evidence:**  
- The live service process uses the env only to choose the storage path passed to `CoreRuntime::new_with_snapshot_file(...)` in [serve.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/serve.rs):29-33.  
- `runtime_state/snapshot.rs` uses the same env for its side-channel reads in [runtime_state/snapshot.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs):120-145.  
- Tooling inherits the old name and defaults in [agent-observe.sh](/Users/petepetrash/Code/capacitor/scripts/dev/agent-observe.sh):4-11.

**Recommendation:**  
Retain the capability short-term, but rename it to reflect its actual role, for example:

1. `CAPACITOR_RUNTIME_SNAPSHOT_PATH`
2. `CAPACITOR_RUNTIME_ARTIFACT_PATH`

Then confine it to service bootstrap, tests, and explicit artifact-debug tooling.

### [Runtime UI] Finding 4: Swift runtime status still reports snapshot-era messages

**Severity:** Medium  
**Type:** Stale docs / UX correctness  
**Location:** [apps/swift/Sources/Capacitor/Models/AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift):658-710

**Problem:**  
Even after the service cutover, the visible runtime status still tells users they are in “Core runtime snapshot mode” and that “Core runtime snapshot” is unavailable. That is now false architecture documentation in the product itself.

**Evidence:**  
- `ensureRuntimeReady()` comment still says “runtime state is sourced from the core snapshot file” in [AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift):658-662.  
- `checkRuntimeHealth()` sets UI messages to `Core runtime snapshot mode` and `Core runtime snapshot unavailable` in [AppState.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift):686-707.

**Recommendation:**  
Update these strings and comments to service terminology immediately. Even if the persisted artifact remains a snapshot file, the user-facing runtime boundary is the local runtime service.

### [Tests] Finding 5: Test-only storage overrides are still legitimate and should not be deleted blindly

**Severity:** Low  
**Type:** Test harness dependency  
**Location:** [core/hud-hook/tests/common/mod.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/tests/common/mod.rs):33-58, [core/capacitor-core/tests/ffi_contract.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/tests/ffi_contract.rs):77-93

**Problem:**  
`CAPACITOR_CORE_SNAPSHOT` is still used by test harnesses to isolate runtime artifacts per temp directory. This is not dead code; it is the current mechanism keeping tests hermetic.

**Evidence:**  
- `ServerGuard::spawn(...)` and `spawn_service_bootstrap(...)` inject `CAPACITOR_CORE_SNAPSHOT` for isolated temp snapshots in [core/hud-hook/tests/common/mod.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/tests/common/mod.rs):33-58.  
- `CoreRuntime::new_with_snapshot_file(...)` is exercised directly in [core/capacitor-core/tests/ffi_contract.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/tests/ffi_contract.rs):77-93.

**Recommendation:**  
Do not remove test-time storage overrides until there is a replacement mechanism for isolated runtime artifact paths. If the env var is renamed, update tests in the same change.

## Recommendation Order

1. Replace the hook-diagnostic side-channel (`runtime_state::snapshot.rs` usage in `check_hook_health` / `run_hook_test`) with a runtime-service-aware read path.
2. Update `agent-observe.sh` and `transparent-ui-server.mjs` to query the runtime service first, keeping file reads as explicit artifact-debug fallback only.
3. Update user/developer-facing docs and in-app runtime-status wording to stop teaching the snapshot architecture.
4. Rename `CAPACITOR_CORE_SNAPSHOT` to a storage-path-oriented name once the side-channel reads are removed.
5. Keep test-only artifact-path overrides until a cleaner fixture mechanism exists.

## Bottom Line

`CAPACITOR_CORE_SNAPSHOT` is **not dead**, but its current footprint is too broad for the dedicated runtime-service architecture.

- **Keep:** service-process artifact path override and test isolation
- **Excise/update:** live diagnostics, observability tooling, and stale architecture messaging that still treat the snapshot file as the runtime boundary
