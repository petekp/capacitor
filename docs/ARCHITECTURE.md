# Capacitor Architecture (Dedicated Runtime Service)

> Doc role: `canonical-spec`
> Status: Current architecture spec. Read after `.claude/docs/architecture-primer.md`.
> Rationale: `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

## System Boundary

Capacitor uses a dedicated local runtime service as its live application boundary.

- VERIFIER_CLAIM(runtime_boundary_service): owner_scope=core/hud-hook/src/serve.rs; Runtime boundary: authenticated local HTTP service hosted by `hud-hook serve`
- Live runtime reads go through authenticated `/health` and `/runtime/*` endpoints exposed by that service.
- Persisted artifacts under `~/.capacitor/runtime/` exist for durability, replay, and debugging. They are not the primary live boundary for the app.
- The UniFFI boundary remains the app-facing path for setup and other non-runtime APIs.

## Ownership By Subsystem

- VERIFIER_CLAIM(runtime_semantics_owner_split): owner_scope=core/**/*.rs,apps/swift/Sources/Capacitor/**/*.swift; One production owner per behavior: Rust owns runtime semantics; Swift owns presentation, orchestration, and macOS side effects.
- Rust (`core/capacitor-core`) owns path normalization, workspace identity, ingest normalization, reducer/query state derivation, runtime persistence, replay artifacts, and runtime setup validation.
- `core/hud-hook` owns the local authenticated runtime-service shell, Claude hook ingress, shell `cwd` forwarding, and the typed `/runtime/*` read plus ingest endpoints.
- Swift (`apps/swift/Sources/Capacitor`) owns runtime-service supervision, projection and stabilization (`SessionStateManager`, `ShellStateStore`, `RoutingStateStore`, `AppState`), SwiftUI views, activation orchestration, tmux execution, terminal drivers, and setup coordinators.

## Runtime Data Flow

1. Claude hook events and shell cwd signals reach `hud-hook serve`.
2. `hud-hook serve` normalizes adapter input and forwards it into the canonical `capacitor-core` runtime.
3. `capacitor-core` applies ingest, reducer, and query logic, then persists runtime artifacts for durability and replay.
4. The Swift app reads typed runtime state from authenticated `/runtime/*` endpoints exposed by the service.
5. Swift projection layers apply presentation-only freshness guards and hysteresis before updating visible UI state.

## Activation Boundaries

- Rust derives canonical routing targets from shell and session evidence.
- `ActivationPolicy` interprets routing state into activation intent and applies only explicit local fallback when runtime facts are missing or incomplete.
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
