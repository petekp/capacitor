# Hook Failure Prevention Checklist

This document provides precise steps to prevent hook state tracking failures.

## Immediate Actions (Completed)

✅ **1. Enhanced Logging**
- Added logging for all early exits with reasons
- Added logging for all state transitions
- Added logging for skipped events
- Added trigger field to debug logs

✅ **2. Removed Silent Exits**
- All `exit 0` calls now log why they're exiting
- Invalid input logged with details
- Unhandled events logged explicitly

✅ **3. PreCompact Fix**
- Removed trigger="auto" filter
- ALL compactions now set state=compacting
- Documented behavior in state machine doc

✅ **4. Created Test Suite**
- Tests all 11 event handlers
- Validates state transitions
- Can be run before deploying hook changes
- Location: `~/.claude/scripts/test-hud-hooks.sh`

✅ **5. Created Documentation**
- Complete state machine reference
- Expected behavior for each event
- Debugging commands
- Testing instructions

## Ongoing Prevention Steps

### Before Modifying Hooks

1. **Read the state machine doc** (`.claude/docs/hook-state-machine.md`)
   - Understand current behavior
   - Identify what should change

2. **Check the docs** (`docs/claude-code/hooks.md`)
   - Verify what fields are actually provided
   - Don't assume fields exist without checking

3. **Never filter events silently**
   - If you need to skip an event, log why
   - Add a comment explaining the reasoning

4. **Test with real data**
   - Trigger the actual event (don't just assume)
   - Check the debug log to see what data arrives
   - Verify state file updates correctly

### After Modifying Hooks

1. **Run the test suite**
   ```bash
   ~/.claude/scripts/test-hud-hooks.sh
   ```

2. **Test the specific change manually**
   - For PreCompact: Actually run `/compact` manually
   - For SessionStart: Launch a new Claude session
   - For Stop: Let Claude finish a response

3. **Check the debug log**
   ```bash
   tail -20 ~/.claude/hud-hook-debug.log
   ```
   - Verify state transitions happened
   - Check for unexpected warnings/errors

4. **Verify in the HUD**
   - Open Claude HUD
   - Trigger the event
   - Confirm status updates in real-time

5. **Document changes**
   - Update `.claude/docs/hook-state-machine.md` if behavior changed
   - Add comments explaining complex logic

## Warning Signs

Watch for these patterns that indicate potential failures:

🚨 **Silent exits without logging**
```bash
if [ "$condition" ]; then
  exit 0  # ❌ NO! Log why first
fi
```
Should be:
```bash
if [ "$condition" ]; then
  echo "$(date) | Skipping: reason" >> "$LOG_FILE"
  exit 0
fi
```

🚨 **Assumptions about field values**
```bash
if [ "$trigger" = "auto" ]; then  # ❌ What if trigger is missing?
```
Should be:
```bash
# Always process PreCompact, regardless of trigger
new_state="compacting"
```

🚨 **No validation logging**
```bash
jq update command > tmpfile && mv tmpfile $STATE_FILE
# ❌ No log of what changed!
```
Should be:
```bash
echo "$(date) | State transition: $event -> $new_state" >> "$LOG_FILE"
jq update command > tmpfile && mv tmpfile $STATE_FILE
```

🚨 **Filtering log output**
```bash
jq -c '{event: .hook_event_name, cwd: .cwd}'
# ❌ Missing important fields like trigger!
```
Should include ALL relevant fields for debugging.

## Health Monitoring

### Daily Checks

Run this command to check for hook failures:
```bash
grep -E "ERROR|WARNING|FAIL" ~/.claude/hud-hook-debug.log | tail -20
```

### Weekly Checks

1. Check for dead lock files (PID not running):
```bash
for lock in ~/.claude/sessions/*.lock; do
  [ -f "$lock/pid" ] && pid=$(cat "$lock/pid") && \
  ! kill -0 $pid 2>/dev/null && echo "Dead PID lock: $lock"
done
```

2. Check for orphaned locks (PID alive but no state record):
```bash
# Get all PIDs from state file
state_pids=$(jq -r '.sessions[].pid // empty' ~/.claude/hud-session-states-v2.json 2>/dev/null | sort -u)

for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] || continue
  meta="$lock/meta.json"
  [ -f "$meta" ] || continue
  pid=$(jq -r '.pid' "$meta" 2>/dev/null)
  [ -n "$pid" ] && kill -0 $pid 2>/dev/null && \
  ! echo "$state_pids" | grep -q "^$pid$" && \
  echo "Orphaned: $lock (PID $pid alive but no state)"
done
```

**Note:** Orphaned locks are also handled automatically by the Rust core:
- `reconcile_orphaned_lock()` is called when adding projects via HUD
- The resolver falls back to trusting state records when lock PID has no session
- See ADR-002 "Orphaned Lock Handling" for details

3. Check for stale sessions (state record with dead PID):
```bash
jq -r '.sessions | to_entries[] | select(.value.pid != null) | "\(.value.pid) \(.value.cwd)"' \
  ~/.claude/hud-session-states-v2.json | while read pid cwd; do
  kill -0 $pid 2>/dev/null || echo "Dead PID: $pid ($cwd)"
done
```

### Before Deploying Changes

**Mandatory Checklist:**
- [ ] Read hook state machine docs
- [ ] Verify Claude Code docs for event payload
- [ ] Add logging for all decision points
- [ ] Run test suite: `~/.claude/scripts/test-hud-hooks.sh`
- [ ] Test manually with real Claude session
- [ ] Verify in HUD app
- [ ] Check debug log for errors
- [ ] Update documentation if behavior changed

## Recovery Procedures

### If hooks stop working entirely:

1. Check jq is installed:
   ```bash
   which jq || brew install jq
   ```

2. Check state file is valid JSON:
   ```bash
   jq . ~/.claude/hud-session-states-v2.json
   ```

3. Check hook script is executable:
   ```bash
   ls -l ~/.claude/scripts/hud-state-tracker.sh
   ```

4. Check hook is registered in settings:
   ```bash
   jq '.hooks' ~/.claude/settings.json
   ```

### If specific events aren't tracking:

1. Check debug log for that event:
   ```bash
   grep "EventName" ~/.claude/hud-hook-debug.log | tail -10
   ```

2. Run test suite to isolate:
   ```bash
   ~/.claude/scripts/test-hud-hooks.sh
   ```

3. Manually inject test event:
   ```bash
   echo '{"hook_event_name":"PreCompact","session_id":"test","cwd":"/tmp","trigger":"manual"}' | \
     bash ~/.claude/scripts/hud-state-tracker.sh
   ```

4. Check what was logged:
   ```bash
   tail -5 ~/.claude/hud-hook-debug.log
   ```

## References

- Hook state machine: `.claude/docs/hook-state-machine.md`
- Claude Code hook docs: `docs/claude-code/hooks.md`
- Test suite: `~/.claude/scripts/test-hud-hooks.sh`
- Hook script: `~/.claude/scripts/hud-state-tracker.sh`
- Debug log: `~/.claude/hud-hook-debug.log`
