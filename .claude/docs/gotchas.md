# Gotchas Reference

Detailed implementation gotchas for Capacitor development. See CLAUDE.md for the most common ones.

## Rust

### Formatting Required
CI enforces `cargo fmt`. Pre-commit hook catches this.

### dylib Copy After Rebuilds
After Rust rebuilds: `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`

### hud-hook Symlink (Not Copy)
Copying adhoc-signed Rust binaries to `~/.local/bin/` triggers macOS Gatekeeper SIGKILL (exit 137). Use symlink instead:
```bash
ln -s target/release/hud-hook ~/.local/bin/hud-hook
```
See `scripts/sync-hooks.sh`.

### hud-hook Must Point to Dev Build
During development, `~/.local/bin/hud-hook` must symlink to `target/release/hud-hook` (not app bundle) to pick up changes. After Rust changes: rebuild, verify symlink target. Stale hooks create stale locks.

### Logging Guard Must Be Held
`logging::init()` returns `Option<WorkerGuard>` which must be held in `main()` scope. Using `std::mem::forget()` prevents log flushing. See `logging.rs` and `main.rs:70`.

### UniFFI Bindings Must Be Regenerated
After adding/changing fields in FFI types (e.g., `ShellEntryFfi`), regenerate Swift bindings:
```bash
cargo build -p hud-core --release  # Must build release first
cargo run --bin uniffi-bindgen generate \
    --library target/release/libhud_core.dylib \
    --language swift --out-dir apps/swift/bindings
cp apps/swift/bindings/hud_core.swift apps/swift/Sources/Capacitor/Bridge/
```
Symptom without this: Swift compile error "extra argument 'fieldName' in call".

### Tmux Multi-Client Detection
Use `tmux display-message -p "#{client_tty}"` (not `list-clients`) to get the current client's TTY. `list-clients` returns clients in arbitrary order—wrong when multiple terminals are attached to the same session.

**Efficient pattern:** Combine queries into single call:
```rust
// Instead of two calls for session + tty:
run_tmux_command(&["display-message", "-p", "#S\t#{client_tty}"])
// Then split on '\t'
```

## Swift

### Never Use Bundle.module
Use `ResourceBundle.url(forResource:withExtension:)` instead—crashes in distributed builds.

### SwiftUI View Reuse
Use `.id(uniqueValue)` to force fresh instances for toasts/alerts.

### Swift 6 Concurrency
Views initializing `@MainActor` types need `@MainActor` on the view struct.

### Rust↔Swift Timestamps
Use custom decoder with `.withFractionalSeconds`. See `ShellStateStore.swift`.

### UniFFI Task Shadows Swift Task
UniFFI bindings define a `Task` type shadowing Swift's `_Concurrency.Task`. Always use `_Concurrency.Task` explicitly. Symptom: "cannot specialize non-generic type 'Task'" errors. Affected: `TerminalLauncher.swift`, `ShellStateStore.swift`.

### Rust Activation Resolver Is Sole Path
Terminal activation now uses a single path: Rust decides (`engine.resolveActivation()`), Swift executes (`executeActivationAction()`). The legacy Swift-only strategy methods were removed in Jan 2026. All decision logic lives in `core/hud-core/src/activation.rs` (25+ unit tests).

### Terminal Activation: TTY Discovery First
In `activateHostThenSwitchTmux`, always try TTY discovery before Ghostty-specific handling. Without this, Ghostty gets activated even when tmux is running in iTerm.

**Correct order:**
1. Try TTY discovery (works for iTerm, Terminal.app)
2. If TTY found → switch tmux, done
3. If TTY not found AND Ghostty running → use Ghostty window-count strategy
4. Otherwise → trigger fallback

### Shell Selection: Tmux Priority When Client Attached
When multiple shells exist at the same path in `shell-cwd.json` (e.g., one tmux shell, two direct shells), the Rust `find_shell_at_path()` function uses this priority order:

1. **Live shells** beat dead shells
2. **Tmux shells** beat non-tmux shells (only when tmux client is attached)
3. **Most recent timestamp** as tiebreaker

**Why this matters:** Without tmux priority, timestamp alone determines shell selection. If a user recently cd'd into a directory in a non-tmux shell, that shell gets selected—resulting in `ActivateByTty` instead of `ActivateHostThenSwitchTmux`. The tmux session then fails to switch.

**Key insight:** "Tmux client attached" is a strong signal the user is actively using tmux and wants session switching. See `activation.rs:find_shell_at_path()` and test `test_prefers_tmux_shell_when_client_attached_even_if_older`.

### Tmux Context: "Has Client" Means ANY Client
When building `TmuxContextFfi` for Rust, `hasAttachedClient` must mean "any tmux client exists anywhere" NOT "client attached to this specific session."

**Wrong:**
```swift
hasTmuxClientAttachedToSession(targetSession)  // ❌ Returns false if viewing different session
```

**Right:**
```swift
hasTmuxClientAttached()  // ✅ Returns true if ANY client exists
```

**Why this matters:** If you're viewing session A and click project B, the old code reported "no client" (because no client was on B's session). Rust then decided `LaunchTerminalWithTmux` → spawned new windows.

**Semantic:** "Has attached client" answers "can we use `tmux switch-client`?" If ANY client exists, we can switch it to the target session. Only launch new terminal when NO clients exist at all.

### Shell Escaping Utilities
`TerminalLauncher.swift` provides two escaping functions for shell injection prevention:
- `shellEscape()` — Single-quote escaping for shell arguments (e.g., `foo'bar` → `'foo'\''bar'`)
- `bashDoubleQuoteEscape()` — Escape `\`, `"`, `$`, `` ` `` for double-quoted strings

Always use these when interpolating user-controlled values (like tmux session names) into shell commands.

## State & Locks

### Session-Based Locks (v4)
Locks keyed by `{session_id}-{pid}`, NOT path hash. Multiple concurrent sessions per directory allowed. Legacy MD5-hash locks (`{hash}.lock`) are stale—delete them. See `create_session_lock()` in `lock.rs`.

### Exact-Match Only for State Resolution
Lock and session matching uses exact path comparison. No child→parent inheritance. `/project/src` lock does NOT make `/project` active. Monorepo packages track independently.

### Diagnosing Stale Locks
Check `~/.capacitor/sessions/*.lock`. Session locks have UUID format. MD5-hash locks (32 hex chars) are legacy/stale. Use `ps -p {pid}` to verify lock holder.

### Focus Override Behavior
Manual override persists until clicking different project OR navigating to directory with active session. Navigating to project without session keeps focus (prevents timestamp racing). See `ActiveProjectResolver.swift`.

### Lock Dir Read Errors
`count_other_session_locks()` returns `usize::MAX` on I/O errors (not 0). Non-zero count preserves session record. Returning 0 would incorrectly tombstone active sessions. See `lock.rs:682-697`.

## Hooks

### Async Hooks Need Both Fields
Claude Code requires BOTH `"async": true` AND `"timeout": 30`. Missing either causes validation failure. Check `~/.claude/settings.json` for malformed entries. See `setup.rs:422-426`.

### Testing Unhealthy Hook States
App auto-repairs hooks at startup. Claude Code interactions keep heartbeat fresh. To test SetupStatusCard visibility:
1. Remove both `~/.local/bin/hud-hook` AND `apps/swift/.build/.../hud-hook` to prevent auto-repair, OR
2. Add `disableAllHooks: true` to `~/.claude/settings.json`

Heartbeat check returns `Healthy` if any active lock exists, even with stale heartbeat. See `check_hook_health()` in `engine.rs:782-787`.

## Activity Tracking

### Hook Format Detection in ActivityStore::load()
The activity store supports two formats: hook format (`"files"` array from hud-hook) and native format (`"activity"` array with `project_path`). When loading, the code checks for hook format markers before attempting native format parsing.

**Why this matters:** Hook format JSON successfully deserializes as native format (due to `serde(default)`), but with empty `activity` arrays. Without explicit hook marker detection, file activity data gets silently discarded, breaking the activity-based fallback for state resolution.

**Related test:** `loads_hook_format_with_boundary_detection` in `activity.rs`.

## Accepted Tradeoffs

### Cleanup Race Condition
`run_startup_cleanup()` uses read-modify-write without file locking. Concurrent hook events during cleanup could be lost. Accepted because: (1) cleanup runs only at app launch, (2) window is milliseconds, (3) lost events self-heal. See `cleanup.rs`.
