# Holistic Reliability + Simplicity Plan (Rust Core + Swift Client)

Date: 2026-03-05
Status: Draft execution baseline
Scope: End-to-end hardening and simplification without removing in-development features

## 1. Mission
Turn Capacitor into a high-reliability, low-bloat system by fixing correctness defects first, then reducing architectural complexity while preserving all current capabilities.

## 2. Inputs Incorporated
- Rust audit summary: `.claude/docs/audit/SUMMARY.md`
- Rust subsystem findings: `.claude/docs/audit/01-hook-and-runtime-ingest.md`, `.claude/docs/audit/02-setup-health-projects.md`
- Swift audit summary: `.claude/docs/audit/swift-client/SUMMARY.md`
- Swift subsystem findings:
  - `.claude/docs/audit/swift-client/01-runtime-state-and-resolution.md`
  - `.claude/docs/audit/swift-client/02-terminal-activation-and-process.md`
  - `.claude/docs/audit/swift-client/03-creation-and-ingestion.md`
  - `.claude/docs/audit/swift-client/04-setup-and-lifecycle.md`
  - `.claude/docs/audit/swift-client/05-tests-and-regressions.md`
- Simplicity audit: `.claude/docs/audit/simplicity-audit.md`
- Existing migration control plane: `.claude/migration/CHARTER.md`, `.claude/migration/DECISIONS.md`, `.claude/migration/SLICES.yaml`, `.claude/migration/MAP.csv`, `.claude/migration/guard.sh`

## 3. Consolidated Audit Picture

### 3.1 Severity Snapshot
| System | High | Medium | Low | Total |
|---|---:|---:|---:|---:|
| Rust core + hud-hook | 2 | 3 | 1 | 6 |
| Swift client | 8 | 7 | 1 | 16 |
| Combined | 10 | 10 | 2 | 22 |

### 3.2 Cross-System Risk Themes
1. Ownership ambiguity across boundaries
- Activation logic is split conceptually across Rust and Swift with likely unconsumed Rust planner surface.
- Setup/lifecycle concerns are distributed across multiple Swift objects without one clear supervisor.

2. Concurrency and lifecycle race hazards
- Unsynchronized process output mutation, async task cancellation leaks, restart-after-stop races.
- Drag/drop and creation-monitor sequencing races.

3. State correctness and attribution drift
- Stale generation suppression is incomplete (shell state can still commit).
- Metadata can freeze globally when only one project is under stabilization hold.
- Rust active-session/health and project sorting semantics do not consistently reflect real activity.

4. Verification gaps
- Setup verification invokes removed CLI shape.
- Time-dependent tests and missing regression tests reduce confidence.

5. Accidental orchestration complexity
- `AppState` is oversized and mixes unrelated workflows.
- Debug/frontier/tooling complexity is intertwined with core runtime surfaces.

## 4. Strategic Direction (Feature-Preserving Simplification)

### 4.1 Keep
- Runtime snapshot/reducer core as canonical state model.
- Hook-server architecture (HTTP-based ingest) as the transport baseline.
- In-development features (ideas/project creation/workstreams/debug tooling) as supported capabilities.

### 4.2 Simplify
- Reduce coupling, not feature count.
- Enforce single-owner boundaries per concern.
- Move optional/feature-specific behavior behind explicit module boundaries.
- Shrink central orchestration blast radius (`AppState`) by extracting narrow services.

### 4.3 Reliability Contract
Each slice must improve at least one of:
- Determinism
- Race safety
- Failure recoverability
- Testability
- Architectural clarity

## 5. Target Architecture (North Star)

### 5.1 Ownership Boundaries
1. Rust owns: hook ingestion validation, event normalization, snapshot persistence/query.
2. Swift owns: UI state composition, terminal process execution, lifecycle orchestration.
3. Activation planning ownership: one owner for this release cycle, with the other path quarantined.

### 5.2 Swift Composition After Refactor
- `RuntimeProjectionService`: fetch + generation guards + merge commit.
- `LifecycleSupervisor`: setup, hook server lifecycle, health, restart policy.
- `ActivationService`: terminal activation execution and process controls.
- `FeatureModules`: creation/ideas/workstreams isolated behind protocols.
- `AppState`: composition root + UI bindings only.

### 5.3 Rust Safety Expectations
- No ambient `PWD` fallback for HTTP hook requests with missing `cwd`.
- Hard request-body caps independent of `Content-Length`.
- Health/session activity semantics aligned with real liveness and recency.

## 6. Deterministic Migration Program

## Phase 0: Re-baseline Control Plane
Goal: convert existing hook-focused migration scaffolding into full-program governance.

- `P0-1` Expand charter invariants to include Swift/Rust correctness, race-safety, and feature-preserving simplification.
- `P0-2` Extend `SLICES.yaml` and `MAP.csv` with cross-system slices below.
- `P0-3` Extend `guard.sh` ratchets for known anti-patterns (examples: `fatalError` setup crash path, deprecated CLI verification shape, unsynchronized process output handling markers).
- `P0-4` Add mandatory `HANDOFF.md` protocol for every slice close.

Exit criteria:
- Control-plane files represent the whole program, not only HTTP hook migration.
- Guard script reports clean baseline.

## Phase 1: Critical Correctness (High-Severity First)
Goal: eliminate all high-severity defects from both audits.

### Rust slices
- `R1-1` Hook cwd attribution correctness
  - Remove unsafe fallback behavior for missing request `cwd`.
  - Add regression tests for missing/invalid cwd payloads.

- `R1-2` Hook server body-size enforcement
  - Enforce hard byte caps even without `Content-Length`.
  - Add tests for chunked/no-length oversized payloads.

- `R1-3` Hook binary verification correctness
  - Replace removed CLI verification path with supported command/health probe.
  - Add tests that fail on invalid binary shape.

### Swift slices
- `S1-1` Setup crash path removal
  - Replace `fatalError` initialization path with recoverable setup error state.
  - Add UI/state tests for initialization failure handling.

- `S1-2` Stale commit atomicity
  - Apply one generation guard to both session and shell-state commits.
  - Add regression tests that prove stale snapshots cannot mutate either store.

- `S1-3` Stabilization metadata isolation
  - Change map fallback from global to per-project scope.
  - Add tests showing unaffected projects keep fresh metadata.

- `S1-4` Terminal process race + cancellation
  - Synchronize output capture.
  - Add cancellation handler + timeout + process termination.
  - Add stress tests for concurrent output and cancellation.

- `S1-5` Drag/drop ingestion race
  - Make append/leave ordering deterministic.
  - Add reproducible tests for mixed valid/invalid URL drops.

Exit criteria:
- All Phase 1 slices done with passing tests.
- No unresolved High findings remain open.

## Phase 2: Lifecycle and Liveness Hardening
Goal: remove medium-severity race/liveness flaws that can create latent production instability.

- `S2-1` Creation monitor cancellation correctness
  - Prevent cancelled creations from reactivation.
  - Track and cancel monitor tasks by creation ID.

- `S2-2` Hook server lifecycle hardening
  - Non-blocking stop semantics.
  - Cancel in-flight health checks on stop.
  - Add restart guards (epoch/intent token).
  - Harden PID adoption with identity/port checks.

- `R2-1` Runtime health active-session semantics
  - Tighten active criteria and stale-session handling.

- `R2-2` Project ordering correctness
  - Sort by latest session file activity, not project dir mtime.

- `S2-3` Main-actor blocking subprocess removal
  - Move sensemaking git calls off main actor and merge results back safely.

Exit criteria:
- Lifecycle actions are cancellation-safe and non-blocking on main actor.
- Health/restart behavior is deterministic under stop/start race tests.

## Phase 3: Architectural Simplification Without Feature Cuts
Goal: reduce accidental complexity and blast radius while preserving full feature surface.

- `A3-1` `AppState` decomposition
  - Extract runtime, lifecycle, activation, and feature modules.
  - Keep `AppState` as thin composition root.

- `A3-2` Activation ownership decision and cleanup
  - Choose one activation planner owner for this cycle.
  - Quarantine or delete unconsumed activation path artifacts in the non-owner layer.

- `A3-3` Setup pipeline state machine
  - Explicit phases and transitions for install/check/launch/verify.
  - Remove ad hoc lifecycle branching.

- `A3-4` Feature module boundaries
  - Keep in-development features enabled but isolate their state machines and side effects.
  - Eliminate cross-cutting feature logic from core runtime paths.

- `A3-5` Debug/tooling isolation
  - Move debug/tuning surfaces behind explicit debug module boundary and dependency boundary.

Exit criteria:
- `AppState` is materially smaller and orchestration-only.
- Activation path has one clear owner.
- Feature code remains present but no longer entangled with critical runtime paths.

## Phase 4: Regression Shield + Operational Readiness
Goal: lock in gains and prevent drift.

- `T4-1` Fix time-dependent tests with injected clock/test-time controls.
- `T4-2` Add missing regression tests from both audits.
- `T4-3` Update stale comments/docs to match post-refactor architecture.
- `T4-4` Add periodic soak and replay checks to CI or pre-merge checks.

Exit criteria:
- Deterministic tests pass across dates and environments.
- Guard budgets are lower than baseline and denylist checks are stable at zero.

## 7. Agent Execution Protocol (Anti-Drift / Anti-Tunnel-Vision)

1. One active slice at a time in `SLICES.yaml`.
2. Test-first rule for every bug or correctness claim.
3. Every slice includes deletion targets up front.
4. Every slice must update all control-plane artifacts (`SLICES.yaml`, `MAP.csv`, `DECISIONS.md`, `HANDOFF.md`).
5. Guard script + test suites must pass before slice closure.
6. Parallel agents may only work on disjoint path sets.
7. Any architecture boundary decision is append-only in `DECISIONS.md`.
8. Confidence is evidence-based only: failing test reproduced -> fixed -> guard + suites green.

## 8. Program-Level Metrics
Track these weekly:
- Open findings by severity (target: High = 0, Medium trending down).
- Guard ratchet counts (target: monotonic decrease).
- Flake rate in Swift and Rust tests.
- Main-actor blocking call count in hot paths.
- `AppState.swift` LOC and dependency fan-in.
- Number of cross-boundary calls that bypass designated owners.

## 9. Immediate Next Actions
1. Ratify this plan into control-plane artifacts (charter/slices/map/guard) as the new baseline.
2. Start Phase 1 slices in strict severity order.
3. Close each slice only with proof artifacts and ratchet updates.
