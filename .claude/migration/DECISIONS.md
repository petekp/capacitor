# Migration Decisions

## Decision 1: Keep `handle.rs` event processing, remove only stdin entry point

The `handle::run()` function reads JSON from stdin — that's the deprecated path. But `handle_hook_input()` and everything below it is shared between both paths. We keep the shared code, delete only the stdin reader (`run()`) and the `Handle` subcommand.

**Rationale:** The HTTP server in `serve.rs` already calls `handle::handle_hook_input()` directly. The stdin path is the only consumer of `handle::run()`.

## Decision 2: Merge `register_hooks_in_settings` into `register_http_hooks_in_settings`

Today there are two registration functions: one writes `type: "command"` hooks, the other writes `type: "http"` hooks. After migration, only HTTP registration is needed. The command registration function and its caller (`install_hooks`) become dead code.

**Rationale:** Single code path reduces maintenance burden and eliminates the risk of accidentally installing command hooks.

## Decision 3: Keep `HookInstaller.swift` but rewire to HTTP path

`HookInstaller.ensureHooksInstalled()` currently calls `engine.installHooks()` (command path). After migration, it should call `engine.installHttpHooks(port:)`. The binary install step remains necessary — the `hud-hook serve` binary still needs to exist at `~/.local/bin/hud-hook`.

**Rationale:** The binary is still needed for the HTTP server; only the hook registration type changes.

## Decision 4: Keep legacy detection functions for `remove_hooks` backward compat

Functions like `is_managed_hook_command()`, `is_hud_hook_command()`, and `LEGACY_STATE_TRACKER_MARKER` are used by `remove_hooks()` to clean up any hook format. These should be retained so the app can clean up old installations.

**Rationale:** Users upgrading from command hooks need the removal logic to recognize and clean up old entries.

## Decision 5: Remove `HUD_SUMMARY_GEN` stdin drain from `handle::run()`

The `HUD_SUMMARY_GEN` check in `handle::run()` is a stdin-specific workaround. When we remove the stdin path, this goes too. The HTTP server never encounters this scenario since it reads from request bodies, not inherited stdin.

**Rationale:** Dead code after stdin removal. The HTTP path can't trigger this condition.

## Decision 6: Retain test fixtures with command hook data

Tests in `runtime_setup.rs` use `"hud-hook handle"` and `"command"` hook types in their fixture data. These are *not* vestigial — they exercise the upgrade (`normalize_hud_hook_config`) and removal (`remove_hooks`) backward-compat paths defined in Decision 4. The remaining 14 `hud-hook handle` references and 1 `"command".to_string()` are all test-scoped.

**Rationale:** Removing these tests would leave the upgrade/removal code untested. The test data must match real-world legacy formats to be useful.

## Decision 7: Exclude `.worktrees/` from guard script scanning

The guard script was incorrectly counting references in stale git worktrees (e.g., `.worktrees/terminal-abstraction/`), inflating budgets. Added `.worktrees/` to the exclusion list alongside `target/` and `.claude/migration/`.

**Rationale:** Worktrees contain snapshots of older code and shouldn't affect ratchet budgets.

## Decision 8: Expand migration scope from hook-only to holistic Rust+Swift reliability program

The migration control plane now governs end-to-end reliability and simplification across Rust core and Swift client, not only HTTP hook transport migration.

**Rationale:** Both audits identified high-severity issues outside hook transport. Continuing with a hook-only charter would leave the highest-risk defects unmanaged by slices, ratchets, and evidence gates.

## Decision 9: Feature-preserving simplification policy

We will simplify architecture and implementation complexity without removing in-development feature surfaces (ideas, project creation, workstreams, debug tooling), unless a future explicit decision supersedes this one.

**Rationale:** Product direction requires retaining capability surface. Complexity reduction should come from clearer ownership boundaries and module isolation, not feature cuts.

## Decision 10: Control-plane-first phase-0 ratification is mandatory before new implementation slices

Before Phase 1 bug-fix slices, we must keep `CHARTER.md`, `SLICES.yaml`, `MAP.csv`, and `guard.sh` aligned to the holistic plan baseline.

**Rationale:** Stale control-plane artifacts are a primary source of agent drift and contradictory execution state.

## Decision 11: Add holistic reliability ratchets calibrated to 2026-03-05 baseline

In addition to legacy hook ratchets, the guard script now tracks baseline counts for known reliability anti-patterns (setup fatal crash path, unsupported verification arg, blocking waits on hot paths, terminal output race marker, drag-drop ordering marker, fixed-date brittle tests).

**Rationale:** Ratchets turn known risks into deterministic debt ceilings and force monotonic improvement slice-by-slice.

## Decision 12: Activation ownership boundary decision deferred to dedicated slice

The activation ownership choice (Swift owner vs Rust owner for planning) is intentionally deferred to slice `a3-2` and must be resolved there with explicit deletion targets for the non-owner path.

**Rationale:** Audit evidence indicates ownership ambiguity, but an immediate decision without migration context would increase risk. A dedicated slice with tests and deletion targets is lower-risk and auditable.

## Decision 13: `resolve_cwd` for hook events is request-scoped only

`HookInput::resolve_cwd` now resolves cwd from request payload `cwd` first, then explicit request-scoped `current_cwd` only. It no longer falls back to ambient process environment variables (`CLAUDE_PROJECT_DIR`, `PWD`).

**Rationale:** In `hud-hook serve` mode, ambient daemon environment can represent launcher state rather than event origin and can misattribute events to the wrong project. Missing cwd should remain a deterministic skip for non-delete events.

## Decision 14: Enforce request body cap by bounded reads, not only declared length

`/hook` request handling keeps the `Content-Length` fast-path check but now also enforces `MAX_BODY_BYTES` during actual body reads. Oversized bodies are rejected with `413` even when length is unknown/chunked.

**Rationale:** Header-based checks are advisory; only bounded reads guarantee protection against unknown-length payloads and chunked transfer bypass.

## Decision 15: Hook binary verification must validate supported CLI surface

`verify_hook_binary` now runs `hud-hook --help`, requires success, and validates that the output exposes required subcommands (`serve` and `cwd`). It no longer treats arbitrary non-137 exits from an unsupported subcommand probe as success.

**Rationale:** Executability alone is insufficient; setup validation must prove the binary can serve the currently supported hook transport/commands.

## Decision 16: Setup runtime initialization failures are recoverable UI state, not process-fatal

`SetupRequirementsManager` no longer crashes on `CoreRuntime` initialization failure. It now stores a blocking initialization error state and surfaces it in onboarding UI.

**Rationale:** Setup failures should degrade to actionable UI and retries, not terminate the app during onboarding.

## Decision 17: Runtime snapshot freshness guard is atomic across session + shell projections

A runtime snapshot is now either fully committed (session + shell projections) or fully dropped when stale. Mixed commit states are disallowed.

**Rationale:** Split-brain projection state creates incorrect UI/system behavior and invalidates the generation guard's purpose.

## Decision 18: Stabilization holds preserve metadata only for held project paths

When display-state stabilization holds a subset of projects, session attribution and preferred-session metadata now fall back only for those held paths. Non-held paths continue to take fresh metadata from the latest runtime merge.

**Rationale:** A local hold should not globally freeze unrelated project metadata.

## Decision 19: `runBashScriptWithResult` is cancellation-aware and timeout-bounded

Terminal subprocess execution now terminates the child process when the parent task is cancelled, synchronizes output aggregation across callbacks, and applies a defensive timeout kill.

**Rationale:** Prevent orphaned shell processes and data races in output capture under cancellation/concurrent callback conditions.

## Decision 20: Drop URL extraction uses deterministic grouped loaders

File-drop ingestion now normalizes providers into loader closures and collects URL results with lock-protected append/snapshot semantics before completion.

**Rationale:** Avoid timing-dependent loss of valid URLs from DispatchGroup callback ordering and queue handoff races.

## Decision 21: Creation monitor tasks are owned by creation lifecycle state

Session-discovery and completion-monitor tasks are now tracked by creation ID inside `AppState`, cancelled whenever a creation enters a terminal state, and ignored if a late callback arrives for a cancelled, failed, or completed creation.

**Rationale:** Creation monitors are advisory observers, not state owners. Terminal lifecycle state must dominate late async callbacks to prevent cancelled work from being resurrected by delayed session detection or file-stability polling.

## Decision 22: Hook server lifecycle is guarded by explicit stop intent and generation

`HookServerManager` now tracks at most one in-flight health check, cancels it on lifecycle transitions, and ignores late callbacks unless their generation still matches the current lifecycle and stop intent remains false. Explicit stop no longer blocks on `waitUntilExit()` and also terminates a validated adopted pid when no owned `Process` handle exists.

**Rationale:** Hook-server health checks are observers, not authorities. Stop intent must dominate late async failure signals, and lifecycle state must not be mutated by callbacks from an obsolete process generation.

## Decision 23: Hook-health grace is based on recent active work, not any non-idle session

Hook-health grace now treats only `working`, `waiting`, or `compacting` sessions as active candidates, requires recent activity within the grace window, and refuses to synthesize `is_alive = true` when loading runtime sessions from the persisted snapshot.

**Rationale:** A stale persisted session should not mask a stale heartbeat just because its last known state was non-idle. Grace is meant to cover currently active work, not historical residue.

## Decision 24: Project recency is derived from latest non-agent session file activity

Pinned project ordering now uses the newest non-agent `.jsonl` session file mtime inside the Claude project directory, which is the same source used for `last_active`. Directory mtimes are no longer treated as the project recency signal.

**Rationale:** Claude appends to existing session files without necessarily mutating the enclosing project directory, so directory mtime can drift from real activity and produce visibly wrong ordering.

## Decision 25: Sensemaking git subprocess execution is owned by a detached loader path

`ProjectDetailsManager` no longer runs recent-files, branch, and last-commit git subprocesses directly on the main actor. It now funnels those commands through one shared git runner invoked from a detached async loader, then merges the resulting context back into main-actor state.

**Rationale:** The sensemaking context fetch is auxiliary work. It should never monopolize the main actor or duplicate subprocess wait logic across three separate call sites.

## Decision 26: Project creation workflow is owned by a dedicated coordinator, not AppState

The project-creation pipeline has been extracted into `ProjectCreationCoordinator`, which now owns creation persistence, prompt/file generation, Claude launch/resume, and session/completion monitor task lifecycle. `AppState` remains the observable facade and composition root, exposing thin view-facing shims and injecting the coordinator's dependencies.

**Rationale:** Project creation is a bounded async workflow with its own persistence and monitor state. Keeping that workflow inside `AppState` forced a monolithic state owner to also own long-running process orchestration. The coordinator boundary narrows `AppState` blast radius without churning the view layer.

## Decision 27: Terminal activation planning ownership stays in Swift

`TerminalLauncher` is the sole production activation owner. The Rust `runtime_activation` module is now compiled only for tests, and the UniFFI activation-planning APIs were removed from the generated Swift bridge.

**Rationale:** Production behavior already flows through Swift `performUnifiedActivation` and its regression suite. The Rust planner had no production call sites, so keeping it exposed through UniFFI created cross-language ownership ambiguity without delivering runtime value. Quarantining it to test-only reference code removes architectural duplication while preserving a reusable policy corpus if we later choose to port ownership intentionally.

## Decision 28: Setup and hook-server lifecycle transitions are owned by explicit reducers

`SetupRequirementsManager` now delegates state mutation to `SetupLifecycleState`, which owns onboarding transitions for runtime initialization, setup checks, hook install results, and shell-instructions presentation. `HookServerManager` now delegates lifecycle mutation to `HookServerLifecycleState`, which owns the transition rules for start, ready, failure-threshold restart, and explicit stop.

**Rationale:** The previous logic spread lifecycle ownership across imperative branches in multiple methods, making it harder to reason about which transitions were legal and which caller last mutated the state. Explicit reducers narrow that surface to a small transition table, make lifecycle behavior directly unit-testable, and reduce the chance of state drift when new setup or hook-server branches are added later.

## Decision 29: Project-facing feature policy is owned by a dedicated coordinator, not AppState

`ProjectFeatureCoordinator` now owns the project-facing feature-policy branches that were previously embedded in `AppState`: project detail navigation, idea-capture modal routing, idea polling and mutation helpers, description generation, and feature-gated project creation from ideas. `AppState` remains the observable facade/composition root, wiring feature flags, UI state sinks, and `ProjectDetailsManager`/`ProjectCreationCoordinator` dependencies into thin delegating shims.

**Rationale:** These branches are not core runtime state ownership; they are feature-policy decisions about whether to expose or route in-development capabilities. Keeping them inside `AppState` mixed long-lived runtime orchestration with optional feature gating, increased blast radius for simple feature changes, and made it harder to reason about which code was core versus feature-specific. A dedicated coordinator narrows that seam without removing the features or changing their externally visible behavior.

## Decision 30: Debug and tuning surfaces consume production state through explicit wrappers; they do not own it

`GlassConfig` now lives in a production-owned theme path and remains the same shared live `@Observable` instance consumed by both production rendering and the debug UI tuning panel. The remaining debug-only controls are routed through explicit wrapper types under `apps/swift/Sources/Capacitor/Debug/`: `AppDebugCommands`/`AppDebugWindows` for app-level menu and window wiring, `ProjectListDiagnosticsSection` for inline project diagnostics, and `SetupDebugScenarioPicker` for onboarding preview scenarios.

**Rationale:** The previous structure inverted ownership by placing production visual state under a debug tuning-panel path and embedding concrete debug menu/card/preview logic directly into production app and view files. That made it harder to tell which code was operationally required versus optional tooling. Moving shared state to a production-owned path while quarantining debug controls behind explicit wrappers preserves live tuning behavior but makes the boundary mechanically enforceable with denylist ratchets.

## Decision 31: Session-state staleness evaluation is clock-injected at the merge boundary

`SessionStaleness` now provides a `SessionClock`, and `SessionStateManager` resolves that clock at the start of each runtime-merge application, then passes the resulting `now` into working-staleness normalization. The `SessionStateManagerTests` fixture data no longer relies on literal wall-clock dates and instead builds deterministic timestamps from a shared fixture time.

**Rationale:** The old behavior implicitly depended on `Date()`, so tests that seeded fixed historical timestamps eventually stopped exercising hysteresis and started asserting against stale-state normalization. Injecting time at the merge boundary keeps production semantics unchanged while making tests deterministic and allowing the ratchet on fixed `2026-02-28` literals to fall to zero.

## Decision 32: Creation session attribution chooses the newest discovered session file deterministically

`ProjectCreationCoordinator` no longer takes `newSessions.first` from an unordered `Set`. It now resolves new session files from the Claude projects directory, sorts them by modification time descending with a stable filename tie-breaker, and attaches the newest discovered session to the in-flight creation.

**Rationale:** Session discovery is advisory but user-visible. When multiple new `.jsonl` files appear between poll intervals, attribution must be deterministic and anchored to an explicit recency rule rather than hash-set iteration order.

## Decision 33: Direct-match session arbitration prefers recency before activity and normalizes stale working first

`SessionStateManager` now compares direct-match candidates by recency before activity class, and its activity tiebreaker operates on the normalized runtime state after stale-working downgrade.

**Rationale:** A stale `working` candidate that will be downgraded to `ready` should not out-rank a newer `ready` candidate and carry older session metadata into the UI. Recency is the authoritative signal once two direct matches resolve to the same effective readiness class.

## Decision 34: Runtime snapshot failures are hysteretic and clear stale runtime-derived UI state after the second consecutive fresh failure

`AppState` now tracks consecutive fresh runtime snapshot failures. A first fresh failure preserves existing runtime-derived session and shell state to tolerate transient snapshot outages; a second consecutive fresh failure clears that runtime-derived state and recomputes the active-project context. Any successful fresh snapshot resets the failure counter. The runtime bootstrap task also now honors cancellation so tests and future callers can quiesce bootstrap deterministically.

**Rationale:** Snapshot fetch failures are not equivalent to an empty snapshot, so clearing immediately is too aggressive. But never clearing leaves stale “working/ready” UI pinned indefinitely after the runtime becomes unavailable. A small hysteresis window gives transient tolerance while still converging away from stale state.

## Decision 35: Replay verification is pre-merge, soak verification is nightly, and both flow through one operational wrapper

`scripts/ci/runtime-reliability.sh` is now the single operational entrypoint for session-state reliability checks. Pre-merge CI runs it in `ci` mode, which executes the migration guard and the replay/session-state gate. The scheduled `hem-shadow-nightly` workflow runs it in `nightly` mode, which adds the HEM shadow soak benchmark on top of the same guard + replay baseline.

**Rationale:** The replay gate and soak bench already existed, but they were separate operational concepts and therefore easy to drift apart. A single wrapper plus guard-enforced workflow wiring makes the verification path deterministic for humans and agents: one pre-merge path, one nightly path, shared baseline checks, and explicit prevention of accidental removal.
