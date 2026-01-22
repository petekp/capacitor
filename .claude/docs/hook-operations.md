# Hook Operations Reference

Complete reference for the HUD state tracking hook system: state machine, debugging, and troubleshooting.

## State Machine

```
┌─────────────────────────────────────────────────────┐
│                   State Transitions                  │
└─────────────────────────────────────────────────────┘

SessionStart         → ready
UserPromptSubmit     → working
PermissionRequest    → waiting
PostToolUse          → depends on current state:
                       - compacting → working (returns from compaction)
                       - working    → working (heartbeat update only)
                       - ready      → working (session resumed)
                       - idle       → working (session resumed)
                       - waiting    → working (permission granted)
Notification         → ready (only if notification_type="idle_prompt")
Stop                 → ready
PreCompact           → compacting (only when trigger="auto")
SessionEnd           → REMOVED (session deleted from state file)
```

## Event Handlers

| Event | Triggers | Action | Requirements |
|-------|----------|--------|--------------|
| **SessionStart** | Session launch/resume | Create lock, state=ready | session_id, cwd |
| **UserPromptSubmit** | User submits prompt | state=working, create lock if missing | session_id, cwd |
| **PermissionRequest** | Claude needs permission | state=waiting | session_id, cwd |
| **PostToolUse** | After tool execution | Update state based on current | session_id |
| **Notification** | Claude notification | state=ready (only if idle_prompt) | session_id, cwd, notification_type |
| **Stop** | Claude finishes responding | state=ready | session_id, cwd, stop_hook_active=false |
| **PreCompact** | Before compaction | state=compacting only when trigger="auto" | session_id, cwd |
| **SessionEnd** | Session ends | Remove session (lock released when process exits) | session_id, cwd |

## Lock/State Relationship

**Normal case:** Lock PID matches state record PID → Resolver uses state record directly.

**Mismatched PID case:**
1. If record's PID is alive → Resolver prefers state record (newer session without lock)
2. If record's PID is dead → Resolver searches for sessions matching lock's PID
3. If no match found → Falls back to state record

**Orphaned lock cleanup:** `reconcile_orphaned_lock()` cleans up stale locks when `add_project` is called.

---

## Debugging

### Quick Commands

```bash
# Watch hook events in real-time
tail -f ~/.claude/hud-hook-debug.log

# Check recent state transitions
grep "State transition" ~/.claude/hud-hook-debug.log | tail -20

# Check for errors/warnings
grep -E "ERROR|WARNING" ~/.claude/hud-hook-debug.log | tail -20

# View current session states
cat ~/.capacitor/sessions.json | jq .

# Check active lock files
for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] && cat "$lock/meta.json" 2>/dev/null
done | jq -s .

# Run test suite
~/.claude/scripts/test-hud-hooks.sh

# Manually inject test event
echo '{"hook_event_name":"PreCompact","session_id":"test","cwd":"/tmp","trigger":"manual"}' | \
  bash ~/.claude/scripts/hud-state-tracker.sh
```

### Health Monitoring

**Check for dead lock files:**
```bash
for lock in ~/.claude/sessions/*.lock; do
  [ -f "$lock/pid" ] && pid=$(cat "$lock/pid") && \
  ! kill -0 $pid 2>/dev/null && echo "Dead PID lock: $lock"
done
```

**Check for stale sessions:**
```bash
jq -r '.sessions | to_entries[] | select(.value.pid != null) | "\(.value.pid) \(.value.cwd)"' \
  ~/.capacitor/sessions.json | while read pid cwd; do
  kill -0 $pid 2>/dev/null || echo "Dead PID: $pid ($cwd)"
done
```

---

## Troubleshooting

### Hook Events Not Firing

1. Check hook configuration: `jq '.hooks' ~/.claude/settings.json`
2. Verify hook script exists: `ls -la ~/.claude/scripts/hud-state-tracker.sh`
3. Check debug log: `tail -50 ~/.claude/hud-hook-debug.log`
4. Run test suite: `~/.claude/scripts/test-hud-hooks.sh`

### Session States Stuck on Ready

**Symptoms:** All cards show "Ready" even when sessions are working.

**Diagnosis:**
```bash
# Check state file for working sessions
cat ~/.capacitor/sessions.json | jq '.sessions | to_entries[] | select(.value.state == "working")'

# Check lock for your project
echo -n "/path/to/project" | md5
ls -la ~/.claude/sessions/<hash>.lock/

# Compare PIDs
cat ~/.claude/sessions/<hash>.lock/pid
```

**Root cause:** Resolver prioritizing stale lock files over fresh state entries when PIDs differ.

### Hooks Stop Working Entirely

1. Check jq is installed: `which jq || brew install jq`
2. Check state file is valid: `jq . ~/.capacitor/sessions.json`
3. Check hook is executable: `ls -l ~/.claude/scripts/hud-state-tracker.sh`
4. Check hook is registered: `jq '.hooks' ~/.claude/settings.json`

---

## Prevention Guidelines

### Before Modifying Hooks

1. Read this document and understand current behavior
2. Check `docs/claude-code/hooks.md` for event payload fields
3. Never filter events silently—always log skip reasons
4. Test with real data, not assumptions

### Warning Signs

🚨 **Silent exits:** Every `exit 0` must log why it's exiting
🚨 **Assumed fields:** Don't assume trigger/notification_type exist
🚨 **No validation logging:** Always log state transitions

### After Modifying Hooks

- [ ] Run test suite: `~/.claude/scripts/test-hud-hooks.sh`
- [ ] Test manually with real Claude session
- [ ] Check debug log: `tail -20 ~/.claude/hud-hook-debug.log`
- [ ] Verify in HUD app
- [ ] Update this document if behavior changed

---

## References

- Hook script: `~/.claude/scripts/hud-state-tracker.sh`
- Test suite: `~/.claude/scripts/test-hud-hooks.sh`
- Debug log: `~/.claude/hud-hook-debug.log`
- State file: `~/.capacitor/sessions.json`
- Claude Code hook docs: `docs/claude-code/hooks.md`
- ADR-002: Lock handling architecture
