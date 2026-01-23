# Debugging Guide

Procedures for debugging Claude HUD components.

## General Debugging

```bash
# Inspect cache files
cat ~/.capacitor/stats-cache.json | jq .

# Enable Rust debug logging
RUST_LOG=debug swift run

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

## Hook State Tracking

The hook binary (`~/.local/bin/hud-hook`) handles Claude Code hook events and tracks session state.

Quick commands:
```bash
tail -f ~/.capacitor/hud-hook-debug.log        # Watch events
cat ~/.capacitor/sessions.json | jq .          # View states
ls ~/.capacitor/sessions/                      # Check active locks
```

## Common Issues

### UniFFI Checksum Mismatch

If you see `UniFFI API checksum mismatch: try cleaning and rebuilding your project`:

1. Check for stale Bridge file: `apps/swift/Sources/ClaudeHUD/Bridge/hud_core.swift`
2. Remove stale app bundle: `rm -rf apps/swift/ClaudeHUD.app`
3. Remove stale .build cache: `rm -rf apps/swift/.build`
4. Verify dylib is fresh: `ls -la target/release/libhud_core.dylib`

See `.claude/docs/development-workflows.md` for the full regeneration procedure.

### Stats Not Updating

1. Check if cache is stale: `cat ~/.capacitor/stats-cache.json | jq '.entries | keys'`
2. Delete cache to force recomputation: `rm ~/.capacitor/stats-cache.json`
3. Verify session files exist: `ls ~/.claude/projects/`

### State Stuck on Working/Waiting (Session Actually Ended)

**Symptoms:** Project shows Working or Waiting but Claude session has ended.

**Root cause:** Lock holder didn't clean up (crashed, force-killed, or PID mismatch).

**Debug:**
```bash
# Check if lock exists
ls ~/.capacitor/sessions/

# Check if lock holder PID is alive
cat ~/.capacitor/sessions/*.lock/pid | xargs -I {} ps -p {}

# If PID is dead, app cleanup should remove it on next launch
# Force cleanup by restarting the app
```

**Fix:** App runs `runStartupCleanup()` on launch which removes locks with dead PIDs.

### State Transitions to Ready Prematurely (Session Still Active)

**Symptoms:** Project shows Ready but Claude is still generating a response. Typically happens ~30 seconds into a long generation without tool use.

**Root cause (historical bug, now fixed):** The resolver applied `is_active_state_stale()` checks even when a lock existed. During tool-free text generation, no hook events fire to refresh `updated_at`, so after 30 seconds the state would fall back to Ready despite the lock proving Claude was still running.

**Current behavior:** When a lock exists, the resolver trusts the recorded state unconditionally. The lock holder monitors Claude's PID and will release when Claude actually exits, so lock existence is authoritative.

**Key insight:** Lock presence = Claude running. Trust the lock over timestamp freshness.

### SwiftUI Layout Broken (Gaps, Components Not Filling Space)

**Symptoms:** Large gaps between header and content, tab bar floating in middle of window.

**Root cause:** Window drag spacers using `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)` in HStacks. The `maxHeight: .infinity` causes the HStack to expand vertically.

**Solution:** For horizontal spacers that need to be draggable:
```swift
// Simple spacer - preferred
Spacer()

// Or fixed height if needed for hit testing
Color.clear
    .frame(maxWidth: .infinity)
    .frame(height: 28)
    .contentShape(Rectangle())
    .windowDraggable()
```
