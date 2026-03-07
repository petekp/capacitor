# Capacitor Architectural Audit Plan

Date: 2026-03-06

Method:

- Read the stated architecture in [docs/ARCHITECTURE.md](/Users/petepetrash/Code/capacitor/docs/ARCHITECTURE.md) and compare it to the running code paths.
- Decompose the system by container and subsystem before judging quality.
- Verify likely drift points with tests, docs, and cross-surface references.
- Exclude local build artifacts from findings unless they are tracked or shape the production architecture.

Evidence gathered:

- `cargo test` passed for `capacitor-core` and `hud-hook`.
- `npm test` passed for `services/ingest-worker`.
- The current worktree is `/Users/petepetrash/Code/capacitor` on branch `main`.

## Subsystem Table

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Hook ingest adapter | `core/hud-hook/src/*.rs` | HTTP server, PID file, heartbeat file, snapshot lock file | High |
| 2 | Core runtime engine | `core/capacitor-core/src/{domain,ingest,reduce,query,storage,runtime_state}` | Snapshot persistence under `~/.capacitor/runtime/` | High |
| 3 | Core setup/catalog services | `core/capacitor-core/src/{runtime_setup,runtime_validation,runtime_projects,runtime_ideas,lib.rs}` | Reads/writes `~/.claude/`, project metadata, idea files | High |
| 4 | Swift app orchestration + projection | `apps/swift/Sources/Capacitor/Models/{AppState,RuntimeClient,SessionStateManager,ShellStateStore,ActiveProjectResolver}.swift` | UI state, snapshot reads, polling, routing decisions | High |
| 5 | Swift platform integration services | `apps/swift/Sources/Capacitor/Models/{TerminalLauncher,HookServerManager,ProjectDetailsManager,ProjectCreationCoordinator,WorkstreamsManager}.swift` | AppleScript, AX reads, subprocesses, worktree operations, LLM subprocesses | High |
| 6 | Swift presentation/navigation | `apps/swift/Sources/Capacitor/{ContentView,Views/**/*.swift}` | Rendering, animation timing, drag/drop interaction | Medium |
| 7 | Optional ingest backend | `services/ingest-worker/*` | Remote feedback/telemetry ingest, D1 writes, scheduled retention | Medium |
| 8 | Marketing/download site | `apps/www/*` | Public download CTA, static marketing content | Low |

## Production Boundary Assumptions

- The production runtime path is: Claude Code hooks -> `hud-hook` -> `capacitor-core` snapshot -> Swift `RuntimeClient` -> Swift projection/services -> SwiftUI.
- `services/ingest-worker` is optional and not part of local runtime truth.
- `apps/www` is a separate public-facing asset, not part of the runtime sidecar loop.
- `core/capacitor-core/src/runtime_activation` is not part of the production binary because it is compiled only under `#[cfg(test)]`.

## Main Hypotheses Checked

1. The repo claims a single persisted runtime truth, but the FFI/runtime boundary may still expose multiple storage modes.
2. The Swift app claims split ownership across managers, but the true orchestration burden may still sit inside `AppState`.
3. Peripheral surfaces may have contract drift because they are not on the main product path.
