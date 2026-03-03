# Solution Map: Anchor-Pin Conflict

## Paradigm 1: Level Toggling ("Companion Z-Order")

**Core bet:** Anchoring implies a z-order relationship. When anchored, Capacitor's
window level should track the target app's activation state — not the user's pin
toggle. The pin toggle's behavior is *subsumed* while anchored.

The insight: `.floating` means "above ALL normal windows from ALL apps." That's too
broad when Capacitor has a specific companion relationship. What we want is "above
the terminal, but not above unrelated apps."

### Approach 1a: Simple Level Toggle

Observe `NSWorkspace.didActivateApplicationNotification`. When anchored:

- Target app activates → `window.level = .floating` (visible above terminal)
- Any other app activates → `window.level = .normal` (recedes with terminal)
- On detach → restore user's pin preference

Behavior matrix:

| State | Terminal Active | Other App Active |
|-------|----------------|-----------------|
| Anchored + pinned | `.floating` ✅ | `.normal` (recedes) |
| Anchored + unpinned | `.floating` ✅ | `.normal` (recedes) |
| Detached + pinned | `.floating` ✅ | `.floating` (stays) |
| Detached + unpinned | `.normal` | `.normal` |

- **How it works:** Subscribe to workspace notification in the anchoring controller.
  Compare activated PID against `descriptor.target.ownerPID`. Toggle level.
- **Gains:** Most "natural" companion feel. Capacitor automatically appears alongside
  the terminal and disappears when irrelevant. Works even WITHOUT pin enabled — fixes
  the un-pinned case where Capacitor currently gets lost behind the terminal after
  app switch.
- **Gives up:** User can't glance at Capacitor while working in Safari — the whole
  point of pinning. Pin's core value is suspended while anchored.
- **Shines when:** User mostly works in the terminal and only briefly switches away.
- **Risks:** Jarring if the user forgets Capacitor is anchored and it suddenly appears/
  disappears on app switch. Race conditions with rapid Cmd-Tab cycling (need debounce).
  `FloatingWindowConfigurator` may fight the level changes on SwiftUI updates.
- **Complexity:** moderate — workspace observer + level management + coordinator with
  FloatingWindowConfigurator to avoid conflicts.

### Approach 1b: Level Toggle + Click-to-Raise-Both

Same as 1a, plus: when Capacitor is at `.normal` (both backgrounded) and the user
clicks on Capacitor, also activate the target app.

- **How it works:** In `applicationDidBecomeActive`, if anchored and was at `.normal`,
  call `NSRunningApplication(processIdentifier: ownerPID)?.activate(options: [])`.
- **Gains:** The companion pair feels like a single unit. Clicking either one brings
  both forward.
- **Gives up:** Same as 1a. Additionally, `activate()` is deprecated in macOS 14+.
  The cooperative activation model (`yieldActivation`) requires Capacitor to yield
  to the terminal, then the terminal would need to call `NSApp.activate()` — which
  requires terminal cooperation we don't have.
- **Shines when:** Deep companion integration is desired.
- **Risks:** `activate(options:)` deprecation means this may break on future macOS.
  Focus stealing can feel aggressive. Cross-app activation is inherently fragile.
- **Complexity:** complex — all of 1a plus deprecated API usage, focus management
  edge cases, and macOS version compatibility concerns.


## Paradigm 2: Anchor Suspension ("Sleep/Wake")

**Core bet:** Pinning and anchoring are independent features with independent value.
When they conflict, pause the anchor behavior and let pinning work normally. The
anchor relationship survives in a "dormant" state.

The insight: the problem isn't that Capacitor is floating while Ghostty is backgrounded.
The problem is that the GLOW and POSITION SYNC are active when the target is invisible.
If we pause anchor behavior, the HUD naturally falls back to "pinned standalone mode."

### Approach 2a: Pause + Fade

When the target app deactivates:

1. Pause position sync (stop heartbeat timer, keep descriptor)
2. Fade edge glow to zero (dormant state)
3. Keep HUD where it is — respecting pin preference

When the target app re-activates:

1. Resume position sync
2. Re-sync position (target may have moved)
3. Animate glow back in (same as attach, with pulse)

No re-snapping needed. The anchor descriptor is preserved across the sleep/wake cycle.

- **How it works:** Add a new state to the anchoring lifecycle: `.dormant(AnchorDescriptor)`.
  Observe workspace notifications. Transition `.anchored` ↔ `.dormant` on app activation
  changes. The glow view already reads controller state reactively.
- **Gains:** Pin value is FULLY preserved — user can still glance at Capacitor from
  any app. Anchor relationship survives. No phantom glow. No position sync to invisible
  window. Simple mental model: "the anchor sleeps when the terminal is away."
- **Gives up:** The spatial relationship is temporarily meaningless — Capacitor is
  floating at its last anchored position, which may not make sense without the terminal
  next to it. But it's no worse than a standalone pinned HUD.
- **Shines when:** User frequently switches between terminal and other apps and wants
  Capacitor always visible.
- **Risks:** If the target window moved while dormant (user moved it from another app,
  or Spaces transition), the wake-up re-sync might be visually jarring. Mitigated by
  the existing spring animation on position sync.
- **Complexity:** simple — add one state, one workspace observer, pause/resume logic.
  Glow view and position sync already handle state transitions cleanly.

### Approach 2b: Pause + "Paired" Indicator

Same as 2a, but instead of just fading the glow, show a small "paired" indicator
(e.g., a subtle icon or text showing which terminal Capacitor is paired with).

- **How it works:** When dormant, replace the edge glow with a small status indicator
  (e.g., "⟵ Ghostty" or a minimal Ghostty icon) at reduced opacity.
- **Gains:** User knows the anchor is still active even without the glow. Reduces
  confusion about why the glow disappeared.
- **Gives up:** More visual design work. Another UI element to maintain.
- **Shines when:** Discoverability is a priority.
- **Risks:** The indicator might feel cluttered for a "glanceable" HUD. May be
  over-designing for a niche state.
- **Complexity:** moderate — 2a plus a new view component and Ghostty icon/text.


## Paradigm 3: Non-Activating Panel ("Architecture Shift")

**Core bet:** Capacitor's window type is fundamentally wrong for a companion role.
NSWindow is designed for primary application windows. NSPanel with `.nonactivatingPanel`
is designed exactly for auxiliary HUDs that shouldn't steal focus. Changing the window
architecture would make many UX issues disappear — including the anchor-pin conflict.

### Approach 3a: Convert to NSPanel

Replace the main NSWindow with an NSPanel:

```swift
let panel = NSPanel(
    contentRect: .zero,
    styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
panel.level = .floating
panel.hidesOnDeactivate = false
panel.collectionBehavior = [
    .canJoinAllSpaces,
    .transient,
    .auxiliary,
    .fullScreenAuxiliary,
]
```

Key behavioral changes:
- Clicking on Capacitor does NOT make it the active app → terminal stays frontmost
- Capacitor stays at `.floating` level always → always visible above normal windows
- `.transient` hides it in Mission Control → less visual clutter
- `.fullScreenAuxiliary` lets it appear alongside full-screen terminals

The anchor-pin conflict partially dissolves: since Capacitor never steals focus,
clicking on it doesn't cause the terminal to deactivate. The user stays "in" the
terminal while interacting with Capacitor.

However, the core conflict remains: when the user actively switches to Safari,
Ghostty still goes behind, and Capacitor still floats above. The panel approach
doesn't solve that — it just eliminates one trigger (clicking on Capacitor itself).

- **How it works:** Replace NSWindow with NSPanel in the SwiftUI WindowGroup or use
  a custom NSHostingController-based approach. Major architectural change.
- **Gains:** Fixes a broader class of UX issues: Capacitor never disrupts the user's
  terminal focus. Works alongside full-screen terminals. Better Mission Control
  behavior. Makes Capacitor feel like a system-level HUD rather than a separate app.
- **Gives up:** The BIGGEST change on this list. SwiftUI's WindowGroup creates
  NSWindow — getting NSPanel requires workarounds (NSHostingController, custom app
  architecture). May break window dragging, frame persistence, settings sheets.
  Still doesn't fully solve the anchor-pin conflict for active app switches.
- **Shines when:** Capacitor is ready for a window architecture overhaul and wants
  to feel like a system HUD rather than an app window.
- **Risks:** Massive scope. May require rewriting FloatingWindowConfigurator,
  WindowFrameStore, settings sheets, and the drag-to-move system. SwiftUI's
  integration with NSPanel is underdocumented and fragile.
- **Complexity:** very complex — architectural overhaul with many downstream effects.


## Paradigm 4: Mutual Exclusivity ("Pick One")

**Core bet:** Anchoring and pinning serve different workflows. Trying to combine
them creates an inherently confusing state. Just don't allow it.

### Approach 4a: Anchoring Disables Pin

When the HUD snaps to a target:
- Auto-disable `alwaysOnTop` (set to false)
- Gray out the pin toggle while anchored
- On detach → restore previous pin preference

- **How it works:** In `anchorTo()`, save pin state, set `alwaysOnTop = false`.
  In `detach()`, restore saved pin state. Gray out pin button when anchored.
- **Gains:** Zero conflict — the problem literally cannot occur. Clear mental model:
  "anchored = companion, pinned = standalone."
- **Gives up:** Users who want both features simultaneously. The "glance at Capacitor
  while in Safari" use case is blocked while anchored.
- **Shines when:** Simplicity is paramount and the combined use case is rare.
- **Risks:** Feels restrictive. Users might not understand why pin is grayed out.
  Doesn't solve the un-pinned case where Capacitor gets lost behind windows.
- **Complexity:** simple — save/restore boolean, gray out UI toggle.

### Approach 4b: Pin Detaches Anchor

When the user enables pin while anchored:
- Detach the anchor
- HUD stays where it is, now floating independently

When the user anchors while pinned:
- Disable pin
- HUD snaps to terminal

- **How it works:** The two features toggle each other off. Like radio buttons.
- **Gains:** Even simpler mental model. User actively chooses which mode.
- **Gives up:** Same as 4a. Additionally, the user has to re-establish whichever
  mode they want after switching.
- **Shines when:** Both features are rarely used together.
- **Risks:** Users might find it annoying that enabling one disables the other
  without warning.
- **Complexity:** simple.


## Non-obvious options

### Hybrid: Level Toggle + Suspension (1a + 2a combined)

When anchored and target app deactivates:
1. Set `window.level = .normal` (follow terminal behind active app)
2. Pause position sync and fade glow

When anchored and target app re-activates:
1. Set `window.level = .floating` (pop back above terminal)
2. Resume position sync and animate glow back

This combines the companion z-order behavior with the visual feedback of suspension.
The user gets: "Capacitor appears alongside my terminal and disappears when I'm
doing something else. When I come back, it's right there."

This is arguably the most "companion-like" behavior. The pin toggle's meaning while
anchored becomes: (no effect — z-order is companion-driven). On detach, pin
preference is restored.

**The strongest candidate.** It handles both the visual (glow) and spatial (z-order)
dimensions of the conflict.

### "Lazy Visibility Check"

Don't observe workspace notifications at all. Instead, in the 2Hz heartbeat, check
whether the target window is in front of the HUD using CGWindowListCopyWindowInfo
z-ordering data. If the target is behind other windows, suppress the glow.

- Simpler than workspace observation (no new notifications)
- Leverages existing polling infrastructure
- But 2Hz is slow for visual feedback (up to 500ms lag on app switch)

### "Anchor Implies Float"

Redefine: when anchored, Capacitor is ALWAYS at `.floating` level regardless of pin
setting. The pin toggle only affects the un-anchored state.

This means anchored Capacitor is always visible — but combined with level toggling
(approach 1a), it could mean: "always float when terminal is active, always hide when
it's not." This is effectively the hybrid approach above.

### "Do Nothing But Fix the Glow"

The minimal intervention: just suppress the edge glow when the target app is not
frontmost. Don't change z-order or position sync. The anchor still works, it's just
not visually highlighted.

This is cheap and fixes the most jarring symptom (glow pointing at nothing) without
touching the deeper z-order issue.


## Eliminated early

- **Cross-process child windows** (`NSWindow.addChildWindow`): only works within the
  same process. Not applicable.
- **Cross-process z-ordering** (`orderWindow(_:relativeTo:)`): confirmed non-functional
  across processes. The otherWin parameter is looked up in the calling app's window list.
- **NSRunningApplication.activate() for click-to-raise**: deprecated in macOS 14+.
  The cooperative activation model requires the target app to participate, which we
  can't guarantee. Too fragile for production use.
- **Timeout-based auto-detach**: "If target backgrounded for >N seconds, detach."
  Arbitrary threshold, doesn't handle quick app switches, and re-snapping is expensive.
