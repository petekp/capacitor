# Activity-Based Project Tracking

**Status:** Done
**Completed:** January 2026

## Summary

Solved monorepo blindness: when Claude runs from a monorepo root but edits files in packages, Capacitor now correctly shows which package is active by tracking file activity and attributing it to project boundaries.

## What Was Built

**Project Boundary Detection** (`core/hud-core/src/boundaries.rs`)
- Walks up from file paths to find nearest project marker
- Priority: CLAUDE.md > .git > package.json/Cargo.toml/etc.
- Ignores node_modules, vendor, target, etc.

**File Activity Tracking** (`core/hud-core/src/activity.rs`)
- Records file edits with project attribution
- 5-minute activity threshold for "Working" state
- Atomic writes, crash-safe

**Smart Project Validation** (`core/hud-core/src/validation.rs`)
- Validates paths with helpful suggestions
- CLAUDE.md template generation

## Key Behavior

```
Claude edits /monorepo/packages/auth/src/login.ts
    → Activity recorded for /monorepo/packages/auth/
    → HUD shows packages/auth as "Working" ✓
```

## Files

| Module | Location |
|--------|----------|
| Boundaries | `core/hud-core/src/boundaries.rs` |
| Activity | `core/hud-core/src/activity.rs` |
| Validation | `core/hud-core/src/validation.rs` |
| Integration | `core/hud-core/src/sessions.rs` |
