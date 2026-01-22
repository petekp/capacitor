# Claude HUD

Native macOS dashboard for Claude Code—displays project statistics, session states, and helps you context-switch between projects instantly.

## Stack

- **Swift App** (`apps/swift/`) — SwiftUI, macOS 14+, 120Hz ProMotion
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
swift build                       # Debug build
swift run                         # Run app

# Restart app (use this script - pre-approved in permissions)
/Users/petepetrash/Code/claude-hud/scripts/dev/restart-app.sh
```

## Distribution

Release builds require notarization for Gatekeeper approval. Scripts handle the full workflow.

### Quick Release

```bash
./scripts/release/bump-version.sh patch          # Bump version
./scripts/release/build-distribution.sh          # Build + sign + notarize ZIP
./scripts/release/create-dmg.sh                  # Create + notarize DMG
./scripts/release/generate-appcast.sh            # Update Sparkle feed

gh release create v0.x.x \
  dist/ClaudeHUD-v0.x.x-arm64.dmg \
  dist/ClaudeHUD-v0.x.x-arm64.zip \
  dist/appcast.xml \
  --title "Claude HUD v0.x.x" \
  --notes "Release notes"
```

### First-Time Setup

```bash
./scripts/sync-hooks.sh --force         # Install hook binary and wrapper script
```

Notarization credentials (one-time):
```bash
xcrun notarytool store-credentials "ClaudeHUD" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

See `docs/NOTARIZATION_SETUP.md` for full guide.

### Gotchas

- **Sparkle.framework must be bundled** — Swift Package Manager links but doesn't embed frameworks. The build script copies it to `Contents/Frameworks/` and signs it.
- **Private repos break auto-updates** — Sparkle fetches appcast.xml anonymously; private GitHub repos return 404. Repo must be public for updates to work.
- **Always run `cargo fmt`** — CI enforces formatting; commit will fail otherwise.

## Structure

```
claude-hud/
├── core/hud-core/src/      # Rust: engine.rs, types.rs, stats.rs, projects.rs, sessions.rs
├── core/hud-hook/src/      # Rust: CLI hook handler binary (replaces bash script logic)
├── apps/swift/Sources/     # Swift: App.swift, Models/, Views/, Theme/
├── .claude/docs/           # Architecture docs, feature specs
└── docs/                   # Claude Code CLI docs, ADRs
```

## Core Principle: Sidecar Architecture

**Claude HUD is a sidecar that powers up your existing Claude Code workflow—not a standalone app.**

- Read from `~/.claude/` — config, plugins, transcripts (Claude's namespace)
- Write to `~/.capacitor/` — session state, file activity (HUD's namespace)
- Invoke the `claude` CLI — for AI features, call CLI rather than API directly
- Respect existing workflows — HUD observes and surfaces, doesn't replace

See [ADR-003: Sidecar Architecture Pattern](docs/architecture-decisions/003-sidecar-architecture-pattern.md).

## Key Files

| Purpose | Location |
|---------|----------|
| HudEngine facade | `core/hud-core/src/engine.rs` |
| Shared types | `core/hud-core/src/types.rs` |
| Session state detection | `core/hud-core/src/sessions.rs` |
| Swift app state | `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` |
| UniFFI bindings | `apps/swift/Sources/ClaudeHUD/Bridge/hud_core.swift` |

## State Tracking

Hooks track local Claude Code sessions → state file → HUD reads.

**Paths:**
- **State file:** `~/.capacitor/sessions.json`
- **Lock directory:** `~/.capacitor/sessions/`
- **Hook script:** `~/.claude/scripts/hud-state-tracker.sh`

**Docs live in code:** See `scripts/hud-state-tracker.sh` header for state machine, debugging commands, and troubleshooting. See `core/hud-core/src/state/` for architecture.

**Hook Sync:** The installed hook must match the repo version. Use `./scripts/sync-hooks.sh` to check/update. The `restart-app.sh` script warns about mismatches.

## Documentation Index

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Detailed architecture | `.claude/docs/architecture-overview.md` |
| Debugging procedures | `.claude/docs/debugging-guide.md` |
| Adding CLI agents | `.claude/docs/adding-new-cli-agent-guide.md` |
| Idea capture specs | `.claude/docs/idea-capture-specs.md` |
| Claude Code CLI reference | `docs/claude-code/` |
| Architecture decisions | `docs/architecture-decisions/` |

## Plans

Implementation plans live in `.claude/plans/`. Files are prefixed by status:

- **`ACTIVE-`** — Ready for implementation. Use these.
- **`DRAFT-`** — Work in progress, not ready.
- **`REFERENCE-`** — Vision docs, checklists—not implementation plans.

See `.claude/plans/README.md` for the full index.

## Notes

- **Path encoding:** Project paths use `/` → `-` replacement (e.g., `/Users/peter/Code` → `-Users-peter-Code`)
- **Caching:** Mtime-based invalidation in stats and summaries
- **Platform:** macOS 14+ (Apple Silicon and Intel)
- **UniFFI bindings:** Must update both `apps/swift/bindings/` and `apps/swift/Sources/ClaudeHUD/Bridge/` after Rust API changes (see development-workflows.md)
