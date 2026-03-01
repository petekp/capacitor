# Capacitor

A fun, glanceable, bring-your-own terminal UI for navigating multiple coding agent sessions in parallel.

## Stack

- **Platform** — Apple Silicon, macOS 14+
- **Swift App** (`apps/swift/`) — SwiftUI, 120Hz ProMotion
- **Rust Core** (`core/capacitor-core/`) — Business logic via UniFFI bindings

## Commands

```bash
# Quick iteration (most common)
./scripts/dev/restart-alpha-stable.sh     # DEFAULT for agents: switch to alpha+stable, then relaunch
./scripts/dev/restart-current.sh          # Only when explicitly preserving an already-selected context
./scripts/dev/restart-alpha-frontier.sh   # Use only when frontier is explicitly requested

# Rust (when changing core/)
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Full rebuild (after Rust changes)
cargo build -p capacitor-core --release && cd apps/swift && swift build
# Advanced launch control:
./scripts/dev/restart-app.sh --channel alpha --profile stable
```

**First-time setup:** `./scripts/dev/setup.sh`

## Structure

```
capacitor/
├── core/capacitor-core/src/      # Rust runtime: ingest/, reduce/, query/, activate/, storage/
├── core/hud-hook/src/            # Rust CLI hook handler
├── apps/swift/Sources/Capacitor/ # Swift app shell + views + runtime client
└── .claude/docs/                 # Local engineering runbooks
```

## Core Principle: Runtime Snapshot Architecture

**Capacitor observes Claude Code—it doesn't replace it.**

- Read from `~/.claude/` — transcripts, config (Claude's namespace)
- Write to `~/.capacitor/` — runtime snapshot, logs, and state (our namespace)
- Never call Anthropic API directly — invoke `claude` CLI instead

## Key Files

| Purpose | Location |
|---------|----------|
| CoreRuntime facade | `core/capacitor-core/src/lib.rs` |
| Runtime types | `core/capacitor-core/src/runtime_types.rs` |
| Runtime setup + validation | `core/capacitor-core/src/runtime_setup.rs` |
| Shell CWD tracking | `core/hud-hook/src/cwd.rs` |
| Terminal activation | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift` |

## State Tracking

Hooks → **hud-hook** → **capacitor-core snapshot** → Swift reads runtime snapshot

- **Runtime snapshot:** `~/.capacitor/runtime/app_snapshot.json`
- **Runtime logs/artifacts:** `~/.capacitor/runtime/`
- **Hook binary:** `~/.local/bin/hud-hook`

**Resolution:** runtime sessions and shell state are authoritative.

## Telemetry

For coding-agent runtime debugging, use the canonical diagnostic CLI:

```bash
./scripts/dev/agent-observe.sh diagnose   # One-shot full diagnostics
./scripts/dev/agent-observe.sh check      # Validate paths
./scripts/dev/agent-observe.sh health     # Runtime health
./scripts/dev/agent-observe.sh freshness  # Snapshot staleness
```

Full command reference: `./scripts/dev/agent-observe.sh help`
Debugging guide: `.claude/docs/debugging-guide.md`

Optional browser UI: `node scripts/transparent-ui-server.mjs` (localhost:9133)

## Common Gotchas

- **Rebuild after Swift changes** — Run `./scripts/dev/restart-alpha-stable.sh` by default to verify changes compile and render in stable profile (use frontier only when explicitly requested)
- **Always run `cargo fmt`** — CI enforces formatting
- **Dev builds need dylib** — After Rust rebuilds: `cp target/release/libcapacitor_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`
- **Hook symlink, not copy** — Use `ln -s target/release/hud-hook ~/.local/bin/hud-hook` (copying triggers Gatekeeper SIGKILL)
- **UniFFI Task shadows Swift Task** — Use `_Concurrency.Task` explicitly in async code
- **Swift app links release Rust core** — After any `core/capacitor-core` change, run `cargo build -p capacitor-core --release` before `swift run`

**Full gotchas reference:** `.claude/docs/gotchas.md`
