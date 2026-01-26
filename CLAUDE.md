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
- **Locks:** `~/.capacitor/sessions/{hash}.lock/`
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

## Documentation

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Release procedures | `.claude/docs/release-guide.md` |
| Architecture deep-dive | `.claude/docs/architecture-overview.md` |
| Debugging | `.claude/docs/debugging-guide.md` |
| Terminal support matrix | `.claude/docs/terminal-switching-matrix.md` |

## Plans

Implementation plans in `.claude/plans/` with status prefixes: `ACTIVE-`, `DRAFT-`, `REFERENCE-`
