# Status Sync System Architecture

> Reference document for the real-time status synchronization system between Claude Code sessions and HUD clients (desktop/mobile).

## Overview

The status sync system enables real-time visibility into Claude Code session states across devices. When Claude is working, waiting, or ready in a terminal, the HUD app reflects this immediately.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CLAUDE CODE HOST                                   │
│  ┌─────────────┐    ┌──────────────────────┐    ┌─────────────────────┐    │
│  │   Hooks     │───▶│ hud-state-tracker.sh │───▶│ State File (JSON)   │    │
│  │ (7 events)  │    │ (state transitions)  │    │ ~/.claude/hud-      │    │
│  └─────────────┘    └──────────────────────┘    │ session-states.json │    │
│                              │                   └─────────────────────┘    │
│                              ▼ (triggers)                                    │
│                     ┌──────────────────────┐                                │
│                     │ publish-state.sh     │                                │
│                     │ (debounce 400ms)     │────────┐                       │
│                     └──────────────────────┘        │                       │
│                                                     │ HTTP POST             │
│  ┌─────────────────────────────────────────┐       │ /api/v1/state         │
│  │ StatusLine (continuous while working)   │       │                       │
│  │ - Updates context window info           │       │                       │
│  │ - Sends heartbeats (2s rate limit)      │───────┼─▶ /api/v1/heartbeat   │
│  └─────────────────────────────────────────┘       │                       │
└────────────────────────────────────────────────────┼───────────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CLOUDFLARE RELAY (Durable Object)                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ HudSession                                                           │   │
│  │ - Persists last state to storage                                    │   │
│  │ - Broadcasts state_update + heartbeat to WebSocket clients          │   │
│  │ - Ping alarm every 30s (hibernation-safe)                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────┬────────────────────────┘
                                                     │ WebSocket
                                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           HUD CLIENTS                                        │
│  ┌──────────────────┐    ┌─────────────────────────────────────────────┐   │
│  │ RelayClient      │───▶│ AppState                                    │   │
│  │ - WebSocket conn │    │ - sessionStates (from relay state_update)  │   │
│  │ - projectHearts  │    │ - getSessionState() with staleness check   │   │
│  │ - reconnect      │    │ - 1s timer triggers re-evaluation          │   │
│  └──────────────────┘    └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## State Machine

### States

| State | Meaning | UI Color | Source |
|-------|---------|----------|--------|
| `idle` | No active session | Gray | Hook |
| `ready` | Claude waiting for input | Green | Hook |
| `working` | Claude actively processing | Orange/Amber | Hook |
| `waiting` | Stale "working" (user interrupted) | Yellow | **Client-side synthesis** |
| `compacting` | Auto-compacting context | Tan | Hook |

### Transitions

| Hook Event | Trigger | State Change | Publishes? |
|------------|---------|--------------|------------|
| `SessionStart` | Session begins | → `ready` | ✅ |
| `UserPromptSubmit` | User sends message | → `working` | ✅ |
| `PermissionRequest` | Tool needs approval | (no change) | ❌ |
| `PostToolUse` | Tool completed | `compacting`→`working` only | ✅ (conditional) |
| `Stop` | Claude finishes response | → `ready` | ✅ |
| `SessionEnd` | Session terminates | (no change) | ❌ |
| `PreCompact` | Auto-compact starts | → `compacting` | ✅ (if trigger=auto) |
| `Notification` | `idle_prompt` (60s idle) | → `ready` | ✅ |

## Key Design Decisions

### 1. Why "waiting" is Client-Side Only

**Problem:** Claude Code has no hook for user interrupts (Ctrl+C, Escape). The only signal is `idle_prompt` which fires after 60 seconds of inactivity - far too slow for good UX.

**Solution:** Heartbeat-based staleness detection:
- StatusLine sends heartbeats every 2 seconds while state is "working"
- Clients track the most recent heartbeat per project
- If no heartbeat for 5+ seconds, client synthesizes "waiting" state
- This detects interrupts within ~5-6 seconds instead of 60

### 2. Why Heartbeats Use Prefix Matching

**Problem:** Heartbeats are sent with exact `cwd` (e.g., `/Code/project/apps/swift`) but projects are pinned at root paths (e.g., `/Code/project`).

**Solution:** Client uses prefix matching:
```swift
lastHeartbeat = relayClient.projectHeartbeats
    .filter { $0.key.hasPrefix(project.path) }
    .map { $0.value }
    .max()
```

### 3. Why PostToolUse Handles Compacting→Working

**Problem:** After auto-compaction ends, no hook fires to resume "working" state. Claude just starts using tools again.

**Solution:** `PostToolUse` checks if current state is "compacting" and transitions to "working", since tool use is a clear signal work has resumed.

### 4. Why We Track Connection Time

**Problem:** If mobile connects after desktop interrupted Claude:
- Relay still has "working" state
- No heartbeats arrive (Claude is stopped)
- Mobile would show "working" forever

**Solution:** Track `connectedAt`. If "working" with no heartbeats AND connected >5s, treat as stale.

### 5. Why PermissionRequest Doesn't Change State

**Problem:** Early implementation set state to "waiting" on PermissionRequest, causing flicker.

**Solution:** PermissionRequest exits without changing state. Permissions happen during active work - the user is still engaged, Claude is still "working" conceptually.

### 6. Why SessionEnd Doesn't Set Idle

**Problem:** SessionEnd fires immediately after Stop, which would overwrite "ready" with "idle".

**Solution:** SessionEnd just exits without changing state, preserving the "ready" state from Stop.

## File Locations

### Host Machine (~/.claude/)

| File | Purpose |
|------|---------|
| `hud-session-states.json` | Current state for all projects |
| `hud-relay.json` | Relay config (url, deviceId, secretKey) |
| `hud-last-heartbeat` | Unix timestamp of last heartbeat sent |
| `hud-publish-debug.log` | Debug log for publish-state.sh |
| `hud-hook-debug.log` | Debug log for hud-state-tracker.sh |
| `scripts/hud-state-tracker.sh` | State machine implementation |
| `hooks/publish-state.sh` | Debounced relay publishing |
| `statusline-command.sh` | Context updates + heartbeat sending |
| `settings.json` | Hook configuration |

### Relay (apps/relay/)

| File | Purpose |
|------|---------|
| `src/index.ts` | Route handling, Durable Object binding |
| `src/durable.ts` | HudSession Durable Object (WebSocket, state, heartbeat) |
| `src/types.ts` | TypeScript type definitions |

### Swift Client (apps/swift/)

| File | Purpose |
|------|---------|
| `Utils/RelayClient.swift` | WebSocket connection, heartbeat tracking, reconnection |
| `Models/AppState.swift` | State management, staleness detection |

## Timing Parameters

| Parameter | Value | Location |
|-----------|-------|----------|
| Heartbeat interval | 2 seconds | statusline-command.sh |
| Staleness threshold | 5 seconds | AppState.swift |
| Staleness check interval | 1 second | AppState.swift (timer) |
| Publish debounce | 400ms | publish-state.sh |
| Relay ping interval | 30 seconds | durable.ts (alarm) |
| Reconnect backoff | 2^n seconds, max 60s | RelayClient.swift |
| Heartbeat cleanup age | 24 hours | RelayClient.swift |

## Robustness Features

1. **Debounce Pattern** - Last-writer-wins prevents rapid-fire publishes
2. **Atomic Writes** - tmp file + mv for state file updates
3. **Infinite Reconnection** - Exponential backoff, never gives up
4. **Connection Time Tracking** - Handles "connect after interrupt" edge case
5. **Heartbeat Cleanup** - Prunes old entries on reconnect
6. **State File Recovery** - Auto-repairs corrupted JSON
7. **jq Dependency Check** - Scripts verify jq is available
8. **Summary Generation Isolation** - `HUD_SUMMARY_GEN=1` prevents recursive hooks

## Debugging

### Check current state
```bash
cat ~/.claude/hud-session-states.json | jq .
```

### Watch hook activity
```bash
tail -f ~/.claude/hud-hook-debug.log
```

### Watch publish activity
```bash
tail -f ~/.claude/hud-publish-debug.log
```

### Test heartbeat endpoint
```bash
curl -X POST https://your-relay.workers.dev/api/v1/heartbeat/your-device-id \
  -H "Content-Type: application/json" \
  -d '{"project":"/path/to/project","timestamp":"2024-01-01T00:00:00Z"}'
```

### Force state refresh
```bash
# Trigger a state publish manually
echo '{}' | ~/.claude/hooks/publish-state.sh
```

## Common Issues

### "Working" stuck after interrupt
- Check heartbeats are being sent: `tail -f ~/.claude/hud-hook-debug.log`
- Verify relay is receiving: check publish debug log
- Confirm WebSocket connected: check Swift console

### State not updating
- Verify hooks are configured in `~/.claude/settings.json`
- Check jq is installed: `which jq`
- Look for errors in debug logs

### Mobile shows wrong state
- Check `connectedAt` is being set (RelayClient.swift)
- Verify staleness threshold timing
- Confirm heartbeats are being received via WebSocket

---

*Last updated: January 2025*
*Related: [Claude Code Hooks docs](../docs/cc/hooks.md)*
