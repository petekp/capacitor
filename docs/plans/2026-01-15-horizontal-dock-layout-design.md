# Horizontal Dock Layout Design

**Date:** 2026-01-15
**Status:** Approved
**Related Idea:** #idea-01KF1SKSB7D6AZVCPN6E3R6T6Z

## Overview

Add an alternative horizontal dock layout to Claude HUD. Users can manually toggle between the existing vertical layout and a new horizontal dock with compact, squarish cards.

This is a **layout-only** change. Visual styling (frosted glass, status indicators, typography, glow effects) remains identical to the current implementation.

## Goals

1. Provide a dock-style layout for users who prefer horizontal orientation
2. Support placement at screen edges (starting with bottom dock use case)
3. Maintain all existing functionality in a more compact card format
4. Enable comfortable multi-project visibility in a single horizontal row

## Non-Goals (This Pass)

- New visual aesthetics (OLED insets, tape deck metaphors, etc.)
- Automatic layout switching based on window shape
- "Up next" idea queue display (future exploration)
- Placement at all screen edges (start with horizontal only)

---

## Design Details

### Card Proportions

**Current cards:** Wide rectangles (~4:1 aspect ratio), designed for vertical stacking.

**Dock cards:** Compact rectangles (~3:2 aspect ratio, landscape). More square than current, but still wider than tall.

**Content adaptation:**

| Element | Current Layout | Dock Layout |
|---------|---------------|-------------|
| Project name | Top, full width | Top, truncates earlier |
| Status indicator | Right side | Right of name (same row) |
| Summary text | Below name, multi-line | Below name, 1-2 lines max |
| Blocker | Below summary | Below summary, compact |
| Dev server port | Badge near status | Badge near status |

**Target dimensions:** ~120-150pt wide × ~80-100pt tall (tuned during implementation for comfortable tap targets).

### Dock Arrangement

- **Direction:** Left-to-right horizontal flow
- **Spacing:** 12-16pt gap between cards
- **Alignment:** Cards vertically centered in dock window
- **Scroll:** Paged snap-scroll (no half-visible cards)

### Pagination

- **Dot indicators:** Below cards, showing current page position
- **Edge peek:** ~20pt sliver of next/previous card visible at page boundaries
- **Interaction:** Swipe or scroll-wheel moves between pages

### Window Constraints

**Vertical mode (unchanged):**
- Min width: ~280pt
- Max width: ~400pt
- Height: Flexible based on content

**Dock mode (new):**
- Min width: ~400pt (fits 2-3 cards)
- Max width: ~1200pt (fits 6-8 cards)
- Min height: ~120pt
- Max height: ~180pt

Card count per page adjusts dynamically based on available width.

### Mode Switching

**Toggle mechanism:**
- View menu: `View → Vertical Layout` / `View → Dock Layout`
- Keyboard shortcuts: `⌘1` (Vertical), `⌘2` (Dock)

**Behavior on switch:**
1. Persist choice across app restarts
2. If window size invalid for new mode, animate resize to nearest valid size
3. Window position stays in place; only size adjusts

---

## Implementation Plan

### New Files

| File | Purpose |
|------|---------|
| `DockLayoutView.swift` | Horizontal card arrangement with paged ScrollView |
| `DockProjectCard.swift` | Compact 3:2 card variant |

### Modified Files

| File | Changes |
|------|---------|
| `ContentView.swift` | Layout mode state, conditional rendering between vertical/dock |
| `App.swift` | Menu items for layout toggle, keyboard shortcuts |
| `AppState.swift` | Persist `layoutMode` preference |

### Reused As-Is

- `ProjectCardView.swift` styling components (frosted glass, glow, etc.)
- `StatusIndicatorView.swift`
- `Typography.swift`
- All interaction handlers (tap, hover, context menu, drag)

### Implementation Order

1. **AppState + persistence** — Add `layoutMode` enum and persist to UserDefaults
2. **Menu items** — Add View menu toggles with keyboard shortcuts
3. **DockProjectCard** — Create compact card variant reusing existing styling
4. **DockLayoutView** — Horizontal paged scroll container
5. **ContentView integration** — Conditional rendering based on mode
6. **Window constraints** — Enforce min/max per mode
7. **Polish** — Pagination dots, edge peek, animations

---

## Future Exploration

After this foundation ships, potential enhancements:

- **"Up next" display** — Show queued idea with play/record metaphor
- **Hardware aesthetics** — OLED inset screens, LED-style indicators
- **Edge placement** — Support top, left, right dock positions
- **Auto-hide** — Dock slides away when not in use

---

## Open Questions

1. **Exact card dimensions** — Will tune during implementation based on feel
2. **Pagination dot style** — Match existing UI or more subtle?
3. **Transition animation** — Simple crossfade or cards visibly reflow?

---

## Appendix: Inspiration References

- Elektron Digitakt/Octatrack — OLED screens, minimal text, accent colors
- Teenage Engineering OP-1/EP-133 — Playful density, lo-fi charm
- Ableton Push — Grid-based, clean gradients, studio aesthetic
- Vintage rack gear (Lexicon, Eventide) — LCD displays, utilitarian density

Visual styling exploration deferred to future pass.
