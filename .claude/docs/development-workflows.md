# Development Workflows

Detailed procedures for common development tasks in Claude HUD.

## Quick Start

```bash
cargo build -p hud-core --release  # Build Rust library first
cd apps/swift
swift build       # Debug build
swift run         # Run the app
```

## Common Commands

### Rust Core (from repo root)

```bash
cargo check --workspace           # Check all crates
cargo build --workspace           # Build all crates
cargo build -p hud-core --release # Build core for Swift
cargo fmt                         # Format code (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Run all tests
```

### Swift App (from `apps/swift/`)

```bash
swift build             # Debug build
swift build -c release  # Release build
swift run               # Run the app
```

### Building for Distribution

```bash
cargo build -p hud-core --release
cd apps/swift
swift build -c release
# Create .app bundle manually or use xcodebuild
```

## Regenerating Swift Bindings

**IMPORTANT:** The project has two locations for `hud_core.swift`:
1. `apps/swift/bindings/` - where UniFFI generates bindings
2. `apps/swift/Sources/ClaudeHUD/Bridge/` - where Swift actually compiles from

You must update **both** locations and clean build artifacts after Rust API changes.

```bash
# 1. Build the release library
cargo build -p hud-core --release

# 2. Generate bindings from the built library
cd core/hud-core
cargo run --bin uniffi-bindgen generate --library ../../target/release/libhud_core.dylib --language swift --out-dir ../../apps/swift/bindings/

# 3. Copy bindings to where Swift compiles from
cp ../../apps/swift/bindings/hud_core.swift ../../apps/swift/Sources/ClaudeHUD/Bridge/

# 4. Clean Swift build artifacts (required to avoid checksum mismatch)
cd ../../apps/swift
rm -rf .build ClaudeHUD.app

# 5. Rebuild
swift build
```

### Troubleshooting Checksum Mismatch

If you see `UniFFI API checksum mismatch: try cleaning and rebuilding your project`:

1. **Check for stale Bridge file:** The `Sources/ClaudeHUD/Bridge/hud_core.swift` may be outdated
2. **Check for stale app bundle:** Remove `apps/swift/ClaudeHUD.app` if it exists
3. **Check for stale .build cache:** Remove `apps/swift/.build` directory
4. **Verify dylib is fresh:** `ls -la target/release/libhud_core.dylib` should show recent timestamp

The checksums are embedded in both the dylib and Swift bindings. They must match exactly at runtime.

## Modifying Hook State Tracking

Hook handling is implemented entirely in Rust (`core/hud-hook/`).

**Architecture:**
- `core/hud-hook/src/main.rs` — Entry point for hook binary
- `core/hud-hook/src/handle.rs` — Main hook handler (state transitions)
- `core/hud-hook/src/lock_holder.rs` — Lock management daemon
- `core/hud-core/src/state/` — Shared state types and resolution logic

**To modify hook behavior:**

1. **Read the docs first:**
   - `core/hud-core/src/state/types.rs` — Canonical hook→state mapping
   - `docs/claude-code/hooks.md` — Claude Code event payloads

2. **Make your changes** in the Rust crate (`core/hud-hook/src/`)
   - State transitions: `handle.rs`
   - Lock behavior: `lock_holder.rs`

3. **Build and install:**
   ```bash
   cargo build -p hud-hook --release
   cp target/release/hud-hook ~/.local/bin/
   ```

4. **Test manually** with a real Claude session:
   - Trigger the specific event you modified
   - Check debug log: `tail -20 ~/.capacitor/hud-hook-debug.log`
   - Verify state in HUD app

5. **Sync hooks** to ensure installed version matches repo:
   ```bash
   ./scripts/sync-hooks.sh --force
   ```

## Modifying Statistics Parsing

- Update regex patterns in `parse_stats_from_content()` (`core/hud-core/src/stats.rs`)
- Update `ProjectStats` struct in `core/hud-core/src/types.rs`
- Delete `~/.capacitor/stats-cache.json` to force recomputation

## Adding Project Type Detection

- Modify `has_project_indicators()` (`core/hud-core/src/projects.rs`)
- Add file/directory checks for new project type

## Adding a New SwiftUI View

1. **Create view:** Add SwiftUI view in `apps/swift/Sources/ClaudeHUD/Views/`
2. **Update state:** Add published properties to `AppState.swift` if needed
3. **Wire up:** Add navigation in `ContentView.swift`
