# Capacitor Architecture (Runtime-Snapshot Model)

## Principles

1. One persisted runtime truth: Rust owns hook ingest, reducer/query policy, and snapshot persistence.
2. One production owner per behavior: Swift owns UI projection, lifecycle orchestration, activation, and macOS integrations.
3. Data-first boundary: runtime snapshots cross the Rust/Swift seam, then Swift applies deterministic projection rules before rendering.

## Runtime Flow

1. Claude Code hook events invoke `capacitor-hook`.
2. `capacitor-hook` normalizes events and writes them to `capacitor-core`.
3. `capacitor-core` applies reducer logic and persists `~/.capacitor/runtime/app_snapshot.json`.
4. Swift reads snapshot-shaped data through `RuntimeClient`.
5. `AppState`, `SessionStateManager`, and `ShellStateStore` apply freshness guards, attribution, and hysteresis before updating visible UI state.

## Ownership

- Rust (`core/capacitor-core`):
  - Path normalization and workspace identity
  - Hook event normalization and reducer/query state derivation
  - Snapshot persistence
  - Runtime setup validation and hook-health evaluation
- Swift (`apps/swift/Sources/Capacitor`):
  - Snapshot projection and stabilization (`SessionStateManager`, `ShellStateStore`, `AppState`)
  - SwiftUI views + interaction flows
  - macOS automation (AppleScript/AX, window activation)
  - Terminal activation ownership
  - Setup/hook-server lifecycle orchestration
  - Feature-policy coordinators for creation, ideas, and debug surfaces

## Boundaries

- FFI boundary: `capacitor-core` UniFFI exports for app-facing APIs.
- Hook ingest boundary: `capacitor-hook` CLI -> `capacitor-core` command ingestion.
- No separate runtime process boundary: socket process removed.

## Repository Shape

- `core/capacitor-core/`: canonical reducer/query/storage runtime + FFI APIs
- `core/capacitor-hook/`: hook/CWD ingest adapter
- `apps/swift/`: menubar application, projection layer, lifecycle supervisors, and feature coordinators

## Non-Goals

- Backward compatibility with legacy IPC/launchd flows
- Maintaining parallel policy implementations across Rust and Swift
