# Gotchas Reference

This file is the implementation-hazard companion to `CLAUDE.md` and
`.claude/docs/debugging-guide.md`.

Architecture source of truth lives in:

- `CLAUDE.md`
- `docs/ARCHITECTURE.md`
- `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
- `docs/channel-profile-workflow.md`

## Rust

### Formatting is mandatory

CI enforces `cargo fmt`. Run it before committing.

### Swift links the release Rust dylib

Default workflow after Rust changes:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Fallback surgery only, when you are debugging the build pipeline itself:

```bash
cargo build -p capacitor-core --release
cd apps/swift
SWIFT_BIN_PATH="$(swift build --show-bin-path)"
cp ../../target/release/libcapacitor_core.dylib "$SWIFT_BIN_PATH/"
```

### Use the installed `hud-hook` binary, not ad hoc copies

Copying adhoc-signed Rust binaries into `~/.local/bin/` can trigger Gatekeeper
`SIGKILL` (exit 137). Prefer the canonical installer flow:

```bash
./scripts/sync-hooks.sh --force
```

If you must inspect the path directly, the installed binary is:

```bash
~/.local/bin/hud-hook
```

### UniFFI bindings must be regenerated after FFI type changes

```bash
cargo build -p capacitor-core --release
cargo run -p capacitor-core --bin uniffi-bindgen generate \
  --library target/release/libcapacitor_core.dylib \
  --language swift \
  --out-dir apps/swift/bindings
cp apps/swift/bindings/capacitor_core.swift apps/swift/Sources/Capacitor/Bridge/
```

If you skip this, Swift can fail with checksum mismatches or mismatched call shapes.

### Managed hook config must match the current mixed transport contract

Capacitor accepts only the canonical nested managed hook format from the current
event/type contract. Do not add ad hoc hook fallbacks or alternate config shapes
to patch setup problems. The live ingress flows through the local hook endpoint
into the runtime service.

## Swift

### `OSLog` is unreliable in unsigned debug runs

For `swift run`, prefer `DebugLog.write(...)`, stderr, and
`./scripts/dev/agent-observe.sh`.

### UniFFI `Task` shadows Swift `Task`

Generated bindings define `Task`. Use `_Concurrency.Task` explicitly in app code.

### `GeometryReader` plus observed state can trigger layout loops

Capture observable values into local `let` constants before entering
`GeometryReader` or layout callbacks.

### `TimelineView(.animation)` plus heavy blur can overload WindowServer

Prefer state-driven animation loops over perpetual `TimelineView(.animation)` for
blur-heavy surfaces.

### Incremental builds can leave a stale app binary

When Swift looks unchanged but runtime behavior disagrees, force a rebuild:

```bash
./scripts/dev/restart-alpha-stable.sh --force
```

## Runtime And Activation

### Rust owns persisted truth; Swift owns projection and execution

Do not move snapshot truth, setup policy, or file-backed semantics into Swift.
Do not move terminal activation execution into Rust.

### `AppState` is the shell environment hub, not a policy dumping ground

`AppState` may expose canonical collaborators to views, but it should not
recreate live-world assembly, duplicate domain rules, or become a façade for
every workflow.

### Production activation flow lives in Swift

The live activation flow is owned by Swift and currently centered on:

- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `apps/swift/Sources/Capacitor/Models/GhosttyAXReader.swift`

Rust owns runtime truth and hook ingest. It does not own live terminal activation execution.

### Query tmux client TTY at activation time

Do not trust previously captured TTYs blindly. Query fresh when you need to
reason about active tmux clients:

```bash
tmux list-clients -F '#{client_tty} #{session_name}'
```

### Use exact identity for ownership; use parent/child only for focus UX

Project/session ownership should use exact or normalized identity matching.
Parent/child path matching is only for UI focus and activation heuristics.

## Hooks And First-Run Testing

### Shell snippets must call `hud-hook cwd`

The source of truth for shell integration text is:

- `apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift`
- `apps/swift/Sources/Capacitor/Views/Setup/ShellInstructionsSheet.swift`

Relevant verification tests:

- `apps/swift/Tests/CapacitorTests/HookInstallerTests.swift`
- `apps/swift/Tests/CapacitorTests/ShellSetupInstructionsTests.swift`

### First-run testing should reset both prefs and runtime state

Use:

```bash
./scripts/dev/reset-for-testing.sh
```

That script resets app prefs, runtime state, installed hook configuration, and
development bundle state so onboarding can be tested honestly.
