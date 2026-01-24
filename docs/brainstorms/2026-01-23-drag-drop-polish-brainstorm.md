---
date: 2026-01-23
topic: drag-drop-polish
---

# Drag-and-Drop Polish: Mixed Results & Discoverability

## What We're Building

Two refinements to the drag-and-drop project linking feature:

1. **Mixed Results Toast** — When dropping multiple folders produces mixed outcomes (some succeed, some fail), show errors prominently while acknowledging successes briefly.

2. **Discoverability** — Help users learn they can drop folders anywhere through two touchpoints: an empty state call-to-action and a one-time tooltip after their first button-based add.

## Why This Approach

**Mixed Results:** Users need to know when something fails—that's actionable. Success is evident from projects appearing in the list. An error-first message like `"2 failed to add (3 succeeded)"` gives them the critical info upfront.

**Discoverability:** New users see the empty state first, so making drag-drop the primary CTA there catches them early. For users who miss it and use the button, a one-time floating tooltip educates without being intrusive. Storing in `@AppStorage` ensures we never nag.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Toast priority | Errors first, successes as suffix | Errors are actionable; successes are self-evident |
| Toast format | `"2 failed (3 succeeded)"` | Compact, scannable, prioritizes problems |
| Empty state | Drag-drop as primary CTA | First thing new users see |
| Post-button hint | Floating tooltip, one-time | Unobtrusive progressive disclosure |
| Hint persistence | `@AppStorage` (once ever) | Respects user's time; no repeated education |

## Open Questions

- **Tooltip placement:** Near the window edge? Center? Anchored to where they just added?
- **Tooltip dismiss behavior:** Click anywhere, click tooltip, or auto-dismiss after N seconds?
- **Empty state visual:** Just text, or include a drop zone illustration?

## Next Steps

→ `/workflows:plan` for implementation details
