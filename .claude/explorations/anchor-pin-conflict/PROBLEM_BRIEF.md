# Problem Brief: Anchor-Pin Conflict

## Problem statement

Capacitor has two independent features that express contradictory intent when both are active:

- **Pinning** (`alwaysOnTop`): "I always want to see Capacitor, regardless of which app is active." Sets `window.level = .floating`.
- **Anchoring**: "Capacitor is a companion to this specific terminal window." Syncs HUD position to the target, glows on the connected edge.

When both are enabled and the target app (e.g., Ghostty) loses focus:
1. Ghostty recedes behind the active app (macOS default z-ordering)
2. Capacitor stays on top (because `.floating`)
3. The anchor glow points at empty space — the target is invisible
4. The 2Hz heartbeat continues syncing position with the invisible window
5. User can drag and re-snap to the invisible window
6. The HUD feels disconnected and the spatial relationship is meaningless

The underlying need: define a coherent mental model for what "anchored + pinned" means when the target app isn't visible.

## Dimensions

| Dimension | Notes |
|-----------|-------|
| **Coherence** | Does the combined behavior make intuitive sense? Can the user predict what happens? |
| **Visibility** | Can the user still glance at Capacitor when working in other apps? (Pin's purpose) |
| **Relationship durability** | Does the anchor survive app switches, or must the user re-snap? |
| **Implementation complexity** | How much state management, how many edge cases? |
| **Interaction cost** | How many clicks/drags to recover from an app switch? |
| **Discoverability** | Can the user understand what happened without reading docs? |

## Success criteria

### Must
- No phantom state: the HUD must never glow toward empty space or follow an invisible window with no visual indication that something is off
- The user's pin preference must not be permanently altered by anchoring
- App switching must not require re-snapping every time (the anchor relationship should survive a cmd-tab round trip)

### Should
- Capacitor should remain visible when the user wants to glance at it from another app (preserving pin's core value)
- The behavior should be self-explanatory — no docs needed
- The transition between "target visible" and "target hidden" should be smooth, not jarring

### Nice
- Clicking on Capacitor while both are backgrounded could bring the target app forward too (companion feel)
- Reduced motion users get equivalent clarity via opacity/state changes
- The solution works for any anchor target, not just Ghostty

## Assumptions

1. **Users who pin want persistent visibility** — pinning is a deliberate choice for always-on monitoring. Status: confirmed (this is the feature's purpose).
2. **Users who anchor want spatial coupling** — anchoring is about "this HUD belongs next to this terminal." Status: confirmed (the whole point of edge glow + position sync).
3. **App switching is frequent** — typical workflow: terminal → browser → terminal → editor → terminal. Status: unconfirmed — need to ask user, but likely true given multi-agent workflow.
4. **The anchor relationship is valuable to preserve** — re-snapping is expensive in attention cost. Status: likely true given the 3-second cooldown already exists to prevent accidental detach.
5. **macOS NSWorkspace notifications are reliable for app activation tracking** — `didActivateApplicationNotification` fires consistently. Status: confirmed (well-established API).

## Constraints

- macOS doesn't support cross-process child windows (`addChildWindow` is same-process only)
- `window.level = .floating` is a binary toggle — there's no "float above this specific app" API
- The anchoring controller is `@Observable` and drives SwiftUI — solutions must integrate reactively
- `FloatingWindowConfigurator` is an NSViewRepresentable that re-applies window config on SwiftUI updates — z-order changes must coordinate with it
- The 2Hz heartbeat uses CGWindowListCopyWindowInfo which sees all on-screen windows regardless of z-order
