# Capacitor

Native macOS dashboard for Claude Code—displays project statistics, session states, and helps you context-switch between projects instantly.

## Stack

- **Platform** — Apple Silicon, macOS 14+
- **Swift App** (`apps/swift/`) — SwiftUI, 120Hz ProMotion
- **Rust Core** (`core/hud-core/`) — Business logic via UniFFI bindings

## Commands

```bash
# Build and run
cargo build -p hud-core --release && cd apps/swift && swift build && swift run

# Rust
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Swift (from apps/swift/)
swift build && swift run          # Build and run

# Restart app (pre-approved)
./scripts/dev/restart-app.sh
```

**First-time setup:** `./scripts/dev/setup.sh`

## Structure

```
capacitor/
├── core/hud-core/src/      # Rust: engine.rs, sessions.rs, projects.rs, ideas.rs
├── core/hud-hook/src/      # Rust: CLI hook handler (handle.rs, cwd.rs)
├── apps/swift/Sources/     # Swift: App.swift, Models/, Views/, Theme/
└── .claude/docs/           # Architecture docs, feature specs
```

## Core Principle: Sidecar Architecture

**Capacitor observes Claude Code—it doesn't replace it.**

- Read from `~/.claude/` — transcripts, config (Claude's namespace)
- Write to `~/.capacitor/` — session state, shell tracking (our namespace)
- Never call Anthropic API directly — invoke `claude` CLI instead

## Key Files

| Purpose | Location |
|---------|----------|
| HudEngine facade | `core/hud-core/src/engine.rs` |
| Session state | `core/hud-core/src/sessions.rs` |
| Hook event config | `core/hud-core/src/setup.rs` |
| Shell CWD tracking | `core/hud-hook/src/cwd.rs` |
| Terminal activation | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/hud_core.swift` |

## State Tracking

Hooks → `~/.capacitor/sessions.json` → Capacitor reads

- **State file:** `~/.capacitor/sessions.json`
- **Locks:** `~/.capacitor/sessions/{session_id}-{pid}.lock/`
- **Shell CWD:** `~/.capacitor/shell-cwd.json`
- **Hook binary:** `~/.local/bin/hud-hook`

**Resolution:** Lock existence with live PID is authoritative, regardless of timestamp.

## Gotchas

- **Always run `cargo fmt`** — CI enforces formatting; pre-commit hook catches this
- **Dev builds need dylib** — After Rust rebuilds: `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`
- **Never use `Bundle.module`** — Use `ResourceBundle.url(forResource:withExtension:)` instead (crashes in distributed builds)
- **SwiftUI view reuse** — Use `.id(uniqueValue)` to force fresh instances for toasts/alerts
- **Swift 6 concurrency** — Views initializing `@MainActor` types need `@MainActor` on the view struct
- **Rust↔Swift timestamps** — Use custom decoder with `.withFractionalSeconds` (see `ShellStateStore.swift`)
- **Session-based locks (v4)** — Locks are keyed by `{session_id}-{pid}`, NOT path hash. This allows multiple concurrent sessions in the same directory. Each process gets its own lock. Legacy MD5-hash locks (`{hash}.lock`) are stale and should be deleted. See `create_session_lock()` in `lock.rs`.
- **Exact-match-only for state resolution** — Lock and session record matching uses exact path comparison only. No child→parent inheritance. A lock at `/project/src` does NOT make `/project` show as active. Monorepo packages track state independently from their parent.
- **hud-hook must point to dev build during development** — The symlink at `~/.local/bin/hud-hook` must point to `target/release/hud-hook` (not the app bundle) to pick up code changes. After Rust changes: rebuild (`cargo build -p hud-hook --release`) then verify symlink target. Stale hooks create stale locks.
- **Diagnosing stale locks** — If projects show wrong state, check `~/.capacitor/sessions/*.lock`. Session-based locks have UUID format (`{session_id}-{pid}.lock`). MD5-hash locks (32 hex chars like `abc123...def.lock`) are legacy/stale—delete them. Use `ps -p {pid}` to verify lock holder is alive.
- **Focus override clears only for active sessions** — When user clicks a project, the manual override persists until they click a different project OR navigate to a directory with an active Claude session. Navigating to a project without a session keeps focus on the override (prevents timestamp racing). See `ActiveProjectResolver.swift`.
- **Hook binary must be symlinked, not copied** — Copying adhoc-signed Rust binaries to `~/.local/bin/` triggers macOS Gatekeeper SIGKILL (exit 137). The binary works fine when run from `target/release/` but dies when copied. Fix: use symlink (`ln -s target/release/hud-hook ~/.local/bin/hud-hook`). See `scripts/sync-hooks.sh`.
- **Async hooks require both fields** — Claude Code's hook validation requires async hooks to have BOTH `"async": true` AND `"timeout": 30`. Missing either field causes "Settings configured" to show red. If hooks stop working after an upgrade, check `~/.claude/settings.json` for malformed hook entries. See `setup.rs:422-426`.
- **Cleanup race condition (accepted)** — `run_startup_cleanup()` follows read-modify-write on `sessions.json` without file locking. Concurrent hook events arriving during cleanup could be lost. This risk is accepted because: (1) cleanup runs only at app launch (low frequency), (2) the window is small (milliseconds), (3) lost events self-heal on next hook event. See `cleanup.rs`.
- **Lock dir read errors use fail-safe sentinel** — `count_other_session_locks()` returns `usize::MAX` (not 0) when `read_dir` fails for reasons other than `NotFound`. The caller treats any non-zero count as "preserve session record." Returning 0 on I/O errors would incorrectly tombstone active sessions. See `lock.rs:682-697`.
- **hud-hook logging guard must be held, not forgotten** — `logging::init()` returns `Option<WorkerGuard>` which must be held in `main()` scope. The guard's `Drop` implementation flushes buffered logs. Using `std::mem::forget()` prevents final log entries from being written. See `logging.rs` and `main.rs:70`.
- **UniFFI `Task` shadows Swift concurrency `Task`** — The UniFFI-generated bindings in `hud_core.swift` define a `Task` type that shadows Swift's `_Concurrency.Task`. Always use `_Concurrency.Task` when creating async tasks or calling `Task.sleep()`. Affected files: `TerminalLauncher.swift`, `ShellStateStore.swift`. Symptom: "cannot specialize non-generic type 'Task'" errors.
- **Activation strategy methods must return actual success** — In `TerminalLauncher.swift`, strategy methods like `activateKittyRemote` must return the actual result of their activation attempt (not always `true`). Returning `true` unconditionally breaks the fallback chain in `executeStrategy()`. The fallback only triggers when primary returns `false`.

## Documentation

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Release procedures | `.claude/docs/release-guide.md` |
| Architecture deep-dive | `.claude/docs/architecture-overview.md` |
| Debugging | `.claude/docs/debugging-guide.md` |
| Terminal support matrix | `.claude/docs/terminal-switching-matrix.md` |
| Side effects reference | `.claude/docs/side-effects-map.md` |

## Plans

Implementation plans in `.claude/plans/` with status prefixes: `ACTIVE-`, `DRAFT-`, `REFERENCE-`
