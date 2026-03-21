# Mission: Rebuild UX — Diff + Banner for Delegation Review

## Problem
When a delegation worker modifies Swift app code and produces a milestone, the reviewer
sees the brief and artifacts in the review window but the running app is still the old build.
The worker's changes aren't compiled.

## Chosen Approach: Diff + Notification Banner
After exploring three approaches (background build gate, restart-aware review, lighter
alternatives), we chose the lightest structurally sound option:

1. **Manifest signal** — Add `swift_changes: Bool?` to `DelegationReviewManifest`. Worker
   sets it when Swift files are changed. Prompt updated accordingly.
2. **Inline diff** — Review window shows `git diff --stat` summary + expandable full diff
   from the worktree. Reviewer reads code changes like a PR review.
3. **Notification banner** — When `swift_changes == true`, show a dismissible banner:
   "This milestone includes Swift changes. Run restart-alpha-stable.sh to preview live."

## Why This Approach
- Zero build infrastructure, zero process management
- Matches how code review already works (diff is the primary review surface)
- No context-switching for the reviewer (everything in one window)
- Half-day implementation, no Rust changes, no UniFFI surface changes
- Notification banner is the escape hatch for rare live-preview needs

## Non-Goals
- Background build verification (deferred — complexity inversion for most milestones)
- App self-restart with state persistence (deferred — fragile, dev-only)
- Hot-reload or live preview (not feasible for compiled SwiftUI)
- Worktree-aware build scripts (separate workstream if needed later)
