# Capacitor Global Storage Migration

**Status:** Done
**Completed:** January 2026

## Summary

Migrated all Capacitor storage from `~/.claude/` to `~/.capacitor/` namespace. This supports the app rename and multi-agent future (not just Claude Code).

## What Was Built

**StorageConfig** (`core/hud-core/src/storage.rs`)
- Centralized path management
- Testable via injection
- Future-ready for XDG, env overrides, cloud sync

## New Structure

```
~/.capacitor/
├── sessions.json           # Active session states
├── projects.json           # Tracked projects list
├── summaries.json          # Session summaries cache
├── project-summaries.json  # AI-generated project descriptions
├── stats-cache.json        # Token usage cache
├── file-activity.json      # File activity for project attribution
├── projects/               # Per-project data
│   └── {encoded-path}/
│       ├── ideas.md
│       └── order.json
├── sessions/               # Lock directories
└── config.json             # App preferences (future)
```

## Migration Mapping

| Old | New |
|-----|-----|
| `~/.claude/hud.json` | `~/.capacitor/projects.json` |
| `~/.claude/hud-session-states-v2.json` | `~/.capacitor/sessions.json` |
| `~/.claude/sessions/` | `~/.capacitor/sessions/` |
| `{project}/.claude/ideas.local.md` | `~/.capacitor/projects/{encoded-path}/ideas.md` |

## Key Design

- **Sidecar principle**: Read from `~/.claude/` (Claude's namespace), write to `~/.capacitor/` (our namespace)
- **Path encoding**: `/` → `-` (e.g., `/Users/pete/Code` → `-Users-pete-Code`)
