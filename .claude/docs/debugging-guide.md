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
