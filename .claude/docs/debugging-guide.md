# Debugging Guide

Procedures for debugging Claude HUD components.

## General Debugging

```bash
# Inspect cache files
cat ~/.claude/hud-stats-cache.json | jq .

# Enable Rust debug logging
RUST_LOG=debug swift run

# Test regex patterns
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

## Hook State Tracking Debugging

```bash
# Watch hook events in real-time
tail -f ~/.claude/hud-hook-debug.log

# Check recent state transitions
grep "State transition" ~/.claude/hud-hook-debug.log | tail -20

# Check for errors/warnings
grep -E "ERROR|WARNING" ~/.claude/hud-hook-debug.log | tail -20

# View current session states
cat ~/.claude/hud-session-states-v2.json | jq .

# Check active lock files
for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] && cat "$lock/meta.json" 2>/dev/null
done | jq -s .

# Test hook event handlers
~/.claude/scripts/test-hud-hooks.sh

# Manually inject test event
echo '{"hook_event_name":"PreCompact","session_id":"test","cwd":"/tmp","trigger":"manual"}' | \
  bash ~/.claude/scripts/hud-state-tracker.sh
```

**Debugging Resources:**
- Hook state machine: `.claude/docs/hook-state-machine.md`
- Prevention checklist: `.claude/docs/hook-prevention-checklist.md`

## Common Issues

### UniFFI Checksum Mismatch

If you see `UniFFI API checksum mismatch: try cleaning and rebuilding your project`:

1. Check for stale Bridge file: `apps/swift/Sources/ClaudeHUD/Bridge/hud_core.swift`
2. Remove stale app bundle: `rm -rf apps/swift/ClaudeHUD.app`
3. Remove stale .build cache: `rm -rf apps/swift/.build`
4. Verify dylib is fresh: `ls -la target/release/libhud_core.dylib`

See `.claude/docs/development-workflows.md` for the full regeneration procedure.

### Stats Not Updating

1. Check if cache is stale: `cat ~/.claude/hud-stats-cache.json | jq '.entries | keys'`
2. Delete cache to force recomputation: `rm ~/.claude/hud-stats-cache.json`
3. Verify session files exist: `ls ~/.claude/projects/`

### Hook Events Not Firing

1. Check hook configuration in `~/.claude/settings.json`
2. Verify hook script is symlinked: `ls -la ~/.claude/scripts/hud-state-tracker.sh`
3. Check debug log: `tail -50 ~/.claude/hud-hook-debug.log`
4. Run test suite: `~/.claude/scripts/test-hud-hooks.sh`

### Session States Stuck on Ready

**Symptoms:** All project cards show "Ready" even when Claude Code sessions are actively working. The state file shows correct "working" state but the HUD displays "ready".

**Root cause:** Claude Code may not create lock files for every session. The state resolver was prioritizing stale lock files over fresh state store entries. When a session's PID differs from the lock's PID, the resolver searched for sessions matching the lock instead of checking if the current session's PID is alive.

**Diagnosis:**
```bash
# Check state file - look for working sessions
cat ~/.claude/hud-session-states-v2.json | jq '.sessions | to_entries[] | select(.value.state == "working")'

# Check what lock exists for your project
echo -n "/path/to/your/project" | md5
ls -la ~/.claude/sessions/<hash>.lock/

# Compare PIDs - if state file has different PID than lock, that's the issue
cat ~/.claude/sessions/<hash>.lock/pid
```

**Solution:** The resolver (`core/hud-core/src/state/resolver.rs`) must check if the state store entry's PID is alive before falling back to lock-matching sessions. Both `resolve_state` and `resolve_state_with_details` need this fix:

```rust
// When record.pid != lock_info.pid
if is_pid_alive(record_pid) {
    // Record's PID is alive - use its state
    Some(r.state)
} else {
    // Record's PID is dead - search for lock-matching sessions
    find_session_for_lock(store, &lock_info)
}
```

**Verification:**
```bash
cargo run -p hud-core --bin state-check
# Should show "Working" for active sessions
```

### SwiftUI Layout Broken (Gaps, Components Not Filling Space)

**Symptoms:** Large gaps between header and content, tab bar floating in middle of window instead of bottom, scroll views not filling available space.

**Root cause:** Window drag spacers using `Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)` in HStacks. The `maxHeight: .infinity` causes the HStack to expand vertically within its parent VStack, breaking the layout.

**Solution:** For horizontal spacers that need to be draggable:
- Use simple `Spacer()` (expands only horizontally in HStack)
- Or use `Color.clear.frame(maxWidth: .infinity).frame(height: 28)` with a fixed height

**Bad:**
```swift
// In an HStack - this breaks VStack parent layout!
Color.clear
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .windowDraggable()
```

**Good:**
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
