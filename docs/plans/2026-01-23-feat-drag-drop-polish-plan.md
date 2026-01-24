---
title: "feat: Drag-Drop Polish - Mixed Results & Discoverability"
type: feat
date: 2026-01-23
---

# Drag-Drop Polish: Mixed Results & Discoverability

Two UX refinements to the drag-and-drop project linking feature.

## Acceptance Criteria

### Mixed Results Toast

- [ ] When dropping folders with mixed outcomes, show: `"project-a, project-b and X more failed (Y added)"`
- [ ] Errors shown first with names (max 2) + count; successes as suffix count only
- [ ] "Already tracked" projects excluded from counts (they have their own toast: "Already linked!")
- [ ] Pure success = no toast (projects appearing is sufficient feedback)
- [ ] Pure failure = error toast with names + count

**Message format examples:**
- 1 fail, 2 success: `"project-a failed (2 added)"`
- 3 fail, 1 success: `"project-a, project-b and 1 more failed (1 added)"`
- 5 fail, 0 success: `"project-a, project-b and 3 more failed"`

### Empty State Drop Zone

- [ ] When no projects linked, show visual drop zone with dashed border
- [ ] Primary message: "Drag folders here to get started"
- [ ] Keep existing "Link Project" button as secondary option
- [ ] Match existing drop overlay styling: `dash: [8, 6]`, stroke width 2, `hudAccent` at 0.6 opacity
- [ ] Animate in with staggered spring (follow `EmptyProjectsView` pattern)
- [ ] Respect `prefersReducedMotion`

### One-Time Tooltip

- [ ] After first successful button-based add, show tooltip at bottom center
- [ ] Message: "Tip: Drag folders anywhere to add faster"
- [ ] Auto-dismiss after 4 seconds OR tap anywhere to dismiss
- [ ] Persist flag in `@AppStorage("hasSeenDragDropTip")` - shows once ever
- [ ] If toast is showing when tooltip would appear, wait for toast to dismiss first
- [ ] Style: Match toast aesthetic (capsule, `.ultraThinMaterial`, shadow)
- [ ] Animation: Fade in with slight scale (match toast)

**Trigger conditions:**
- ✅ Header → Link Existing → AddProjectView → folder picker → success
- ✅ Empty state "Link Project" button → AddProjectView → success
- ❌ Any drag-drop based add (user already discovered the feature)
- ❌ If `hasSeenDragDropTip` is already true

## Context

**Files to modify:**

| File | Changes |
|------|---------|
| `AppState.swift` | Update `addProjectsFromDrop()` toast logic with truncation and count formatting |
| `ProjectsView.swift` | Update `EmptyProjectsView` to show drop zone visual |
| `ToastView.swift` | No changes needed (existing toast handles new message format) |
| `ContentView.swift` | Add tooltip state, tooltip view, and trigger logic |
| `AddProjectView.swift` | Trigger tooltip callback on successful add |

**Patterns to follow:**

- `EmptyProjectsView` (lines 253-363): Staggered spring animations, reduced motion support
- `ToastView.swift`: Capsule + `.ultraThinMaterial` + shadow styling
- `@AppStorage` pattern from `App.swift`: `@AppStorage("hasSeenDragDropTip") private var hasSeenTip = false`

**New component needed:**

```swift
// TipTooltipView.swift - similar structure to ToastView
struct TipTooltipView: View {
    let message: String
    let onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        // Capsule with tip icon + message
        // 4 second auto-dismiss
        // Tap anywhere gesture
    }
}
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Drop on empty state | Projects appear; no toast unless errors |
| First add via drag-drop | No tooltip (they already know) |
| Tooltip + toast conflict | Toast first, tooltip after toast dismisses |
| Dock layout mode | Tooltip works; empty state N/A (dock is compact view) |
| Already tracked (paused) | Separate "Already linked!" toast; excluded from mixed results count |

## References

- Brainstorm: `docs/brainstorms/2026-01-23-drag-drop-polish-brainstorm.md`
- Existing drop overlay: `ContentView.swift:92-117`
- Empty state pattern: `ProjectsView.swift:253-363`
- Toast pattern: `ToastView.swift`
