# Hook State Machine Reference

This document defines the expected behavior for all hook events in the HUD state tracking system.

## State Transitions

```
┌─────────────────────────────────────────────────────┐
│                   State Machine                      │
└─────────────────────────────────────────────────────┘

SessionStart         → ready
UserPromptSubmit     → working
PermissionRequest    → blocked
PostToolUse          → depends on current state:
                       - compacting → working (returns from compaction)
                       - working    → working (heartbeat update only)
                       - ready      → working (session resumed)
                       - idle       → working (session resumed)
                       - blocked    → working (permission granted)
Notification         → ready (only if notification_type="idle_prompt")
Stop                 → ready
PreCompact           → compacting (for ALL trigger values)
SessionEnd           → REMOVED (session deleted from state file)
```

## Event Handlers

### SessionStart
**Triggers:** Session launch or resume
**Action:** Create lock file, set state=ready
**Requirements:** session_id, cwd
**Logging:** Lock holder spawned

### UserPromptSubmit
**Triggers:** User submits a prompt
**Action:** Set state=working, create lock if missing (resumed sessions)
**Requirements:** session_id, cwd
**Logging:** State transition, retroactive lock creation if needed

### PermissionRequest
**Triggers:** Claude needs user permission
**Action:** Set state=blocked
**Requirements:** session_id, cwd
**Logging:** State transition

### PostToolUse
**Triggers:** After any tool execution
**Action:** Update state based on current state
**Requirements:** session_id
**Logging:**
- compacting→working transitions
- ready/idle/blocked→working transitions
- Heartbeat updates when already working
- Early exit if no session_id

### Notification
**Triggers:** Claude sends notification
**Action:** Set state=ready ONLY if notification_type="idle_prompt"
**Requirements:** session_id, cwd, notification_type
**Logging:**
- idle_prompt → ready transitions
- Ignored notification types

### Stop
**Triggers:** Claude finishes responding
**Action:** Set state=ready
**Requirements:** session_id, cwd, stop_hook_active=false
**Logging:** State transition
**Special:** Skips if stop_hook_active=true

### PreCompact
**Triggers:** Before compaction (manual or auto)
**Action:** Set state=compacting
**Requirements:** session_id, cwd
**Logging:** State transition
**Important:** ALL compactions (manual and auto) set state=compacting

### SessionEnd
**Triggers:** Session ends
**Action:** Remove session from state file, lock released by lock holder
**Requirements:** session_id, cwd
**Logging:** State transition, lock release

## Critical Requirements

### Must Log
- All early exits (with reason)
- All state transitions
- All skipped events (with reason)
- Invalid input (missing cwd, event, session_id)
- Unexpected states
- Lock creation/handoff/release

### Must Never
- Silently exit without logging
- Assume data fields exist without checking
- Filter events without documenting why
- Make assumptions about trigger values

## Testing

Run the test suite to verify all transitions:
```bash
~/.claude/scripts/test-hud-hooks.sh
```

This tests all 11 event handlers with various input conditions.

## Debugging

Check hook logs for state transitions:
```bash
tail -f ~/.claude/hud-hook-debug.log
```

Filter for specific events:
```bash
grep "PreCompact" ~/.claude/hud-hook-debug.log
grep "State transition" ~/.claude/hud-hook-debug.log
```

Check current state:
```bash
cat ~/.claude/hud-session-states-v2.json | jq .
```

Check active locks:
```bash
for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] && cat "$lock/meta.json"
done | jq -s .
```
