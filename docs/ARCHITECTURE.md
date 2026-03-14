# Capacitor Architecture (Dedicated Runtime Service)

## Principles

1. One application boundary: the local runtime service owns ingest, state derivation, and typed runtime reads.
2. One production owner per behavior: Rust owns runtime semantics; Swift owns presentation, orchestration, and macOS side effects.
3. One semantic path: hook adapters, shell adapters, and UI reads all converge on the same runtime service state.

## Runtime Flow

1. Claude Code hook events reach `hud-hook serve` over `/hook`.
2. `hud-hook serve` hosts the local runtime service and normalizes adapter input into the canonical `capacitor-core` runtime.
3. `capacitor-core` applies ingest, reducer, and projection logic, then persists runtime artifacts for durability and replay.
4. The Swift app reads runtime state from authenticated `/runtime/*` endpoints exposed by the service.
5. `AppState`, `SessionStateManager`, and `ShellStateStore` apply presentation-only freshness guards and hysteresis before updating visible UI state.

## Ownership

- Rust (`core/capacitor-core`):
  - Path normalization and workspace identity
  - Hook and shell ingest normalization
  - Reducer/query state derivation
  - Runtime persistence and replay artifacts
  - Runtime setup validation and hook-health evaluation
- Runtime service shell (`core/hud-hook`):
  - Local authenticated runtime-service process
  - Claude `/hook` adapter ingress
  - Shell `cwd` forwarding
  - Typed `/runtime/*` read and ingest endpoints
- Swift (`apps/swift/Sources/Capacitor`):
  - Runtime-service supervision and reconnect/adoption
  - Runtime snapshot projection and stabilization (`SessionStateManager`, `ShellStateStore`, `RoutingStateStore`, `AppState`)
  - SwiftUI views + interaction flows
  - Activation orchestration (`TerminalActivationCoordinator`)
  - tmux execution and client/session/pane routing (`TmuxRouter`)
  - Terminal host automation (`TerminalDriver` implementations, `GhosttyAutomationClient`)
  - Setup and feature-policy coordinators

## Boundaries

- Runtime boundary: authenticated local HTTP service hosted by `hud-hook serve`
- FFI boundary: `capacitor-core` UniFFI exports for app-facing setup and non-runtime APIs
- Adapter boundary: Claude `/hook` and shell `cwd` inputs forward into the runtime service; they do not own lifecycle semantics

## Repository Shape

- `core/capacitor-core/`: canonical ingest, reducer, query, storage, and FFI runtime
- `core/hud-hook/`: runtime-service shell plus hook/shell adapters
- `apps/swift/`: menubar application, runtime-service client/supervisor, projection layer, and feature coordinators

## Activation Boundaries

- Rust derives canonical routing targets from shell and session evidence.
- `AppState` applies routing state from the periodic runtime snapshot and feeds route preferences into activation.
- `TerminalActivationCoordinator` owns request arbitration, stale-request suppression, and activation outcome reporting.
- `TmuxRouter` is the only place raw tmux command strings are built or executed.
- `GhosttyTerminalDriver` plus `GhosttyAutomationClient` own Ghostty's native routing and launch behavior.
- `ITermTerminalDriver` and `TerminalAppTerminalDriver` own their TTY-based host focus and launch behavior, including typed failure mapping.

## Non-Goals

- Reintroducing parallel runtime policy paths across Rust and Swift
- Treating snapshot-file reads as the primary app/runtime boundary
- Backward compatibility with daemon-era IPC or launchd ownership models
