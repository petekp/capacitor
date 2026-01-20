# Plan: UI Tuning Panel Rework

Consolidate `GlassTuningPanel.swift` (1355 lines) and `ProjectCardTuningPanel.swift` (290 lines) into a single, well-organized **UI Tuning** panel with sidebar navigation.

## Problem

- **Friction**: Related parameters are scattered across sections and two separate panels
- **Discoverability**: Hard to find what you're looking for in a 1300+ line file with 17+ sections
- **Workflow**: Switching between panels when tuning a single component's look+feel
- **Maintainability**: Massive file that's grown organically, hard to work in

## Design Decisions

| Decision | Choice |
|----------|--------|
| Mental model | Component-focused ("everything about this thing in one place") |
| Navigation | Sidebar with 2-3 level hierarchy |
| Sidebar depth | Stops at group level (e.g., "Interactions", not individual states) |
| Detail area | Shows all items in selected group, fully expanded |
| Section headers | Sticky — pin to top as you scroll |
| Panel sizing | Resizable, larger default (~520×700) |
| Reset scope | Per-group buttons in sticky headers |
| Export scope | Global (all changed values across everything) |
| Name | "UI Tuning" |
| Access | Menu item + keyboard shortcut |
| **Visual style** | **Match main app aesthetic** — frosted glass backgrounds, same button styles, `VibrancyView` materials, consistent with app's design language (not plain debug styling) |

## Proposed Hierarchy

```
▼ Logo
    Letterpress           → shadow, highlight, blur, blend modes

▼ Project Card
    Appearance            → background, borders, material
    Interactions          → idle, hover, pressed (scale, springs, shadows)
    State Effects         → ready (ripple), working (stripes/glow/vignette),
                            waiting (pulse), compacting

▼ Panel
    Background            → tint, corners, borders, highlights
    Material              → type, emphasis

▼ Status Colors
    All States            → hue/saturation/brightness for ready, working,
                            waiting, compacting, idle
```

## Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  UI Tuning                                           [–] [□] [×] │
├──────────────┬──────────────────────────────────────────────────┤
│              │                                                   │
│  ▼ Logo      │  ┌─────────────────────────────────────────────┐ │
│    Letterpr… │  │ Idle State                         [Reset]  │ │ ← sticky header
│              │  ├─────────────────────────────────────────────┤ │
│  ▼ Project   │  │ Scale           ●────────────────○  1.00    │ │
│    Appearanc │  │ Shadow Opacity  ●──────○─────────  0.17    │ │
│    Interacti │  │ Shadow Radius   ●────○───────────  8.07    │ │
│    State Eff │  │ Shadow Y        ●───○────────────  3.89    │ │
│              │  │                                              │ │
│  ▼ Panel     │  ├─────────────────────────────────────────────┤ │
│    Backgroun │  │ Hover State                        [Reset]  │ │ ← sticky header
│    Material  │  ├─────────────────────────────────────────────┤ │
│              │  │ Scale           ●────────────────○  1.01    │ │
│  ▼ Status    │  │ Spring Response ●──────○─────────  0.26    │ │
│    All State │  │ Spring Damping  ●────────────○───  0.90    │ │
│              │  │ ...                                          │ │
│              │  │                                              │ │
├──────────────┴──────────────────────────────────────────────────┤
│                                            [Copy for LLM]       │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| Action | File |
|--------|------|
| Create | `Views/Debug/UITuningPanel.swift` — New unified panel |
| Create | `Views/Debug/UITuningPanel/Sidebar.swift` — Sidebar navigation |
| Create | `Views/Debug/UITuningPanel/DetailView.swift` — Content area |
| Create | `Views/Debug/UITuningPanel/StickySection.swift` — Sticky header component |
| Modify | `GlassConfig.swift` — Extract from GlassTuningPanel, keep as shared state |
| Delete | `GlassTuningPanel.swift` — After migration complete |
| Delete | `ProjectCardTuningPanel.swift` — After migration complete |
| Modify | Menu/shortcut wiring — Point to new UITuningPanel |

## Implementation Phases

### Phase 1: Foundation
- Create `UITuningPanel.swift` with sidebar + detail layout
- Implement resizable window with size persistence
- Build `StickySection` component with sticky headers
- Wire up menu item and keyboard shortcut

### Phase 2: Migrate Content
- Move Logo parameters to `Logo > Letterpress`
- Move card background/border params to `Project Card > Appearance`
- Move interaction params (from ProjectCardTuningPanel) to `Project Card > Interactions`
- Move state effect params to `Project Card > State Effects`
- Move panel params to `Panel > Background` and `Panel > Material`
- Move status colors to `Status Colors > All States`

### Phase 3: Reset & Export
- Add per-group Reset buttons in sticky headers
- Consolidate Export logic to single global "Copy for LLM" button
- Ensure export only includes changed values (existing behavior)

### Phase 4: Cleanup
- Delete old `GlassTuningPanel.swift`
- Delete old `ProjectCardTuningPanel.swift`
- Remove any dead code paths or duplicate state

## Open Questions

1. **Sidebar width** — Fixed or resizable independently?
2. **Keyboard navigation** — Arrow keys to move between sidebar items?
3. **Search** — Add a filter/search box later? (Not MVP, but worth considering)

## Verification

1. All existing parameters accessible in new panel
2. Reset works per-group without affecting other groups
3. Export produces identical output format for changed values
4. Panel remembers size/position across sessions
5. Sticky headers work correctly during scroll
6. Shortcut opens new panel, old panels removed
