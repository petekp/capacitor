# Analysis: Anchor-Pin Conflict

## Tradeoff Matrix

| Criterion | 1a: Level Toggle | 2a: Suspend+Fade | 3a: NSPanel | 4a: Disable Pin | Hybrid (1a+2a) | Min: Fix Glow |
|-----------|-----------------|-------------------|-------------|-----------------|----------------|---------------|
| **MUST: No phantom glow** | ✅ recedes entirely | ✅ glow fades | ✅ (still floats w/ glow issue) | ✅ no conflict | ✅ recedes + fades | ✅ glow fades |
| **MUST: Pin pref preserved** | ✅ restored on detach | ✅ never changed | ✅ never changed | ✅ restored on detach | ✅ restored on detach | ✅ never changed |
| **MUST: No re-snap on round trip** | ✅ descriptor survives | ✅ descriptor survives | ✅ descriptor survives | ✅ descriptor survives | ✅ descriptor survives | ✅ descriptor survives |
| **SHOULD: Glanceable from other app** | ❌ recedes with terminal | ✅ stays floating | ✅ stays floating | ❌ no pin while anchored | ❌ recedes with terminal | ✅ stays floating |
| **SHOULD: Self-explanatory** | ✅ companion feel is natural | ⚠️ "where'd the glow go?" | ⚠️ big behavior change | ⚠️ "why is pin grayed out?" | ✅ companion feel | ✅ simple |
| **SHOULD: Smooth transition** | ⚠️ pop on app switch | ✅ fade in/out | N/A | ✅ instant | ✅ fade + level | ✅ fade |
| **NICE: Click raises both** | possible but fragile | N/A (already visible) | N/A | N/A | possible but fragile | N/A |
| **Complexity** | moderate | simple | very complex | simple | moderate | trivial |
| **Fixes un-pinned case too** | ✅ auto-floats with terminal | ❌ still lost behind | ✅ always floating | ❌ | ✅ auto-floats | ❌ |

## Eliminated

- **3a (NSPanel):** Eliminated on complexity and incomplete solution. Converting to
  NSPanel is a major architectural change (SwiftUI WindowGroup creates NSWindow;
  NSPanel requires custom hosting) that would touch window management, frame
  persistence, drag-to-move, settings sheets, and the floating window configurator.
  AND it still doesn't solve the core conflict — when the user actively switches to
  Safari, the terminal goes behind but the panel stays floating. The anchor-pin
  conflict persists. NSPanel is worth considering independently as a future
  architecture improvement, but it's orthogonal to this problem.

- **4a/4b (Mutual Exclusivity):** Eliminated on the "glanceable from other app"
  criterion. Users who pin AND anchor are expressing a legitimate combined intent:
  "I want this docked to my terminal AND visible from other apps." Blocking that
  feels like a product regression. Also doesn't fix the un-pinned case.

- **Minimal "Fix Glow Only":** Passes all MUSTs but doesn't fix the un-pinned case
  and leaves position sync running against an invisible window (wasteful). It's the
  right "emergency" fix but not the right solution.

## Finalists

### 1. Approach 2a: Suspend + Fade

From Paradigm 2 (Anchor Suspension). Selected because:
- Preserves pin's core value (glanceable from other apps)
- Simplest implementation (one new state, workspace observer, pause/resume)
- Smooth visual transition (glow fades, re-animates on wake)
- Anchor relationship survives app switches

**Weakness:** Doesn't fix the un-pinned case. Capacitor still gets lost behind
windows when not pinned and the user switches apps.

### 2. Hybrid: Level Toggle + Suspend (1a + 2a)

From Non-obvious section. Selected because:
- Fixes BOTH pinned and un-pinned cases
- Most "companion-like" feel — Capacitor appears with the terminal, disappears with it
- Clean glow transitions (fade on sleep, animate on wake)
- Pin preference is overridden while anchored but restored on detach

**Weakness:** Sacrifices pin's "always visible" value while anchored. Users who want
to glance at Capacitor from Safari can't, because it receded with the terminal.

## Key differentiator

**Is "glanceable from another app" important when anchored?**

If yes → Finalist 1 (Suspend + Fade): Capacitor stays visible, glow sleeps.
If no  → Finalist 2 (Hybrid): Capacitor follows the terminal completely.

This is a product question, not a technical one. The user should decide.

## Open risks

1. **Rapid app switching (Cmd-Tab):** Both finalists react to workspace notifications.
   Rapid cycling could cause flicker. Mitigation: 100ms debounce on the notification
   handler.

2. **Target window moves while dormant:** If the terminal window is repositioned
   (e.g., via another app's "arrange windows" feature, or moving between Spaces),
   the wake-up re-sync might teleport the HUD. Mitigation: the existing spring
   animation in syncPosition smooths this.

3. **Multiple anchored targets:** Currently only one anchor at a time, so not an
   issue. But if multi-anchor is ever added, the workspace observer needs to track
   multiple PIDs.

4. **FloatingWindowConfigurator coordination:** Both finalists toggle window level
   outside of the configurator. Need to ensure SwiftUI updates don't overwrite the
   level back. Mitigation: add an "anchoring override" flag that the configurator
   respects.
