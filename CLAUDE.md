# Capacitor

Native macOS dashboard for Claude Code—displays project statistics, session states, and helps you context-switch between projects instantly.

## Stack

- **Platform** — Apple Silicon only (M1/M2/M3/M4), macOS 14+
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

# Pre-commit hook (one-time setup)
ln -sf ../../scripts/dev/pre-commit .git/hooks/pre-commit

# Swift (from apps/swift/)
swift build                       # Debug build
swift run                         # Run app

# Restart app (use this script - pre-approved in permissions)
/Users/petepetrash/Code/capacitor/scripts/dev/restart-app.sh
```

## First-Time Setup

New to the project? Run the setup script to validate your environment and build:

```bash
./scripts/dev/setup.sh
```

This checks macOS 14+, installs Xcode CLI tools and Rust if missing, builds the Rust core with proper dylib linkage, generates UniFFI bindings, builds the Swift app, and installs pre-commit hooks.

**When to use:** Fresh clone, new machine, or after major dependency changes. For normal development iteration, use `./scripts/dev/restart-app.sh` instead.

## Distribution

Release builds require notarization for Gatekeeper approval. Scripts handle the full workflow.

### Quick Release

```bash
./scripts/release/bump-version.sh patch          # Bump version
./scripts/release/build-distribution.sh --skip-notarization  # Build without notarize
./scripts/release/verify-app-bundle.sh           # VERIFY before release!
./scripts/release/build-distribution.sh          # Full build + notarize
./scripts/release/create-dmg.sh                  # Create + notarize DMG
./scripts/release/generate-appcast.sh            # Update Sparkle feed

gh release create v0.x.x \
  dist/Capacitor-v0.x.x-arm64.dmg \
  dist/Capacitor-v0.x.x-arm64.zip \
  dist/appcast.xml \
  --title "Capacitor v0.x.x" \
  --notes "Release notes"
```

**IMPORTANT:** See `docs/PRE_RELEASE_CHECKLIST.md` for the full verification checklist. Test from an isolated location (`/tmp`) before releasing—dev environment masks issues.

### Release Setup (One-Time)

```bash
./scripts/sync-hooks.sh --force         # Install hook binary and wrapper script
```

Notarization credentials:
```bash
xcrun notarytool store-credentials "Capacitor" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

See `docs/NOTARIZATION_SETUP.md` for full guide.

### Gotchas

- **SwiftUI view reuse breaks re-triggering** — When showing the same content repeatedly (toasts, alerts), use `.id(uniqueValue)` to force SwiftUI to create a fresh view instance. Without this, `onAppear` won't re-fire and animations won't replay.
- **Dev builds need dylib copied** — After bootstrap or Rust rebuilds, run `cp target/release/libhud_core.dylib apps/swift/.build/arm64-apple-macosx/debug/`. Without this, the app crashes with "Library not loaded: @rpath/libhud_core.dylib". The bootstrap script handles this automatically.
- **Sparkle.framework must be bundled** — Swift Package Manager links but doesn't embed frameworks. The build script copies it to `Contents/Frameworks/` and signs it.
- **Private repos break auto-updates** — Sparkle fetches appcast.xml anonymously; private GitHub repos return 404. Repo must be public for updates to work.
- **Always run `cargo fmt`** — CI enforces formatting; commit will fail otherwise.
- **UniFFI bindings must be regenerated for releases** — The build script auto-regenerates Swift bindings from the Rust dylib. If you see "UniFFI API checksum mismatch" crashes, the bindings are stale. The script handles this, but manual builds need: `cargo run --bin uniffi-bindgen generate --library target/release/libhud_core.dylib --language swift --out-dir apps/swift/bindings/` then copy to `Sources/Capacitor/Bridge/`.
- **SPM resource bundle must be copied** — `Bundle.module` only works when running via SPM. The build script copies `Capacitor_Capacitor.bundle` to `Contents/Resources/` so resources load correctly in distributed builds.
- **Never use `Bundle.module` directly** — Use `ResourceBundle.url(forResource:withExtension:)` instead. `Bundle.module` is SPM-generated code that crashes in distributed builds. The `ResourceBundle` helper finds resources in both dev and release contexts.
- **ZIP archives must exclude AppleDouble files** — macOS extended attributes create `._*` files that break code signatures. The build script uses `ditto --norsrc --noextattr` to prevent this. If users see "app is damaged", check for `._*` files in the extracted ZIP.
- **Rust ISO8601 timestamps need custom Swift decoder** — Rust's `chrono` writes timestamps with microsecond precision (`2026-01-24T22:34:54.629248Z`), but Swift's default `.iso8601` decoder only handles second-precision. Use a custom decoder with `ISO8601DateFormatter` configured with `.withFractionalSeconds`. See `ShellStateStore.swift` for the pattern.

## Structure

```
capacitor/
├── core/hud-core/src/      # Rust: engine.rs, types.rs, stats.rs, projects.rs, sessions.rs
├── core/hud-hook/src/      # Rust: CLI hook handler binary (replaces bash script logic)
├── apps/swift/Sources/     # Swift: App.swift, Models/, Views/, Theme/
├── .claude/docs/           # Architecture docs, feature specs
└── docs/                   # Claude Code CLI docs, ADRs
```

## Core Principle: Sidecar Architecture

**Capacitor is a sidecar that powers up your existing Claude Code workflow—not a standalone app.**

- Read from `~/.claude/` — config, plugins, transcripts (Claude's namespace)
- Write to `~/.capacitor/` — session state, file activity (Capacitor's namespace)
- Invoke the `claude` CLI — for AI features, call CLI rather than API directly
- Respect existing workflows — Capacitor observes and surfaces, doesn't replace

See [ADR-003: Sidecar Architecture Pattern](docs/architecture-decisions/003-sidecar-architecture-pattern.md).

## Key Files

| Purpose | Location |
|---------|----------|
| HudEngine facade | `core/hud-core/src/engine.rs` |
| Shared types | `core/hud-core/src/types.rs` |
| Session state detection | `core/hud-core/src/sessions.rs` |
| Shell CWD tracking | `core/hud-hook/src/cwd.rs` |
| Swift app state | `apps/swift/Sources/Capacitor/Models/AppState.swift` |
| Shell state store | `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift` |
| Active project resolver | `apps/swift/Sources/Capacitor/Services/ActiveProjectResolver.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/hud_core.swift` |

## State Tracking

Hooks track local Claude Code sessions → state file → Capacitor reads.

**Paths:**
- **State file:** `~/.capacitor/sessions.json`
- **Lock directory:** `~/.capacitor/sessions/`
- **Hook binary:** `~/.local/bin/hud-hook`

**Resolution principle:** Lock existence is authoritative. When a lock exists with a live PID, trust the recorded state regardless of timestamp freshness. This handles tool-free text generation where no hook events fire for extended periods.

**Architecture:** See `core/hud-hook/src/main.rs` for the hook binary implementation and `core/hud-core/src/state/` for state architecture.

**Hook Setup:** Use `./scripts/sync-hooks.sh` to install the binary, then run the app and click "Fix All" in the setup card to configure hooks in `~/.claude/settings.json`.

**Async Hooks:** Most hooks run with `async: true` so they don't block Claude Code execution. Only `SessionEnd` is synchronous to ensure cleanup completes before exit. Hooks have a 30-second timeout.

### Shell Integration

Shell precmd hooks push CWD changes to Capacitor for ambient project awareness.

**Paths:**
- **Current state:** `~/.capacitor/shell-cwd.json` — Active shell sessions and their CWD
- **History log:** `~/.capacitor/shell-history.jsonl` — Append-only CWD change history (30-day retention)

**How it works:** Shell hooks call `hud-hook cwd "$PWD" "$$" "$TTY"` on every prompt. The hook updates state atomically, cleans up dead PIDs, and detects parent app (Cursor/VSCode/terminal). Swift's `ActiveProjectResolver` combines Claude sessions and shell CWD to determine the active project.

**Performance:** Target <15ms execution. Uses native macOS `libproc` APIs instead of subprocess calls for process tree walking.

**Shell setup:** See the Setup card in the app, which provides shell-specific snippets for zsh, bash, and fish.

## Documentation Index

| Need | Document |
|------|----------|
| Development workflows | `.claude/docs/development-workflows.md` |
| Detailed architecture | `.claude/docs/architecture-overview.md` |
| Debugging procedures | `.claude/docs/debugging-guide.md` |
| Idea capture specs | `.claude/docs/idea-capture-specs.md` |
| Architecture decisions | `docs/architecture-decisions/` |
| Project evolution | `AGENT_CHANGELOG.md` |

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
- **UniFFI bindings:** Must update both `apps/swift/bindings/` and `apps/swift/Sources/Capacitor/Bridge/` after Rust API changes (see development-workflows.md)
