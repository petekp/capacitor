# Hook Operations Reference

Complete reference for the HUD state tracking hook system: state machine, debugging, and troubleshooting.

## State Machine

```
┌─────────────────────────────────────────────────────┐
│                   State Transitions                  │
└─────────────────────────────────────────────────────┘

SessionStart         → ready
UserPromptSubmit     → working
PreToolUse           → working
PostToolUse          → working
PermissionRequest    → waiting
Notification         → depends on notification_type:
                       - idle_prompt                         → ready
                       - permission_prompt|elicitation_dialog → waiting
                       - other                               → no state change (metadata only)
Stop                 → depends on stop_hook_active:
                       - stop_hook_active=true  → no state change (metadata only)
                       - stop_hook_active=false → ready
PreCompact           → compacting (for ALL trigger values: manual/auto/missing)
SubagentStop         → no state change (metadata only)
SessionEnd           → REMOVED (session deleted from state file)
```

## Event Handlers

| Event | Triggers | Action | Requirements |
|-------|----------|--------|--------------|
| **SessionStart** | Session launch/resume | state=ready | session_id, cwd |
| **UserPromptSubmit** | User submits prompt | state=working | session_id, cwd |
| **PreToolUse** | Before tool execution | state=working | session_id, cwd |
| **PostToolUse** | After tool execution | state=working | session_id, cwd |
| **PermissionRequest** | Claude needs permission | state=waiting | session_id |
| **Notification** | Claude notification | see state machine above | session_id, notification_type |
| **Stop** | Claude finishes responding | state=ready unless stop_hook_active=true | session_id, stop_hook_active |
| **PreCompact** | Before compaction | state=compacting | session_id |
| **SubagentStop** | Subagent finished | metadata only (no state change) | session_id |
| **SessionEnd** | Session ends | Remove session | session_id |

## sessions.json schema (v3)

`hud-state-tracker.sh` writes to `~/.capacitor/sessions.json`:

- **version**: `3`
- **sessions**: map keyed by `session_id`

Each session record contains:

- **Core**: `session_id`, `state`, `cwd`, `updated_at`, `state_changed_at`
- **Metadata** (optional): `transcript_path`, `permission_mode`, `project_dir`, `active_subagent_count`
- **last_event** (optional): `hook_event_name`, `at`, plus safe per-event fields like `tool_name`, `tool_use_id`, `notification_type`, `trigger`, `source`, `reason`, `stop_hook_active`

### Persistence denylist (privacy)

We intentionally do **not** persist sensitive/large fields into `sessions.json`, including:

- `prompt`
- `tool_input` / `tool_response`
- notification `message`
- transcript contents, file contents, or inline diffs
- shell command arguments

## Lock/State Relationship

Claude Code owns lock directories in `~/.claude/sessions/*.lock/`. HUD only **reads** them.

- **Locks indicate liveness** (session is running).
- **sessions.json indicates last known state** and captures hook-derived signals (especially “needs user input”).

When a lock exists but no matching state record is available, HUD defaults to **Ready** for that running session.

---

## Debugging

### Quick Commands

```bash
# View current session states
cat ~/.capacitor/sessions.json | jq .

# Check active lock files
for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] && cat "$lock/meta.json" 2>/dev/null
done | jq -s .

# Run test suite
./scripts/test-hook-events.sh

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

**Check for stale sessions (no recent hook updates):**
```bash
jq -r '.sessions | to_entries[] | "\(.key)\t\(.value.state)\t\(.value.updated_at)\t\(.value.cwd)"' \
  ~/.capacitor/sessions.json
```

---

## Troubleshooting

### Hook Events Not Firing

1. Check hook configuration: `jq '.hooks' ~/.claude/settings.json`
2. Verify hook script exists: `ls -la ~/.claude/scripts/hud-state-tracker.sh`
3. Run test suite (from repo): `./scripts/test-hook-events.sh`

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

**Common root causes:**
- hooks not registered in `~/.claude/settings.json`
- hook script not executable
- state file version mismatch/corruption (delete `~/.capacitor/sessions.json` and retry)

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
3. Do not persist sensitive fields into `sessions.json` (see denylist above)
4. Test with real data, not assumptions

### Warning Signs

🚨 **Assumed fields:** Don't assume trigger/notification_type/cwd exist
🚨 **Schema drift:** Hook script and Rust store must agree on sessions.json v3 schema

### After Modifying Hooks

- [ ] Run test suite: `./scripts/test-hook-events.sh`
- [ ] Test manually with real Claude session
- [ ] Verify in HUD app
- [ ] Update this document if behavior changed

---

## References

- Hook script: `~/.claude/scripts/hud-state-tracker.sh`
- Hook tests (repo): `./scripts/test-hook-events.sh`
- State file: `~/.capacitor/sessions.json`
- Claude Code hook docs: `docs/claude-code/hooks.md`
- ADR-002: Lock handling architecture
