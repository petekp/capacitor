# Idea Capture Overlay Pattern Research

**Created:** January 16, 2026
**Purpose:** Inform the overlay expansion pattern for the Idea Capture UI revamp
**Companion to:** `idea-capture-ui-revamp.md`

---

## Research Summary

Surveyed patterns across macOS native apps, productivity tools, design systems, and developer tools. Focus was on **creative and adventurous** patterns that could make Claude HUD feel distinctive while remaining functionally excellent.

---

## Pattern Catalog

### 1. Things 3: In-Place Unfolding

**What it does:**
When you tap a todo in Things 3, it "smoothly transforms into a clear white piece of paper." The item expands in place, pushing other items down, revealing additional fields (tags, checklist, dates) that are "neatly tucked away until you need them."

**Why it's interesting:**
- Custom animation toolkit built specifically for this
- Keeps spatial context—you never lose your place in the list
- Called "one of the most beautiful Mac and iOS apps ever" with "deeply satisfying animations"
- Two Apple Design Awards for design quality

**Applicability to Claude HUD:**
High. The "next idea pill → expanded list" could use this pattern: pill morphs in place, ideas list unfolds below it, project card pushes down slightly.

**Tradeoffs:**
- Requires careful attention to surrounding layout (what moves, what stays)
- More complex to implement than a simple overlay

**Source:** [Things 3 Features](https://culturedcode.com/things/features/)

---

### 2. Linear: Expandable Navigation

**What it does:**
Linear's tab bar can "expand to accommodate additional entries, similar to how the tab bar can turn into a sidebar on iPad." Their UI is described as "inverted L-shape"—global chrome controlling content.

**Why it's interesting:**
- Acknowledges users need more than 5 items
- Flexible and adaptable depending on user's role
- Clean, technical aesthetic that appeals to developers

**Applicability to Claude HUD:**
Medium. The flexibility principle applies—your ideas list should gracefully handle 2 items or 20. But Linear's pattern is more about navigation than content expansion.

**Source:** [Linear UI Redesign](https://linear.app/now/how-we-redesigned-the-linear-ui)

---

### 3. Notion: Row-to-Page Expansion

**What it does:**
Hover over any database row → "Open" button appears → click to open row as full page. Page can appear as:
- Side panel (slide in from right)
- Center modal
- Full page

User controls this via settings. The page has properties at top, free content space below.

**Why it's interesting:**
- Multiple presentation modes for different contexts
- Progressive disclosure: summary in list, full detail on demand
- Row includes grip handle (⋮⋮) for drag-and-drop reordering

**Applicability to Claude HUD:**
High for the ideas list inside the overlay. Each idea row could expand to show full description, and the grip pattern matches your requirement exactly.

**Tradeoffs:**
- Three modes might be overkill for Claude HUD's simpler needs
- The "Open" button appearing on hover adds friction vs. always-visible tap target

**Source:** [Notion Table View Help](https://www.notion.com/help/tables)

---

### 4. Command Palette (Raycast, Linear, VS Code)

**What it does:**
Keyboard shortcut → floating panel appears center-screen. Search input at top, dynamic results below. "Not just for finding things—for doing things."

**Why it's interesting:**
- Raycast specifically: "sleek and modern interface," "smooth animations that don't feel gratuitous," uses native Mac technologies so it's fast
- Context-aware: shows different commands based on what you're doing
- Disappears after action—ephemeral by design

**Applicability to Claude HUD:**
Medium for the overlay itself (you want something anchored to the project, not center-screen), but HIGH for quick-capture. A ⌘+I → type idea → enter flow would be very Raycast-like.

**Source:** [Command Palette Interfaces](https://philipcdavis.com/writing/command-palette-interfaces), [Raycast for Mac](https://albertosadde.com/blog/raycast)

---

### 5. Arc Browser: Sidebar Transformation

**What it does:**
Collapsible sidebar houses vertical tabs, pinned favorites, and tools. "Merges bookmarks and open tabs in one place." Split view creates a new tab entity that you can return to later.

**Why it's interesting:**
- Written in Swift/SwiftUI—"fluid, native feel"
- Split view is first-class: drag tab onto another, they tile side-by-side
- Tabs auto-close after 12 hours unless pinned (automatic cleanup)
- "Fresh aesthetic, theming engine, animations feel modern"

**Applicability to Claude HUD:**
Medium. The sidebar model doesn't directly apply, but the principle of "creating entities from combinations" is interesting—what if a set of ideas could become a saved "focus group" you return to?

**Source:** [Arc for Designers](https://www.hackdesign.org/toolkit/arc-browser/)

---

### 6. App Store Card Animation (matchedGeometryEffect)

**What it does:**
SwiftUI's native pattern for morphing between compact and expanded states. Card in list → tap → card animates to full screen, content fills in. Uses `@Namespace` and `matchedGeometryEffect`.

**Why it's interesting:**
- Native SwiftUI—no custom animation framework needed
- "Hero transition" feel: position, size, shape all interpolate smoothly
- WWDC 2024 recommends "zoom transitions" for large cell → detail transitions

**Applicability to Claude HUD:**
Very high. The pill → overlay transition is a perfect use case. Pill morphs into overlay container, content animates in.

**Implementation hint:**
```swift
withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
    isExpanded.toggle()
}
```

**Source:** [App Store-Style Card Animations](https://medium.com/@charithgunasekera/crafting-app-store-style-card-animations-with-swiftui-12cc3257928e), [WWDC 2024 Transitions](https://developer.apple.com/videos/play/wwdc2024/10145/)

---

### 7. List Inlay Pattern

**What it does:**
Amazon mobile reviews: each item shows capsule summary, tapping expands in place to show full text + details. Multiple items can be expanded simultaneously OR single-expand mode.

**Why it's interesting:**
- No modal, no overlay—purely in-place
- User maintains context of where they are in the list
- Natural for scanning + drilling down

**Applicability to Claude HUD:**
Medium. Works inside an ideas overlay but probably not for the pill→overlay transition itself.

**Source:** [flow|state: ListInlay Pattern](https://miksovsky.blogs.com/flowstate/2012/01/listinlay.html)

---

### 8. Apple HIG: Progressive Disclosure (2025)

**What it does:**
"Keeps interfaces lean." Introduce features when users need them, not before. For data-rich environments: "segment data using card layouts with visual anchors and progressive disclosure."

**Liquid Glass (macOS 26):**
New design language emphasizing "translucency, depth, and fluid responsiveness." Meant for top-level controls like toolbars and tab bars.

**Why it's interesting:**
- Official guidance validates the "collapsed by default, expand on demand" approach
- Liquid Glass aesthetic could inform the overlay's visual treatment
- Warning: Liquid Glass is "meant for top-level controls"—applying it to content areas may feel wrong

**Applicability to Claude HUD:**
High for philosophy, medium for Liquid Glass specifically. Use `.ultraThinMaterial` for the overlay background (you already do this), but don't over-apply glass effects to content.

**Source:** [Apple HIG Disclosure Controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)

---

## Candidate Patterns for Claude HUD

Based on the research, here are 4 candidate approaches ranked by adventurousness:

### Candidate A: Morphing Pill (Most Adventurous)

**Inspired by:** Things 3 + App Store card animation

**Behavior:**
1. "Next idea" pill sits below project card (compact, single line)
2. Click pill → it morphs/grows into a rounded panel using `matchedGeometryEffect`
3. Panel expands in place, pushing project card up or overlay floating above
4. Ideas list animates in with staggered fade
5. Click outside or collapse button → morphs back to pill

**Visual:**
```
┌─────────────────────────────────────┐
│ Project Card                        │
└─────────────────────────────────────┘
    ┌──────────────────────────┐
    │ 💡 Fix auth timeout  [+] │  ← Pill (collapsed)
    └──────────────────────────┘

        ↓ click ↓

┌─────────────────────────────────────┐
│ Project Card                        │
└─────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ Ideas                              [−]  │
├─────────────────────────────────────────┤
│ ⋮⋮  Fix auth timeout           ✏️  ✕   │
│ ⋮⋮  Add retry logic            ✏️  ✕   │
│ ⋮⋮  Update error messages      ✏️  ✕   │
│─────────────────────────────────────────│
│                [+ Add Idea]             │
└─────────────────────────────────────────┘
```

**Pros:**
- Feels magical, distinctly "Claude HUD"
- Maintains spatial context
- Uses native SwiftUI patterns

**Cons:**
- Requires careful layout math
- Pushing project card might feel disruptive

---

### Candidate B: Anchored Floating Panel

**Inspired by:** Raycast + Notion side peek

**Behavior:**
1. Click pill → glassy panel floats out from pill, anchored to it
2. Panel has subtle shadow, appears above other content (no push)
3. Click outside → panel fades out

**Visual:**
```
┌─────────────────────────────────────┐
│ Project Card                        │
└─────────────────────────────────────┘
    ┌──────────────────────────┐
    │ 💡 Fix auth timeout  [+] │
    └───────────┬──────────────┘
                │
    ╭───────────▼───────────────────╮
    │ Ideas                    [−]  │
    ├───────────────────────────────┤
    │ ⋮⋮  Fix auth timeout     ✏️ ✕ │
    │ ⋮⋮  Add retry logic      ✏️ ✕ │
    │ ⋮⋮  Update error msgs    ✏️ ✕ │
    │───────────────────────────────│
    │         [+ Add Idea]          │
    ╰───────────────────────────────╯
```

**Pros:**
- Doesn't disrupt layout
- Feels light and dismissible
- Popover-like familiarity

**Cons:**
- Might feel disconnected from the project card
- Z-fighting concerns if multiple projects visible

---

### Candidate C: Slide-In Side Panel

**Inspired by:** Arc browser sidebar + Figma overlays

**Behavior:**
1. Click pill → panel slides in from right edge
2. Project card remains visible on left, ideas panel on right
3. Panel can be resized or dismissed

**Visual:**
```
┌──────────────────────────┬─────────────────────────┐
│ Project Card             │ Ideas               [×] │
│                          ├─────────────────────────┤
│                          │ ⋮⋮ Fix auth timeout ✏️✕│
│                          │ ⋮⋮ Add retry logic  ✏️✕│
│                          │ ⋮⋮ Update error msg ✏️✕│
│                          │─────────────────────────│
│                          │      [+ Add Idea]       │
└──────────────────────────┴─────────────────────────┘
```

**Pros:**
- Clear spatial separation
- Good for longer editing sessions
- Natural for drag-and-drop within panel

**Cons:**
- Feels heavier, more committed
- Might not fit narrow HUD panel form factor
- Less "quick glance" feeling

---

### Candidate D: In-Place Accordion (Simplest)

**Inspired by:** List Inlay + Apple HIG progressive disclosure

**Behavior:**
1. Ideas section is always visible but collapsed (just header + count badge)
2. Click → section expands in place, ideas rows appear
3. Click header again → collapses

**Visual:**
```
┌─────────────────────────────────────┐
│ Project Card                        │
├─────────────────────────────────────┤
│ 💡 Ideas (3)                    ▼   │  ← Collapsed
└─────────────────────────────────────┘

        ↓ click ↓

┌─────────────────────────────────────┐
│ Project Card                        │
├─────────────────────────────────────┤
│ 💡 Ideas (3)                    ▲   │
│  ⋮⋮  Fix auth timeout       ✏️  ✕   │
│  ⋮⋮  Add retry logic        ✏️  ✕   │
│  ⋮⋮  Update error messages  ✏️  ✕   │
│  ─────────────────────────────────  │
│            [+ Add Idea]             │
└─────────────────────────────────────┘
```

**Pros:**
- Simplest to implement
- Familiar accordion pattern
- Fits naturally in the vertical HUD layout

**Cons:**
- Least distinctive
- Still pushes content down when expanded
- Might reintroduce the "takes too much space" problem for projects with many ideas

---

## Recommendation

**Start with Candidate A (Morphing Pill)** for these reasons:

1. **Distinctive:** No other app does exactly this—it becomes a Claude HUD signature
2. **Aligned with vision:** The HUD vision doc emphasizes "progressive disclosure" and "glanceable"—a pill that morphs on demand is exactly that
3. **Technically feasible:** `matchedGeometryEffect` is designed for this, and you already use spring animations
4. **Solves the space problem:** Pill is tiny when collapsed, overlay floats when expanded

**Fallback:** If morphing feels too complex or doesn't perform well, Candidate B (Anchored Floating Panel) is a solid alternative that's simpler to implement.

**Avoid:** Candidate C (Side Panel) feels too heavy for the HUD's narrow form factor, and Candidate D (Accordion) may reintroduce the space problem you're trying to solve.

---

## Implementation Notes

### For Candidate A (Morphing Pill):

```swift
@Namespace private var ideasNamespace

// Collapsed state
if !isExpanded {
    PillView(idea: nextIdea)
        .matchedGeometryEffect(id: "ideas-container", in: ideasNamespace)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded = true
            }
        }
}

// Expanded state
if isExpanded {
    IdeasOverlayPanel(ideas: allIdeas, onCollapse: {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            isExpanded = false
        }
    })
    .matchedGeometryEffect(id: "ideas-container", in: ideasNamespace)
}
```

### Glassy Background:
```swift
.background(.ultraThinMaterial)
.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
.shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
```

---

## Sources

- [Things 3 Features](https://culturedcode.com/things/features/)
- [Linear UI Redesign](https://linear.app/now/how-we-redesigned-the-linear-ui)
- [Notion Table View](https://www.notion.com/help/tables)
- [Command Palette Interfaces](https://philipcdavis.com/writing/command-palette-interfaces)
- [Raycast for Mac](https://albertosadde.com/blog/raycast)
- [Arc for Designers](https://www.hackdesign.org/toolkit/arc-browser/)
- [App Store Card Animations (Medium)](https://medium.com/@charithgunasekera/crafting-app-store-style-card-animations-with-swiftui-12cc3257928e)
- [WWDC 2024: Enhance UI Animations](https://developer.apple.com/videos/play/wwdc2024/10145/)
- [Apple HIG Disclosure Controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [ListInlay Pattern](https://miksovsky.blogs.com/flowstate/2012/01/listinlay.html)
- [aheze/Popovers Library](https://github.com/aheze/Popovers)
- [SwiftUI Popovers Guide](https://medium.com/@khmannaict13/mastering-swiftui-popovers-a-complete-guide-96c93c548ce5)

---

*Research completed: January 16, 2026*
