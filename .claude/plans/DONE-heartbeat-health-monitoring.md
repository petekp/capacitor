# Heartbeat-Based Hook Health Monitoring

**Status:** Done
**Completed:** January 2026

## Summary

Added runtime detection for when hooks stop firing mid-session, alerting users before they encounter stale state.

## Problem Solved

Hooks can silently stop due to:
- Binary killed by macOS (SIGKILL on unsigned code)
- Crashes or corruption
- Claude Code process anomalies

Previously, users only discovered issues when seeing stale state.

## What Was Built

**Hook Binary** (`core/hud-hook/src/handle.rs`)
- Touches `~/.capacitor/hud-hook-heartbeat` on every event
- Contains Unix timestamp of last update

**Rust Core** (`core/hud-core/src/engine.rs`)
- `check_hook_health()` API
- Returns: Healthy, Unknown, Stale, or Unreadable
- 60-second staleness threshold

**Swift UI** (`HookHealthBanner.swift`)
- Warning banner when hooks are stale
- Shows time since last heartbeat
- "Retry" action button

## Key Behavior

```
Hooks stop firing
    → 60 seconds pass
    → HUD shows: "Hooks stopped responding 2m ago [Retry]"
```

## Files

| Component | Location |
|-----------|----------|
| Heartbeat touch | `core/hud-hook/src/handle.rs` |
| Health check | `core/hud-core/src/engine.rs` |
| Types | `core/hud-core/src/types.rs` (HookHealthStatus, HookHealthReport) |
| Banner UI | `HookHealthBanner.swift` |
