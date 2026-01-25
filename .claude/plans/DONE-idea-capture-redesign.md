# Idea Capture Redesign

**Status:** Done
**Completed:** January 2026

## Summary

Redesigned idea capture to separate fast capture (main view) from management (detail view). Added LLM-powered "sensemaking" that transforms raw brain dumps into structured, actionable ideas.

## What Was Built

**Capture Flow**
- "+ Idea" button appears on hover over project cards
- Full-screen overlay with auto-focused text area
- Keyboard: Enter saves, Shift+Enter saves and continues, Escape cancels

**Queue View** (`IdeaQueueView.swift`)
- Flat list of open ideas (no status sections)
- Drag-and-drop reordering with order persistence
- Top item visually emphasized as "next up"

**Detail Modal** (`IdeaDetailModal.swift`)
- Dark frosted glass aesthetic
- Shows full title, description, timestamp
- Remove action

**Background Sensemaking**
- Runs async after capture using Claude Haiku
- Transforms vague input into clear title + description
- Context: project name, recent files, git info
- Graceful fallback if generation fails

## Key Behavior

```
User types: "that auth thing"
    → Sensemaking runs in background
    → Title becomes: "Fix OAuth token refresh timeout"
    → Description: "The refresh token flow needs error handling..."
```

## Files

| Component | Location |
|-----------|----------|
| Capture button | `ProjectCardView.swift` (PeekCaptureButton) |
| Capture overlay | `IdeaCapturePopover.swift` |
| Queue view | `IdeaQueueView.swift` |
| Detail modal | `IdeaDetailModal.swift` |
| Sensemaking | `ProjectDetailsManager.swift` |
| Order storage | `core/hud-core/src/ideas.rs` |

## Deferred (Future)

- "Work On This" flow with agent detection
- Auto-completion detection
- Cross-project clustering
