# Idea Capture Redesign

**Date:** 2026-01-18
**Status:** Design complete, ready for implementation
**Supersedes:** `idea-capture-ui-revamp.md` (research phase)

---

## Core Insight

Separate **capture** (main view) from **management** (detail view). Ideas are fleeting thoughts that need to be captured fast before they evaporate. Organization and action come later.

---

## Part 1: Main View Capture

### Interaction

**Trigger:** Click "+ Idea" button on project card

### Entry Point: "+ Idea" Button

**Location:** Project card, in the description line area

**Behavior:**
- **Default state:** Shows project description (LLM-generated "what's happening")
- **On hover:** Description crossfades to "+ Idea" button (secondary/subtle styling)
- **While generating:** Shows dimmed placeholder text, still swaps to button on hover

**Transition:** Same crossfade used when description updates

**Rationale:** The button is discoverable on hover without taking permanent space. The description line is the natural home since it's content that can afford to yield temporarily.

**Popover contents:**
- Text area (~80ch wide, 2-3 lines visible)
- Auto-focused on open
- Save / Cancel buttons

**Keyboard shortcuts:**
- `Return` — Save and close popover
- `Shift+Return` — Save, clear input, stay open for rapid-fire capture
- `Escape` — Cancel and close

**After save:**
- Pill count updates immediately
- Background sensemaking begins (non-blocking)

### Rationale

The hover-swap pattern keeps the card clean at rest while making capture discoverable when engaged. The popover is minimal — no title field, no effort picker, no project selector. Just dump the thought.

The constrained text area (~80ch, 2-3 lines) visually signals "quick jot, not essay" — the size itself discourages paragraph-long screeds.

---

## Part 2: Project Detail View

### Mental Model

**Playlist queue** — A simple ordered list where the top item is "next up." No status groupings, no categories, no hierarchy.

### Display

- Flat list of ideas in priority order
- Top idea is visually emphasized (first in queue)
- Each row shows title only (description revealed on click)
- Drag handles for reordering

### Row Visual Style

**Toned-down project card material** — Same DNA as project cards (subtle gradients, borders, depth) but visually subordinate. Ideas shouldn't compete with the project card hierarchy.

### Idea Detail Modal

**Trigger:** Click an idea row

**Appearance:**
- Dark frosted glass aesthetic (matches app container)
- Anchored to the clicked row (not centered)
- Positioned so dismiss button lands under cursor on open

**Contents:**
- Full description (LLM-generated expansion)
- Metadata (when captured, inferred files, related context)
- Actions ("Work on this", "Remove")

### Interactions

| Action | Behavior |
|--------|----------|
| Drag and drop | Reorder priority (borrow animation from project cards) |
| Click idea | Open detail modal anchored to row |
| Dismiss modal | Click dismiss button (positioned under cursor) |
| Start working | Future: explicit action to begin, agent tracks completion |
| Complete | Future: agent auto-detects, idea disappears (borrow exit animation from project cards) |

### What's Removed

- Status sections (OPEN / IN PROGRESS / DONE)
- Manual status toggles
- The "Done" archive

### Rationale

Status is implicit:
- In the queue = open
- Being worked on = in progress (future: detected by agent)
- Disappeared = done

This eliminates cognitive overhead of managing status while preserving the underlying data model.

---

## Part 3: Background Sensemaking

### Purpose

Turn raw brain dumps into structured, actionable ideas without user effort.

### Trigger

Runs asynchronously after each capture. Non-blocking — user sees "Saving idea..." shimmer, then title updates when ready.

### Adaptive Depth

The model assesses signal level and adjusts expansion accordingly:

| Input Quality | Model Output |
|---------------|--------------|
| Vague ("that auth thing") | Full expansion: clean title, 1-2 sentence description, inferred files/context |
| Moderate ("fix timeout in auth flow") | Clean title, brief description |
| Specific ("In auth.ts:42, handle 401") | Pass-through with normalized formatting |

### Context Provided

**Always include (~75 tokens):**
- Raw idea text
- Project name
- 3-5 most recently touched file paths

**Include during active session (~75 more tokens):**
- Last commit message
- Current branch name
- Brief session summary ("User was working on authentication")

**Cached and reused (amortized):**
- Project summary (regenerate weekly or on significant changes)

**Deferred (expensive, save for batch ops):**
- Other ideas in project (for clustering, dedup, relationships)

### Output Schema

```json
{
  "title": "string — clean, actionable title",
  "description": "string — 1-3 sentences expanding the idea",
  "confidence": "number 0-1 — how confident the model is in its interpretation",
  "inferred_context": {
    "likely_files": ["array of file paths"],
    "related_to": "string — what this seems connected to"
  }
}
```

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Model timeout (>10s) | Save with raw text as title, retry later |
| Low confidence (<0.3) | Flag for user review, don't auto-expand |
| Model unavailable | Save raw, queue for background processing |

---

## Part 4: Deferred Features

These require the foundation above to be working first:

### "Work On This" Flow
- Explicit action to begin working on an idea
- Agent watches session to detect completion
- Completed ideas disappear from queue

### Clustering
- Once ideas are structured via sensemaking, LLM can identify patterns
- User-triggered, not auto-imposed
- Clusters as optional views, not permanent structure

### Cross-Project Intelligence
- Spot patterns across projects ("these 3 ideas touch auth")
- Requires structured ideas + multiple active projects

### Dependency Graphing
- LLM identifies which ideas depend on others
- Auto-sequencing suggestions
- Requires structured ideas with enough detail

---

## Visual Design Summary

| Element | Specification |
|---------|---------------|
| **"+ Idea" button** | Hover-swap replaces description line; secondary/subtle styling; crossfade transition |
| **Description placeholder** | Dimmed text while generating; always auto-generates on project add |
| **Capture popover** | Text area ~80ch wide, 2-3 lines; uses existing popover component |
| **Queue rows** | Toned-down project card material; title only; drag handles |
| **Detail modal** | Dark frosted glass (app container aesthetic); anchored to row; dismiss under cursor |
| **Reorder animation** | Borrow from project card reordering |
| **Exit animation** | Borrow from project card removal |

### Design Principles

1. **Hierarchy matters** — Idea rows are subordinate to project cards
2. **Reuse existing patterns** — Popover, transitions, animations from existing components
3. **Progressive disclosure** — Title visible, detail on demand via modal
4. **Cursor-aware positioning** — Modal dismiss button lands where user already is

---

## Implementation Sequence

### Phase 1: Capture Flow
1. Add "+ Idea" button with hover-swap on project card description line
2. Implement capture popover (text area, ~80ch, keyboard shortcuts)
3. Wire up to existing `capture_idea()` Rust function
4. Add dimmed placeholder for generating state

### Phase 2: Detail View Simplification
1. Restyle `IdeaCardView` with toned-down project card material
2. Replace `IdeasListView` status sections with flat queue (title only)
3. Add drag-and-drop reordering with project card animations
4. Persist order (new field in ideas.local.md or separate ordering)

### Phase 3: Idea Detail Modal
1. Create `IdeaDetailModal` with dark frosted glass styling
2. Implement anchored positioning (dismiss button under cursor)
3. Display description, metadata, and actions
4. Wire up "Work on this" and "Remove" actions

### Phase 4: Background Sensemaking
1. Design prompt for signal assessment + adaptive expansion
2. Implement async title/description generation after capture
3. Add context gathering (recent files, session info)
4. Handle errors gracefully

### Phase 5: Polish
1. Ensure description always auto-generates on project add
2. Tune transitions and animations for consistency
3. Age indicators for stale ideas (future)

---

## Technical Notes

### Files to Modify

| Component | File | Changes |
|-----------|------|---------|
| "+ Idea" hover swap | `Views/Projects/ProjectCardView.swift` | Description line swaps to button on hover |
| Capture popover | New: `Views/Ideas/IdeaCapturePopover.swift` | Text area + keyboard shortcuts |
| Queue rows | `Views/Ideas/IdeasListView.swift` | Replace status sections with flat queue |
| Row styling | `Views/Ideas/IdeaCardView.swift` | Toned-down project card material |
| Detail modal | New: `Views/Ideas/IdeaDetailModal.swift` | Frosted glass, anchored positioning |
| Drag reordering | `Views/Ideas/IdeasListView.swift` | Add `onMove` handler + animation |
| Order persistence | `core/hud-core/src/ideas.rs` | Add order field or separate file |
| Sensemaking | `apps/sdk-bridge/` or new service | Async LLM calls |

### Data Model Changes

Current idea structure in `ideas.local.md`:
```markdown
### [#idea-ULID] Title
- **Added:** timestamp
- **Effort:** unknown
- **Status:** open
- **Triage:** pending
- **Related:** None

Description text
```

Add:
```markdown
- **Order:** 1
- **Description:** LLM-generated expansion (distinct from raw input)
```

Or: Store order separately to avoid churning the markdown on every reorder.

---

## Success Criteria

1. **Capture in <2 seconds** — Click pill, type thought, Enter. Done.
2. **Ideas feel alive** — Sensemaking transforms dumps into clear items
3. **Queue is obvious** — Top = next, drag = reprioritize, done = gone
4. **Zero status management** — No clicking checkboxes or moving between columns

---

## Open Questions

1. **Order persistence format** — Inline in markdown vs. separate JSON?
2. **Sensemaking model** — Haiku for speed, or Sonnet for quality?
3. **Completion detection** — How does the agent know when you're done? (Deferred)

---

*Design session: 2026-01-18*
