# Capacitor Architecture (Dedicated Runtime Service)

> Doc role: `canonical-spec`
> Status: Current architecture spec. Read after `.claude/docs/architecture-primer.md`.
> Rationale: `docs/architecture-decisions/004-dedicated-local-runtime-service.md`, `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md`

## System Boundary

Capacitor uses a dedicated local runtime service as its live application boundary.

- VERIFIER_CLAIM(runtime_boundary_service): owner_scope=core/hud-hook/src/serve.rs; Runtime boundary: authenticated local runtime service hosted by `hud-hook serve`
- Live runtime reads go through authenticated `/health` and `/runtime/*` endpoints exposed by that service.
- Persisted artifacts under `~/.capacitor/runtime/` exist for durability, replay, and debugging. They are not the primary live boundary for the app.
- The UniFFI boundary remains the app-facing path for setup and other non-runtime APIs.

## Ownership By Subsystem

- VERIFIER_CLAIM(runtime_semantics_owner_split): owner_scope=core/**/*.rs,apps/swift/Sources/Capacitor/**/*.swift; One production owner per behavior: Rust owns runtime semantics; Swift owns presentation, orchestration, and macOS side effects.
- Rust (`core/capacitor-core`) owns path normalization, workspace identity, ingest normalization, reducer/query state derivation, runtime persistence, replay artifacts, and runtime setup validation.
- `core/hud-hook` owns the local authenticated runtime-service shell, Claude hook ingress, shell `cwd` forwarding, and the typed `/runtime/*` read plus ingest endpoints.
- Swift (`apps/swift/Sources/Capacitor`) owns runtime-service supervision, projection and stabilization (`SessionStateManager`, `ShellStateStore`, `RoutingStateStore`, `AppState`), SwiftUI views, activation orchestration, tmux execution, terminal drivers, and setup coordinators.

## Runtime Data Flow

1. Claude hook events and shell cwd signals reach `hud-hook serve` as distinct live signals into the runtime boundary.
2. `hud-hook serve` normalizes adapter input and forwards it into the canonical `capacitor-core` runtime.
3. `capacitor-core` applies ingest, reducer, and query logic, then persists runtime artifacts for durability and replay. ADR-005 authority-based multi-signal state detection is complete (Phases 1-3, 2026-03-29 through 2026-04-15): hooks remain authoritative for nuanced state; transcripts provide session-existence evidence via the transcript observation service (`Inferential` authority); the authority matrix is enforced in the reducer; evidence replay is contract-tested equivalent to continuous ingest.
4. The Swift app reads typed runtime state from authenticated `/runtime/*` endpoints exposed by the service.
5. Swift projection layers apply presentation-only freshness guards and hysteresis before updating visible UI state. Hook setup failure is non-blocking: the app launches with diagnostics surfaced in the setup UI rather than gating startup.

## State Detection Architecture

ADR-005 is complete. All three phases shipped between 2026-03-29 and 2026-04-15:

- **Phase 1 — Unblock startup** (shipped 2026-03-29, commit `50b81fc1`). Hooks are optional at startup: install or repair failures are informational, not launch-blocking. Only a missing Claude CLI binary or an explicit hook policy block still gates setup. `HookStatus` distinguishes granular setup states; `isFirstRun` derives from a persisted setup marker instead of `HookHealthStatus::Unknown`.
- **Phase 2 — Transcript observation service** (shipped 2026-04-14/15, steps 5-7). `observation::transcript::scan_for_sessions()` is the single Rust-owned abstraction for transcript discovery. `ReducerState::apply_transcript_discovery()` creates Idle sessions with `Inferential` authority. `CoreRuntime::from_storage_with_transcript_cold_start()` reconstructs session existence from transcripts when the persisted snapshot is empty.
- **Phase 3 — Authority matrix + provenance + evidence replay** (Slices 1-6, shipped 2026-04-12/15). `SessionSummary` carries typed provenance across the FFI boundary: `state_source: Option<StateSource>` with `event_kind: HookEventType`, `authority: SignalAuthority` (5 tiers: `DefinitiveTerminal`, `DefinitiveTransient`, `AmbiguousPerTurn`, `MetaAwaitingInput`, `Inferential`), and `observed_at: String`. Reducer enforcement (`AUTHORITY_MATRIX` const + two-layer override guards in `reduce/session.rs`) makes terminal states sticky against lower-authority events. Evidence replay is contract-tested equivalent to continuous live ingest.

Authority matrix (which signal answers which question):

- Nuanced session state (waiting, working, compacting, idle): **hooks** primary; transcripts degrade to coarse "active/inactive" from mtime evidence.
- Session existence and recency: **transcripts + hooks** co-equal.
- Project/terminal routing: **shell CWD** only (non-blocking).
- State recovery after restart: **persisted snapshot + evidence replay**; cold-start reconstruction from transcripts when snapshot is empty.

See `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md` for the full phase decisions, binding conditions, and verification questions.

## Activation Boundaries

- Rust derives canonical routing targets from shell and session evidence.
- `ActivationPolicy` (in `apps/swift/Sources/Capacitor/Models/`) interprets routing state (derived in Rust) into activation intent. When runtime facts are missing or incomplete, it applies a documented local fallback ladder — explicit per-host rules in the policy itself — rather than guessing from partial data.
- `TerminalActivationCoordinator` owns request arbitration, stale-request suppression, and activation outcome reporting.
- VERIFIER_CLAIM(tmux_router_exclusive_command_owner): owner_scope=apps/swift/Sources/Capacitor/Models/TmuxRouter.swift; `TmuxRouter` is the only place raw tmux command strings are built or executed.
- `GhosttyTerminalDriver` plus `GhosttyAutomationClient` own Ghostty's native routing and launch behavior.
- `ITermTerminalDriver` and `TerminalAppTerminalDriver` own their TTY-based host focus and launch behavior, including typed failure mapping.

## Orchestration and Checkpoints

Capacitor supports two independent review flows that share a common window structure:

- **Delegation review** — driven by `DelegationLoopManager` milestone files. Swift owns the delegation lifecycle: idea capture, worktree launch, milestone scanning, review presentation, decision submission, and resume prompts. Multi-round iteration is supported (request changes → new milestone → re-review).
- **Run checkpoint review** — driven by runtime snapshot `runs` and `activeCheckpoint`. The checkpoint bridge (`checkpoint_bridge.rs`) connects method-runner gates to the run kernel, and `hud-hook` relays decisions back via file-based protocol. `AppState` auto-targets the oldest paused checkpoint.

Both flows use `DelegationReviewManifest` as the shared decoder contract and present a left-pane/right-rail review window.

Canonical documentation: `docs/orchestrator/`

| Doc | Covers |
|-----|--------|
| `docs/orchestrator/checkpoint-bridge.md` | Gate→checkpoint→decision→unblock pipeline |
| `docs/orchestrator/review-surfaces.md` | Shared review window contract |
| `docs/orchestrator/appstate-checkpoint-policy.md` | AppState routing policy for both review flows |
| `docs/orchestrator/terminology.md` | Normalized glossary |
| `docs/orchestrator/idea-to-run-gap.md` | Current gaps between idea capture and method execution |

## Non-Goals

- Reintroducing parallel runtime policy paths across Rust and Swift
- VERIFIER_CLAIM(snapshot_file_not_primary_boundary): owner_scope=apps/swift/Sources/Capacitor/**/*.swift; Treating snapshot-file reads as the primary app/runtime boundary
- Backward compatibility with daemon-era IPC or launchd ownership models
