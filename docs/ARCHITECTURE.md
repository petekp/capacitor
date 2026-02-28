# Capacitor Architecture (Runtime-Snapshot Model)

## Principles

1. One core, one truth: Rust owns domain policy and state derivation.
2. Thin UI shell: Swift renders state, captures intent, and performs macOS integrations.
3. Data-first boundaries: commands in, immutable snapshots out.

## Runtime Flow

1. Claude Code hook events invoke `hud-hook`.
2. `hud-hook` normalizes events and writes them to `capacitor-core`.
3. `capacitor-core` applies reducer logic and persists `~/.capacitor/runtime/app_snapshot.json`.
4. Swift reads snapshot-shaped data through `RuntimeClient` and updates UI state.

## Ownership

- Rust (`core/capacitor-core`):
  - Path normalization and workspace identity
  - Session/project state derivation
  - Routing/activation planning inputs
  - Snapshot persistence
- Swift (`apps/swift/Sources/Capacitor`):
  - SwiftUI views + interaction flows
  - macOS automation (AppleScript/AX, window activation)
  - User-triggered command dispatch to runtime

## Boundaries

- FFI boundary: `capacitor-core` UniFFI exports for app-facing APIs.
- Hook ingest boundary: `hud-hook` CLI -> `capacitor-core` command ingestion.
- No separate runtime process boundary: socket process removed.

## Repository Shape

- `core/capacitor-core/`: canonical reducer/query/storage runtime + FFI APIs
- `core/hud-hook/`: hook/CWD ingest adapter
- `apps/swift/`: menubar application

## Non-Goals

- Backward compatibility with legacy IPC/launchd flows
- Maintaining parallel policy implementations across Rust and Swift
