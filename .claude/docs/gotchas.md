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

### OSLog Not Captured for Debug Builds

Swift's `Logger` (OSLog) writes to the unified logging system, but for unsigned debug builds run via `swift run`, these logs are NOT captured by `log show` or `log stream`.

**Symptom:** `logger.info()` calls produce no output in Console.app or `log stream --predicate 'subsystem == "com.capacitor.app"'`.

**Workaround:** For debugging sessions requiring telemetry, add explicit stderr output:
```swift
private func telemetry(_ message: String) {
    FileHandle.standardError.write(Data("[TELEMETRY] \(message)\n".utf8))
}
```

Then capture with: `./Capacitor 2> /tmp/telemetry.log &`

**Note:** Remove telemetry helpers before committing—they're for debugging only.

### NSImage Tinting Compositing Order

When tinting an NSImage with a color, the compositing order matters:

**Wrong:** Fill color first, then draw image
```swift
color.set()
rect.fill(using: .destinationIn)  // ❌ Results in blank image
self.draw(in: rect, ...)
```

**Right:** Draw image first with `.copy`, then apply color with `.sourceAtop`
```swift
self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
color.set()
rect.fill(using: .sourceAtop)  // ✅ Colors only where image has content
```

The `.sourceAtop` operation applies color only to non-transparent pixels of the already-drawn image.

### SwiftUI Hit Testing: Conditional Rendering vs Hidden Views

Using `opacity(0)` with `allowsHitTesting(false)` still creates dead zones that block window dragging:

**Wrong:**
```swift
BackButton()
    .opacity(isOnListView ? 0 : 1)
    .allowsHitTesting(!isOnListView)  // ❌ Still blocks window drag
```

**Right:**
```swift
if !isOnListView {
    BackButton()  // ✅ Completely removed from view hierarchy
}
```

**Why:** Even with hit testing disabled, invisible views can interfere with `NSWindow.isMovableByWindowBackground`. Use conditional rendering to fully remove views from the hierarchy.

### SwiftUI Gestures Block NSView Events

SwiftUI's `onTapGesture(count: 2)` intercepts the underlying `mouseDown` events, preventing `NSWindow.performDrag(with:)` from working:

**Problem:** Adding double-click gesture to header breaks window dragging
```swift
.onTapGesture(count: 2) {
    // This intercepts mouseDown, breaking window drag
}
```

**Solutions:**
1. Use `NSViewRepresentable` with `mouseDown` that checks `event.clickCount`
2. Remove the gesture if window dragging is more important
3. Apply gesture only to specific non-draggable areas

### SwiftUI GeometryReader Constraint Loops

Reading from `@ObservedObject` or `@Observable` inside a `GeometryReader` can trigger infinite constraint update loops, crashing the app with `EXC_BREAKPOINT` in `_postWindowNeedsUpdateConstraints`.

**Root cause:** Reading an observable during layout → triggers `objectWillChange` → view update → new layout pass → read observable → infinite loop.

**Symptom:** Crash log shows recursive `_informContainerThatSubviewsNeedUpdateConstraints` calls (10+ levels deep).

**Wrong:**
```swift
var body: some View {
    GeometryReader { geometry in
        let spacing = glassConfig.cardSpacing  // ❌ @ObservedObject read during layout
        LazyHStack(spacing: spacing) { ... }
    }
}
```

**Right:**
```swift
var body: some View {
    // Capture layout values once at body evaluation
    let spacing = glassConfig.cardSpacingRounded  // ✅ Evaluated before layout

    GeometryReader { geometry in
        LazyHStack(spacing: spacing) { ... }
    }
}
```

**Rule:** Always capture observable values into `let` bindings **before** entering `GeometryReader`, `scrollTransition`, or similar layout callbacks.

**See:** `DockLayoutView.swift:20-22`, `ProjectsView.swift:37-41`, crash log `Capacitor-2026-01-29-102502.ips`

### SwiftUI Rapid State Changes Cause Recursive Layout Crashes

When `objectWillChange.send()` is called synchronously during rapid state changes (e.g., killing multiple Claude Code sessions), SwiftUI can crash with `EXC_BREAKPOINT` in `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`.

**Root cause:** Multiple overlapping layout passes occur when:
1. State changes trigger `objectWillChange.send()` immediately
2. Views have `.animation()` modifiers that trigger layout on state changes
3. Multiple sessions change state within the same frame

**Symptom:** Crash log shows recursive `_informContainerThatSubviewsNeedUpdateConstraints` calls and `NSHostingView` geometry updates.

**Solution:** Debounce `objectWillChange.send()` to coalesce rapid updates:
```swift
private var refreshDebounceWork: DispatchWorkItem?
private var isRefreshScheduled = false

func refreshSessionStates() {
    // Update state synchronously
    sessionStateManager.refreshSessionStates(for: projects)

    // Debounce UI notification
    guard !isRefreshScheduled else { return }
    isRefreshScheduled = true

    refreshDebounceWork?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
        self?.isRefreshScheduled = false
        self?.objectWillChange.send()
    }
    refreshDebounceWork = workItem

    // 16ms (~1 frame at 60fps) coalesces updates within a single frame
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
}
```

**See:** `AppState.swift:216-235`, crash log `Capacitor-2026-01-29-102502.ips`

### Multi-Source Version Detection

Release builds and dev builds have different "sources of truth" for version:

| Context | Version Source |
|---------|---------------|
| Release build | `Info.plist` (set by `build-distribution.sh`) |
| Dev build (`swift run`) | `VERSION` file in project root |
| Unknown | Hardcoded fallback (updated by `bump-version.sh`) |

**Implementation pattern:**
```swift
private static func getAppVersion() -> String {
    // 1. Try Info.plist (correct in release builds)
    if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
       bundleVersion != "1.0" {
        return bundleVersion
    }

    // 2. Dev build fallback: read VERSION file
    if let versionData = FileManager.default.contents(atPath: "VERSION"),
       let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
        return version
    }

    // 3. Ultimate fallback (kept in sync by bump-version.sh)
    return "X.Y.Z"
}
```

**Why this works:** SPM debug builds don't get correct Info.plist values, but the VERSION file is accessible when running from the project directory. The fallback is automatically updated by `bump-version.sh`.

### CI Smoke Test Fallbacks

When scripts need resources that only exist in full builds (e.g., app bundle Info.plist), check for `$CI` environment variable to provide fallbacks:

```bash
if [ -z "$BUILD_NUMBER" ]; then
    if [ -n "$CI" ]; then
        BUILD_NUMBER=$(date +"%Y%m%d%H%M")
        echo "⚠ Using generated build number for CI: $BUILD_NUMBER"
    else
        echo "ERROR: Build required"
        exit 1
    fi
fi
```

GitHub Actions sets `$CI=true` automatically. This allows smoke tests to verify script logic without requiring full distribution builds.

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

### Shell Selection: HOME Excluded from Parent Matching

Path matching supports parent-child relationships for monorepo support (shell at `/Code/monorepo` matches project `/Code/monorepo/packages/app`). However, HOME (`/Users/pete`) is explicitly **excluded** from parent matching.

**Why:** HOME is a parent of nearly everything. Without exclusion, a shell at HOME matches all projects, causing:
- Wrong shell selection (HOME shell instead of project-specific shell)
- `ActivateByTty` instead of `ActivateHostThenSwitchTmux`
- Terminal focuses but tmux session doesn't switch

**Implementation:** `paths_match_excluding_home()` in `activation.rs` checks if the shorter path equals `home_dir` before allowing parent matching.

**Test:** `test_home_shell_does_not_match_project` verifies this behavior.

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

### Terminal Activation: Query Fresh Client TTY

Shell records in `shell-cwd.json` store `tmux_client_tty` at shell creation time. This TTY becomes **stale** when users reconnect to tmux—they get assigned new TTY devices (e.g., `/dev/ttys012` instead of `/dev/ttys000`).

**Symptom:** TTY discovery fails, falls through to Ghostty window-count check, sees 0 windows (user is in Terminal.app/iTerm), spawns new terminal.

**Fix:** Query fresh TTY at activation time:
```swift
private func getCurrentTmuxClientTty() async -> String? {
    let result = await runBashScriptWithResultAsync("tmux display-message -p '#{client_tty}'")
    guard result.exitCode == 0, let output = result.output else { return nil }
    let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return tty.isEmpty ? nil : tty
}
```

**Where:** `TerminalLauncher.swift:activateHostThenSwitchTmux` — use `getCurrentTmuxClientTty() ?? hostTty` before TTY discovery.

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
The activity store supports two formats: legacy hook format (`"files"` array from older hud-hook versions) and native format (`"activity"` array with `project_path`). The hook now writes native format and migrates legacy files on write, but `ActivityStore::load()` still checks for hook format markers before attempting native format parsing to preserve backward compatibility.

**Why this matters:** Hook format JSON successfully deserializes as native format (due to `serde(default)`), but with empty `activity` arrays. Without explicit hook marker detection, file activity data gets silently discarded, breaking the activity-based fallback for state resolution.

**Related test:** `loads_hook_format_with_boundary_detection` in `activity.rs`.

## Accepted Tradeoffs

### Cleanup Race Condition
`run_startup_cleanup()` uses read-modify-write without file locking. Concurrent hook events during cleanup could be lost. Accepted because: (1) cleanup runs only at app launch, (2) window is milliseconds, (3) lost events self-heal. See `cleanup.rs`.
