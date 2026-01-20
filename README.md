# Claude HUD

A native macOS dashboard for [Claude Code](https://claude.ai/claude-code) — see what Claude is doing across all your projects at a glance.

## What is Claude HUD?

Claude HUD is a **sidecar app** that gives you real-time visibility into your Claude Code sessions. Instead of switching between terminal windows to check if Claude is done thinking, HUD shows you the state of every project in one place.

**Key idea:** HUD reads from your existing Claude Code installation (`~/.claude/`) and invokes the CLI for AI features. No separate API key needed.

## Features

### Real-Time Session Tracking
See what Claude is doing right now:
- **Working** — Claude is generating a response
- **Ready** — Waiting for your input
- **Compacting** — Context is being summarized
- **Idle** — No active session

### Project Dashboard
- Pin your active projects for quick access
- Drag to reorder by priority
- See recent activity summaries
- One-click to open project in terminal

### Idea Capture
Capture ideas without breaking your flow:
- Full-canvas modal overlay (⌘+I from any project)
- AI-powered enrichment (priority, effort, tags)
- Per-project idea queues with drag-to-reorder
- Markdown storage — your ideas stay yours

### Dual Layout Modes
- **Vertical** — Full dashboard with navigation and details
- **Dock** — Compact horizontal strip for screen edge docking

### Project Statistics
- Token usage (input, output, cache)
- Model distribution (Opus/Sonnet/Haiku)
- Session history and activity timeline

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Claude Code** installed and configured
- **Rust 1.77+** and **Swift 5.9+** (for building from source)

## Installation

### From Release (Recommended)

Download the latest DMG from [Releases](https://github.com/petekp/claude-hud/releases), open it, and drag Claude HUD to Applications.

The app includes Sparkle for automatic updates.

### Building from Source

```bash
# Clone the repository
git clone https://github.com/petekp/claude-hud.git
cd claude-hud

# Build Rust core and Swift app
cargo build -p hud-core --release
cd apps/swift
swift build -c release
swift run
```

## Setup

### Enable Session Tracking

Claude HUD tracks session state via Claude Code hooks. To enable:

1. Copy the hook script:
   ```bash
   cp ~/.claude/scripts/hud-state-tracker.sh ~/.claude/scripts/
   chmod +x ~/.claude/scripts/hud-state-tracker.sh
   ```

2. Add hooks to your Claude Code settings (`~/.claude/settings.json`):
   ```json
   {
     "hooks": {
       "SessionStart": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh SessionStart" }],
       "UserPromptSubmit": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh UserPromptSubmit" }],
       "Stop": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh Stop" }],
       "PreCompact": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh PreCompact" }]
     }
   }
   ```

3. Restart any active Claude Code sessions.

### Add Projects

Click the **+** button in HUD to add project folders. HUD will detect Claude Code projects by looking for:
- `CLAUDE.md` file
- `.claude/` directory
- `.git/` directory
- `package.json`, `Cargo.toml`, etc.

## Architecture

```
claude-hud/
├── core/hud-core/       # Rust business logic
│   └── src/
│       ├── engine.rs    # FFI facade (UniFFI)
│       ├── sessions.rs  # Session state detection
│       ├── projects.rs  # Project management
│       ├── ideas.rs     # Idea capture system
│       └── stats.rs     # Token usage parsing
│
├── apps/swift/          # SwiftUI macOS app
│   └── Sources/ClaudeHUD/
│       ├── Models/      # AppState, managers
│       ├── Views/       # UI components
│       └── Bridge/      # UniFFI bindings
│
└── scripts/             # Build and release tools
```

**Design principle:** HUD is a sidecar, not a replacement. It leverages Claude Code's existing infrastructure rather than duplicating it.

## Development

### Quick Start

```bash
# Format and lint Rust
cargo fmt && cargo clippy -- -D warnings

# Run Rust tests
cargo test

# Build and run the app
cargo build -p hud-core --release
cd apps/swift && swift run
```

### Useful Scripts

```bash
# Restart the app (rebuilds and relaunches)
./scripts/restart-app.sh

# Run all tests (Rust + Swift + bash)
./scripts/run-tests.sh

# Build distribution ZIP
./scripts/build-distribution.sh

# Create DMG installer
./scripts/create-dmg.sh
```

### Project Structure

| Directory | Purpose |
|-----------|---------|
| `core/hud-core/` | Rust library with business logic |
| `apps/swift/` | SwiftUI application |
| `.claude/docs/` | Internal documentation |
| `docs/architecture-decisions/` | ADRs |
| `scripts/` | Build, test, and release automation |
| `tests/` | Integration tests |

## How Session Tracking Works

1. **Hooks** — Claude Code fires events (SessionStart, Stop, etc.) that run a shell script
2. **State file** — The script writes JSON to `~/.capacitor/sessions.json`
3. **Lock files** — Claude Code creates locks at `~/.claude/sessions/{hash}.lock/`
4. **HUD reads** — The app polls these files and resolves the current state

The state resolver handles edge cases like:
- Multiple sessions in the same project
- Crashed sessions (stale locks with dead PIDs)
- Monorepo projects with nested paths

## Data Storage

Capacitor uses two namespaces:

**`~/.capacitor/`** — owned by Capacitor:
```
~/.capacitor/
├── config.json                 # Pinned projects
├── sessions.json               # Current session states
├── stats-cache.json            # Token usage cache
├── summaries.json              # Session summaries
└── projects/{encoded-path}/    # Per-project data (ideas, order)
```

**`~/.claude/`** — owned by Claude Code CLI (read-only for Capacitor):
```
~/.claude/
├── sessions/                   # Lock directories (created by Claude)
└── projects/                   # Session transcripts
```

## Contributing

Contributions are welcome! Please:

1. Run `cargo fmt` and `cargo clippy -- -D warnings` before committing
2. Add tests for new functionality
3. Update documentation for user-facing changes
4. Follow the existing code style

See `.claude/docs/development-workflows.md` for detailed setup instructions.

## License

MIT

## Acknowledgments

Built with:
- [UniFFI](https://mozilla.github.io/uniffi-rs/) — Rust to Swift bindings
- [Sparkle](https://sparkle-project.org/) — macOS software updates
- [Variablur](https://github.com/daprice/Variablur) — Variable blur effects

---

*Claude HUD is an independent project and is not affiliated with Anthropic.*
