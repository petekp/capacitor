# Idea Capture UI Revamp

**Status:** Research phase
**Created:** January 16, 2026
**Supersedes:** `idea-capture-ui-integration.md` (Phase 1A complete, this is the next evolution)

---

## Problem Statement

The current Idea Capture UI has usability issues discovered during first real-world usage:

1. **Ideas consume too much space** — 5+ ideas under a project card takes as much vertical space as 5 project cards, harming the "rapid 0→1 exploration" goal
2. **Add button is not discoverable** — Users repeatedly forget the small Add button exists
3. **Naming confusion** — "New Idea" creates a project (heavyweight), "Add Project" imports existing (confusing verb)

---

## Design Decisions (Confirmed)

### Priority Ordering

**Phase 1:** User-ordered via drag-and-drop
- Grip handle always visible on left (signals draggability)
- Edit and remove actions appear on hover
- Top item = "next in priority"

**Phase 2 (future):** Claude-driven auto-sequencing based on:
- Product area relationships
- File dependency trees
- Effort estimation
- Holistic ordering (fresh ideas may be deprioritized for coherence)

### Naming Changes

Choose one of:
- **Option A:** "Start Project" / "Add Existing"
- **Option B:** "New Project" / "Link Project"

Both are clear improvements. Finalize during implementation.

### Add Idea Entry Points

Multiple redundant entry points for discoverability:
- On the "next idea" pill itself (small + icon)
- Inside the expanded overlay
- On the project card (more prominent than current)
- Keyboard shortcut (e.g., ⌘+I when project focused)

### Row Affordances

- **Grip handle:** Always visible (left side)
- **Edit action:** Hover-reveal
- **Remove action:** Hover-reveal

---

## Open Design Questions

### Overlay Expansion Pattern

**The core interaction:** Click "next idea" pill → expanded list appears

**Options to research:**
1. Anchored dropdown — Expands from/below the pill
2. Project card takeover — Overlay covers card, ideas replace content
3. Side panel slide — Slides in from right, card stays visible
4. Modal center-screen — Traditional modal with dimmed background

**Decision:** Requires prior art research before committing.

---

## Research Phase

### Scope

Broad survey with emphasis on creative/adventurous patterns:

| Category | Examples to Study |
|----------|-------------------|
| macOS native | Finder, Notes, Reminders — inline expansion, popovers |
| Productivity tools | Linear, Notion, Things, Todoist — compact list → detail transitions |
| Design systems | Apple HIG, Material Design — progressive disclosure guidance |
| Developer tools | Xcode, VS Code — expandable panels, popovers |

### Research Questions

1. How do the best apps handle "collapsed summary → expanded detail" transitions?
2. What animation patterns feel native to macOS while being distinctive?
3. How do apps signal "there's more here" without visual clutter?
4. What patterns support drag-and-drop reordering within an overlay/popover?

### Deliverable

Document findings with screenshots/recordings. Synthesize into 2-3 candidate patterns to prototype.

---

## Implementation Phases

### Phase 1: Research
- [ ] Survey prior art (macOS native, productivity, design systems, dev tools)
- [ ] Document findings with visual examples
- [ ] Synthesize into 2-3 candidate overlay patterns
- [ ] Choose pattern (may require quick prototypes)

### Phase 2: Naming Changes (Quick Win)
- [ ] Rename "New Idea" → "Start Project" or "New Project"
- [ ] Rename "Add Project" → "Add Existing" or "Link Project"
- [ ] Update any related UI copy

### Phase 3: Ideas Display Overhaul
- [ ] Replace inline `IdeaCardView` list with "next idea" pill
- [ ] Implement chosen overlay pattern
- [ ] Add grip handles for drag-and-drop
- [ ] Implement reordering persistence
- [ ] Add hover-reveal edit/remove actions

### Phase 4: Add Idea Discoverability
- [ ] Add + icon to next idea pill
- [ ] Add prominent capture button to project card
- [ ] Ensure Add button in overlay
- [ ] Implement keyboard shortcut (⌘+I or similar)

---

## Technical Notes

### Current Implementation (for reference)

| Component | File | Purpose |
|-----------|------|---------|
| `InlineIdeasList` | `Views/Ideas/InlineIdeasList.swift` | Current inline display (to be replaced) |
| `IdeaCardView` | `Views/Ideas/IdeaCardView.swift` | Individual idea rendering |
| `TextCaptureView` | `Views/Ideas/TextCaptureView.swift` | Modal for capturing ideas |
| `IdeasListView` | `Views/Ideas/IdeasListView.swift` | Full-page ideas view (project detail) |

### Existing Patterns to Leverage

- `.ultraThinMaterial` background for glassy overlays (used in `TextCaptureView`)
- Hover-reveal action bars (used in `IdeaCardView`)
- Spring animations for transitions
- Collapsible sections with chevron toggle

---

## Success Criteria

1. **Space efficiency:** 5+ ideas take ≤1 row of vertical space when collapsed
2. **Discoverability:** New users find "add idea" within 5 seconds of looking at a project
3. **Naming clarity:** Zero confusion about "new project" vs "import existing"
4. **Delight:** The overlay interaction feels polished and distinctly "Claude HUD"

---

## Alignment with Vision

From `hud-vision-jan-2026.md`:

> "An always-visible side strip... collapsed shows mini project cards; click expands detail panel"

This revamp aligns directly: ideas collapse to a minimal "next idea" pill, expand on demand. Progressive disclosure, not information overload.

---

*Interview conducted: January 16, 2026*
