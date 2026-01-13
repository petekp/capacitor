# Hook Script Update Plan

## Goal

Update `~/.claude/scripts/hud-state-tracker.sh` to write the new v2 state format that's keyed by session_id instead of CWD. This enables the Rust `state` module to correctly resolve project states.

## Current vs New State Format

**Current (v1) - keyed by CWD:**
```json
{
  "version": 1,
  "projects": {
    "/path/to/project": {
      "state": "working",
      "session_id": "uuid",
      "thinking": true
    }
  }
}
```

**New (v2) - keyed by session_id:**
```json
{
  "version": 2,
  "sessions": {
    "session-uuid-1": {
      "session_id": "session-uuid-1",
      "state": "working",
      "cwd": "/path/to/project",
      "updated_at": "2024-01-01T00:00:00Z"
    }
  }
}
```

## Changes Required

### 1. New State File Path
- **Current:** `~/.claude/hud-session-states.json`
- **New:** `~/.claude/hud-session-states-v2.json`

Keep both files during transition. The Rust module reads v2, old Swift code reads v1.

### 2. State File Initialization
Change from:
```bash
echo '{"version":1,"projects":{}}' > "$STATE_FILE"
```
To:
```bash
echo '{"version":2,"sessions":{}}' > "$STATE_FILE_V2"
```

### 3. Add PermissionRequest Handler
Currently PermissionRequest exits early. Change to:
```bash
"PermissionRequest")
  new_state="blocked"
  ;;
```

### 4. Update update_state() Function

Replace the CWD-keyed updates with session_id-keyed updates:

```bash
update_state_v2() {
  local tmp_file
  tmp_file=$(mktemp)

  if [ "$new_state" = "idle" ] || [ -z "$session_id" ]; then
    # Remove session on SessionEnd or if no session_id
    jq --arg sid "$session_id" \
       'del(.sessions[$sid])' "$STATE_FILE_V2" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE_V2"
  else
    jq --arg sid "$session_id" \
       --arg state "$new_state" \
       --arg cwd "$cwd" \
       --arg ts "$timestamp" \
       '.sessions[$sid] = {
         session_id: $sid,
         state: $state,
         cwd: $cwd,
         updated_at: $ts
       }' "$STATE_FILE_V2" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE_V2"
  fi
}
```

### 5. Update PostToolUse Handler

Currently reads from v1 format. Update to read from v2:

```bash
"PostToolUse")
  if [ -z "$session_id" ]; then
    exit 0
  fi
  current_state=$(jq -r --arg sid "$session_id" '.sessions[$sid].state // "idle"' "$STATE_FILE_V2" 2>/dev/null)
  # ... rest of logic stays the same
```

### 6. Summary Generation (Stop handler)

The working_on/next_step extraction writes to v1 format. We can either:
- **Option A:** Write to v2 format (add fields to session record)
- **Option B:** Keep separate (summaries are project-level, not session-level)

**Recommendation:** Option B - keep summaries in v1 file or separate file. Session state and project summaries serve different purposes.

## Files to Modify

| File | Change |
|------|--------|
| `~/.claude/scripts/hud-state-tracker.sh` | Main hook - add v2 format support |

## Verification Steps

1. **Before changes:** Run `cargo run -p hud-core --bin state-check` - shows "no sessions in state file"
2. **After changes:**
   - Start a new Claude session in any project
   - Run `state-check` again - should show session with correct state
   - Send a message → verify Working state
   - Stop Claude → verify Ready state
   - Close Claude → verify session removed
3. **Test PermissionRequest:**
   - Trigger a permission prompt
   - Run `state-check` → should show Blocked state
4. **Test PreCompact:**
   - Trigger auto-compaction (large context)
   - Run `state-check` → should show Compacting state

## Rollback Plan

If issues arise:
1. The v1 state file is unchanged - existing Swift app continues working
2. Simply revert the hook script changes
3. Delete `~/.claude/hud-session-states-v2.json`

## Implementation Order

1. Add `STATE_FILE_V2` variable
2. Add v2 file initialization
3. Add `update_state_v2()` function
4. Update PermissionRequest to set `blocked` state
5. Update PostToolUse to read from v2
6. Call `update_state_v2` after `update_state` (dual-write during transition)
7. Test with `state-check`
8. Once verified, can remove v1 writes in future cleanup
