# Mission: Contextual Decision CTAs

## Problem
Review window decision cards have hardcoded generic text ("Ship this milestone and move on"). The worker knows exactly what it did and what the reviewer should pay attention to — that context should surface as the CTA labels and descriptions.

## Goal
Workers generate contextual decision options as part of their milestone manifest. The review window reads these and displays them. Static fallbacks for backward compatibility.

## Constraints
- 3 files touched: DelegationReviewManifest, DelegationReviewWindow, prompt builders
- No new dependencies
- Backward compatible: missing `decisions` field falls back to current static text
- "Write a Response" stays static (user-initiated freeform)
