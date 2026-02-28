# Gotchas Reference

Detailed implementation gotchas for Capacitor development. See `/Users/petepetrash/Code/capacitor/CLAUDE.md` for the short version.

For multi-step debugging procedures, see `/Users/petepetrash/Code/capacitor/.claude/docs/debugging-guide.md`.

## Rust

### Formatting Required
CI enforces `cargo fmt`. Always run it before committing.

### Release dylib Required for Swift Runs
Swift links against the release Rust dylib. After Rust changes:
```bash
cargo build -p capacitor-core --release
cp target/release/libcapacitor_core.dylib apps/swift/.build/arm64-apple-macosx/debug/
```

### hud-hook Symlink (Not Copy)
Copying adhoc-signed Rust binaries to `~/.local/bin/` can trigger Gatekeeper `SIGKILL` (exit 137). Use a symlink:
```bash
ln -s target/release/hud-hook ~/.local/bin/hud-hook
```

### UniFFI Bindings Must Be Regenerated After FFI Type Changes
```bash
cargo build -p capacitor-core --release
cargo run -p capacitor-core --bin uniffi-bindgen generate \
  --library target/release/libcapacitor_core.dylib \
  --language swift \
  --out-dir apps/swift/bindings
cp apps/swift/bindings/capacitor_core.swift apps/swift/Sources/Capacitor/Bridge/
```
If skipped, Swift can fail with "extra argument ... in call" or checksum mismatch errors.

## Swift

### OSLog Is Not Reliable in Unsigned Debug Runs
For `swift run`, prefer stderr or `DebugLog.write(...)`. See the debugging guide for capture steps.

### UniFFI `Task` Shadows Swift `Task`
Generated bindings define `Task`. Use `_Concurrency.Task` explicitly in app code.

### GeometryReader + Observed State Can Trigger Layout Loops
Capture observable values into local `let` constants before entering `GeometryReader`/layout callbacks.

### TimelineView + Material Blur Can Overload WindowServer
Avoid `TimelineView(.animation)` for blur-heavy surfaces; prefer state-driven `withAnimation` loops.

### Incremental Build Can Leave Stale Binary
When no Swift files changed, force a rebuild:
```bash
./scripts/dev/restart-alpha-stable.sh --force
```

## Runtime + Activation

### Rust Resolver Owns Activation Decisions
Activation decision logic belongs in Rust (`core/capacitor-core/src/runtime_activation/`). Swift only executes returned actions.

### Tmux Client TTY Must Be Queried at Activation Time
Do not trust previously captured tmux client tty values. Query fresh with:
```bash
tmux display-message -p '#{client_tty}'
```

### Matching Rules: Exact for Identity, Parent/Child for UI Focus
Use exact identity matching for project/session ownership; use parent/child path matching only for focus UX.

## Hooks

### Hook Config Requires Both `async` and `timeout`
Claude Code hook entries must include both fields or validation fails.

### First-Run Testing
Use `/Users/petepetrash/Code/capacitor/scripts/dev/reset-for-testing.sh` to reset prefs, runtime state, and hook registrations.
