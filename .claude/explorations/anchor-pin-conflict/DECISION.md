# Decision: Anchor-Pin Conflict

## Selected approach

**Hybrid: Level Toggle + Anchor Suspension** — When anchored, Capacitor's z-order
tracks the target app's activation state. Glow and position sync pause when the
target is backgrounded. Pin preference is restored on detach.

## Evidence for this choice

- **Product direction:** User confirmed that companion z-order (Capacitor follows
  the terminal in/out of focus) is more intuitive than floating alone with dormant glow.
- **Technical feasibility:** `NSWorkspace.didActivateApplicationNotification` is
  reliable and well-established. Window level toggling is trivial — the same API
  `FloatingWindowConfigurator` already uses.
- **Bonus fix:** Also resolves the un-pinned case where Capacitor gets lost behind
  windows after an app switch. When anchored, Capacitor auto-floats when the terminal
  is active, regardless of pin setting.
- **User preference preserved:** Pin toggle continues to work normally when not
  anchored. The override is transparent and reversible.

## Why not the alternatives

- **Suspend + Fade (2a):** Preserves pin's glanceable value, but user confirmed
  that companion z-order is more intuitive. Also doesn't fix the un-pinned case.
- **NSPanel (3a):** Correct long-term architecture but massive scope (SwiftUI
  WindowGroup → custom NSHostingController, rewrite drag/frame/settings). Doesn't
  fully solve the anchor-pin conflict anyway. Orthogonal improvement for a future
  iteration.
- **Mutual Exclusivity (4a/4b):** Feels restrictive. Blocks the legitimate combined
  use case. Doesn't fix the un-pinned case.
- **Minimal glow fix:** Only treats the symptom. Position sync continues against an
  invisible window, un-pinned case still broken.

## Implementation plan

### 1. Add `.dormant` state to `AnchoringState`

**File:** `AnchorTypes.swift`

Add `case dormant(AnchorDescriptor)` to the enum. Update computed properties:
- `descriptor` → returns descriptor for dormant
- `isAnchored` → returns true for dormant (relationship exists)
- Add `isDormant: Bool` computed property
- Add `isActivelyAnchored: Bool` (true for anchored/trackingDrag/trackingMotion, false for idle/dormant)

### 2. Add workspace observer to `WindowAnchoringController`

**File:** `WindowAnchoringController.swift`

- Add `NSWorkspace.didActivateApplicationNotification` observer (installed in `init`,
  removed in `deinit`)
- Handler compares activated app's PID against `state.descriptor?.target.ownerPID`
- 100ms debounce to handle rapid Cmd-Tab cycling
- Transitions:
  - Target app activates + state is `.dormant` → wake (→ `.anchored`)
  - Non-target app activates + state is `.anchored`/tracking → sleep (→ `.dormant`)

### 3. Implement sleep/wake lifecycle

**File:** `WindowAnchoringController.swift`

**Sleep (→ `.dormant`):**
1. Save descriptor from current state
2. Stop timer
3. Remove event monitors
4. Set `hudWindow?.level = .normal`
5. Set state to `.dormant(descriptor)`

**Wake (→ `.anchored`):**
1. Set `hudWindow?.level = .floating`
2. Sync position (target may have moved)
3. Install event monitors
4. Start 2Hz heartbeat timer
5. Set state to `.anchored(descriptor)`

### 4. Coordinate with `FloatingWindowConfigurator`

**File:** `App.swift`

Pass anchoring-active flag to the configurator. When the anchoring controller is
managing the window level (state is anchored/tracking/dormant), the configurator
must NOT overwrite the level:

```swift
FloatingWindowConfigurator(
    enabled: floatingMode,
    alwaysOnTop: alwaysOnTop,
    anchoringOverridesLevel: appState.anchoringController.state.isAnchored
)
```

In the configurator: skip the level-setting block when `anchoringOverridesLevel`.

### 5. Restore pin preference on detach

**File:** `WindowAnchoringController.swift`

In `detach()`, after clearing state, restore the window level based on the user's
pin preference:

```swift
let pinned = UserDefaults.standard.bool(forKey: "alwaysOnTop")
hudWindow?.level = pinned ? .floating : .normal
```

### 6. Update `AnchorEdgeGlow` for dormant state

**File:** `AnchorEdgeGlow.swift`

- Read `controller.state.isActivelyAnchored` instead of `controller.state.isAnchored`
  for the anchored glow layer
- Add `isDormant` transition: fade glow out (same as detach animation)
- Add wake transition: animate glow back in (same as attach, with pulse)

### 7. Handle edge cases

- **HUD drag while dormant:** `hudDragBegan()` should detach (same as dragging while
  anchored). User is actively moving the HUD, so break the relationship.
- **Target lost while dormant:** The 2Hz heartbeat is stopped, so we won't detect
  target disappearance until wake. On wake, if bounds lookup fails, detach.
- **Detach cooldown:** `lastDetachTime` is set in `detach()` already. No change needed.

## Known risks and mitigations

- **Risk:** Rapid Cmd-Tab causes flicker as window level toggles.
  **Mitigation:** 100ms debounce on the workspace notification handler.

- **Risk:** `FloatingWindowConfigurator.updateNSView` runs on SwiftUI state changes
  and could overwrite the level.
  **Mitigation:** `anchoringOverridesLevel` flag prevents the configurator from
  touching the level while anchored.

- **Risk:** Target window moves while dormant (e.g., user repositions via keyboard
  shortcut or another app).
  **Mitigation:** Wake-up re-syncs position. The existing position sync handles this
  smoothly.

- **Risk:** Multiple workspace notifications pile up during sleep/wake with expensive
  CG API calls.
  **Mitigation:** Debounce + early return if already in the correct state.
