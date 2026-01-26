# ACTIVE: Bulletproof Hook System

**Status:** ACTIVE
**Priority:** P0 - Critical
**Created:** 2026-01-26

## Problem Statement

The hook system has been unreliable throughout development, causing:
- Sessions stuck in wrong states (Ready vs Idle vs Working)
- Silent failures with no user feedback
- Repeated debugging of the same class of issues

Root cause: Multiple installation paths, no self-healing, and copy vs symlink issues with macOS code signing.

## Success Criteria

1. **Zero silent failures** - Every hook failure surfaces to the user
2. **Self-healing** - App automatically repairs common issues
3. **Single installation path** - One mechanism that works for dev and prod
4. **Startup validation** - Health check before app becomes usable
5. **Clear diagnostics** - When things break, exact cause and fix are shown

## Architecture Decision: Symlink vs Copy

### Analysis

| Approach | Dev Builds | Prod Builds | Pros | Cons |
|----------|------------|-------------|------|------|
| **Copy** | ❌ SIGKILL (adhoc signed) | ✅ Works (codesigned) | Simple | Breaks dev, signature issues |
| **Symlink to repo** | ✅ Works | ❌ N/A (no repo) | Works in dev | Hardcoded path, breaks if repo moves |
| **Symlink to app bundle** | ✅ Works | ✅ Works | Unified approach | Need to resolve bundle path |

### Decision: Symlink to App Bundle Resource

The app should:
1. Bundle `hud-hook` in `Contents/Resources/` (already done in release builds)
2. Create symlink: `~/.local/bin/hud-hook -> /path/to/Capacitor.app/Contents/Resources/hud-hook`
3. For dev builds: Swift build copies binary to `.build/` directory, symlink points there

**Why this works:**
- Symlinks preserve the original binary's code signature
- App always knows where its own bundle is (`Bundle.main`)
- Single code path for dev and prod
- If app moves, symlink breaks obviously (not silently)

## Implementation Plan

### Phase 1: Core Infrastructure (Do First)

#### 1.1 Update `install_binary_from_path()` to use symlinks

**File:** `core/hud-core/src/setup.rs`

```rust
pub fn install_binary_from_path(&self, source_path: &str) -> Result<InstallResult, HudFfiError> {
    let source = Path::new(source_path);
    if !source.exists() {
        return Ok(InstallResult {
            success: false,
            message: format!("Source binary not found at {}", source_path),
            script_path: None,
        });
    }

    let dest_path = self.get_hook_binary_path();
    let dest_dir = dest_path.parent().unwrap();
    fs::create_dir_all(dest_dir)?;

    // Remove existing file/symlink
    if dest_path.exists() || dest_path.is_symlink() {
        fs::remove_file(&dest_path)?;
    }

    // Create symlink instead of copy
    std::os::unix::fs::symlink(source, &dest_path)?;

    Ok(InstallResult {
        success: true,
        message: format!("Hook binary symlinked: {} -> {}", dest_path.display(), source_path),
        script_path: Some(dest_path.to_string_lossy().to_string()),
    })
}
```

#### 1.2 Add symlink validation to `verify_hook_binary()`

```rust
fn verify_hook_binary(&self) -> Result<(), String> {
    let binary_path = self.get_hook_binary_path();

    // Check symlink target exists
    if binary_path.is_symlink() {
        let target = fs::read_link(&binary_path)
            .map_err(|e| format!("Cannot read symlink: {}", e))?;
        if !target.exists() {
            return Err(format!(
                "Symlink target missing: {} -> {}. The app may have moved.",
                binary_path.display(), target.display()
            ));
        }
    }

    // ... existing SIGKILL detection ...
}
```

#### 1.3 Add `HookStatus::SymlinkBroken` variant

```rust
pub enum HookStatus {
    NotInstalled,
    Outdated { current: String, latest: String },
    Installed { version: String },
    PolicyBlocked { reason: String },
    BinaryBroken { reason: String },
    SymlinkBroken { target: String, reason: String },  // NEW
}
```

### Phase 2: Self-Healing

#### 2.1 Add auto-repair on startup

**File:** `apps/swift/Sources/Capacitor/App.swift` or `AppState.swift`

On app launch:
1. Call `check_setup_status()`
2. If `HookStatus::SymlinkBroken` or `HookStatus::BinaryBroken`:
   - Attempt automatic repair via `install_binary_from_path(Bundle.main.resourcePath + "/hud-hook")`
   - Log the repair attempt
3. If repair fails, show blocking alert (app unusable without hooks)

#### 2.2 Add periodic health checks

Every 60 seconds while app is running:
1. Quick check: symlink exists and target exists
2. If broken: attempt repair, notify user if fails

### Phase 3: Observability

#### 3.1 Sync vs Async hook strategy

Current problem: All hooks except `SessionEnd` are async, meaning errors don't surface.

**New strategy:**
- Keep hooks async for performance
- Add a **heartbeat verification**: If no hook events received for 30+ seconds while Claude sessions are active, show warning
- On `SessionStart`: Run a synchronous "ping" to verify hooks work

#### 3.2 Add hook event logging to app

**File:** New `HookHealthMonitor.swift`

Track:
- Last successful hook event timestamp per session
- Expected vs actual event counts
- Surface warnings if hooks appear dead

#### 3.3 SetupStatusCard improvements

Show more detail:
- Symlink path and target
- Last successful hook event
- "Test Hook" button that fires a test event and verifies round-trip

### Phase 4: Dev Experience

#### 4.1 Update `sync-hooks.sh` to detect app bundle

If Capacitor.app exists in `/Applications` or `~/Applications`:
- Symlink to app bundle (matches production behavior)

If not:
- Symlink to `target/release/` (dev fallback)

#### 4.2 Add `scripts/dev/verify-hooks.sh`

Quick diagnostic script:
```bash
#!/bin/bash
echo "=== Hook System Health Check ==="

# Check symlink
echo -n "Symlink: "
ls -la ~/.local/bin/hud-hook

# Check target exists
echo -n "Target exists: "
test -e "$(readlink ~/.local/bin/hud-hook)" && echo "YES" || echo "NO"

# Test execution
echo -n "Execution test: "
echo '{}' | ~/.local/bin/hud-hook handle 2>&1
echo "Exit code: $?"

# Check settings.json
echo -n "Hooks registered: "
grep -c "hud-hook" ~/.claude/settings.json 2>/dev/null || echo "0"
```

## Migration Path

1. **Phase 1 (COMPLETE 2026-01-26):**
   - ✅ Update `install_binary_from_path()` to use symlinks
   - ✅ Add symlink validation to `verify_hook_binary()`
   - ✅ Update `sync-hooks.sh` to prefer app bundle over repo build
   - ✅ Add `HookStatus::SymlinkBroken` variant
   - ✅ Add `HookIssue::SymlinkBroken` variant

2. **Phase 2 (COMPLETE 2026-01-26):**
   - ✅ Regenerate UniFFI bindings for Swift
   - ✅ Implement startup auto-repair in `AppDelegate.validateHookSetup()`
   - ✅ Update `SetupRequirements.swift` to handle `symlinkBroken` status

3. **Phase 3 (TODO):**
   - Add HookHealthMonitor for periodic health checks
   - Improve observability (heartbeat verification, hook event logging)

## Testing Strategy

### Manual Tests
- [ ] Fresh install: App creates working symlink
- [ ] Move app: Symlink breaks, app detects and repairs
- [ ] Delete binary: App detects and repairs
- [ ] Corrupt settings.json: App detects and shows clear error
- [ ] `cargo clean`: Dev symlink breaks, `sync-hooks.sh` repairs

### Automated Tests
- [ ] `verify_hook_binary()` detects broken symlink
- [ ] `install_binary_from_path()` creates symlink, not copy
- [ ] `check_setup_status()` returns correct status for all failure modes

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Symlink to app bundle breaks if app not in expected location | Auto-repair on startup + clear error message |
| User has both dev symlink and app-installed symlink | Single installation function always overwrites |
| Breaking change for existing users | Symlink works transparently; copy users get auto-upgraded |

## Open Questions

1. Should we support multiple binary locations (app bundle, homebrew, manual)?
2. Should hooks be sync by default with async opt-in, for better error visibility?
3. Do we need a "hook test mode" that verifies round-trip before declaring success?
