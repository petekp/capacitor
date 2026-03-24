# Resume: UI Refinement — Autonomous Overnight Run

## Mission
Exhaustive visual QA and refinement of every production UI surface in Capacitor (SwiftUI macOS app). Migrate raw font sizes to semantic `AppTypography` tokens, normalize opacity values, harmonize spacing, and ensure all surfaces share a consistent visual style. The full runbook is written and ready to execute.

## How to Work
- **You are running autonomously.** The user is away and will review your commits when they return.
- **Use the task list extensively.** Create discrete tasks for each sub-step (each file audit, each file edit, each build verification). Mark tasks `in_progress` when starting, `completed` when done. This is how the user will track your progress.
- **Commit per phase.** Each phase in the runbook should produce exactly one commit. Do not batch multiple phases into a single commit.
- **Build after each phase.** Run `./scripts/dev/restart-alpha-stable.sh` after each editing phase to confirm compilation. If the build fails, fix the issue before moving on.
- **Debug views are out of scope.** Skip everything under `Views/Debug/`.

## Resume Point
- Last meaningful action: Wrote `UI-REFINEMENT-RUNBOOK.md` with 7-phase plan covering all 35 production view files
- Next action: Read the runbook, then begin Phase 0 (read the 4 theme files)
- Success criterion: All 7 phases completed, each with its own commit, final build passing

## Runbook Location
`/Users/petepetrash/Code/capacitor/.claude/worktrees/ui-refinement/UI-REFINEMENT-RUNBOOK.md`

**Read this file first.** It contains the complete phased plan, file checklists, token mapping tables, and opacity tier reference.

## Current State
- Runbook written and ready — no edits have been made to any source files yet
- Exploration complete — all 35 production view files inventoried, all inconsistencies pre-identified
- Design system is mature — 4 theme files (`Typography.swift`, `Colors.swift`, `GlassConfig.swift`, `Motion.swift`) define the canonical tokens

### Pre-identified hotspots (from initial exploration)
- ~100 instances of raw `.font(.system(size:))` across production views (most in: `IdeaCapturePopover`, `IdeaDetailModal`, `FooterView`, `SetupStatusCard`, `SetupStepRow`, `HeaderView`, `SharedStyles`, `QuickFeedbackSheet`, `ToastView`, `TipTooltipView`, `ProjectCardComponents`, `ProjectsView`, `SettingsView`, `IdeaQueueView`, `VibrancyActionButton`, `BrandLogomark`, `ShellInstructionsSheet`)
- Scattered `.white.opacity()` values that don't match established tiers (0.45, 0.6, 0.8, 0.85, 0.95 should snap to 0.4/0.5/0.7/0.9)
- Minor padding variance between peer cards (12pt vs 16pt in some cases)

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor/.claude/worktrees/ui-refinement`
- This is a **git worktree** — run all commands from this directory, never cd to the main repo
- Branch: `worktree-ui-refinement`
- Working tree: clean except for the new `UI-REFINEMENT-RUNBOOK.md` (untracked)
- Base commit: `4fad668 Update AGENT_CHANGELOG with capture wiring and recovery deltas`

## Key Artifacts
- `/Users/petepetrash/Code/capacitor/.claude/worktrees/ui-refinement/UI-REFINEMENT-RUNBOOK.md` — the complete phased plan, READ THIS FIRST
- `apps/swift/Sources/Capacitor/Theme/Typography.swift` — `AppTypography` enum, the token source of truth
- `apps/swift/Sources/Capacitor/Theme/Colors.swift` — semantic color tokens
- `apps/swift/Sources/Capacitor/Theme/GlassConfig.swift` — spacing, corner radius, effect parameters
- `apps/swift/Sources/Capacitor/Theme/Motion.swift` — animation preferences
- `apps/swift/Sources/Capacitor/Views/` — all 48 view files (35 production, 9 debug/out-of-scope, plus subdirs)

## Project Rules
- **Rebuild after Swift changes**: `./scripts/dev/restart-alpha-stable.sh` (default for agents)
- **Always run `cargo fmt`** before commits — CI enforces formatting
- **This is a worktree** — do not cd to the main repo root
- **No behavior changes** — visual-only refinements, no logic changes
- **No new comments/docstrings** on code you didn't meaningfully change
- **Skip hooks for non-Swift changes** — but these are all Swift changes, so hooks should run normally
- **UniFFI note**: Swift app links release Rust core at `../../target/release`; if you only change Swift view files you won't need a Rust rebuild, but the restart script handles this automatically

## Established Decisions
- Debug views (`Views/Debug/**`) are excluded — they're dev tooling with intentionally different styling
- Typography migration uses the mapping table in the runbook; if a raw size has no good match, add a new `AppTypography` token only if the pattern appears 2+ times
- SF Symbol icon font sizes (used in `.font(.system(size: X))` purely for icon scaling) should be left raw — they're not text typography
- Opacity snapping: 0.45→0.4, 0.6→0.55, 0.8→0.7 or 0.9 (use judgment), 0.85→0.9, 0.95→0.9
- One commit per phase for easy review/revert

## Phase Summary (from runbook)
1. **Phase 0**: Read theme files (no edits)
2. **Phase 1**: Exhaustive read-only audit of all 35 production files — document every inconsistency
3. **Phase 2**: Typography migration (raw fonts → AppTypography tokens) — commit
4. **Phase 3**: Opacity & color normalization — commit
5. **Phase 4**: Spacing & layout harmonization — commit
6. **Phase 5**: Animation spring standardization — commit
7. **Phase 6**: Cross-surface holistic QA (read-only, fix if needed) — commit if changes
8. **Phase 7**: Final build + verification (`cargo fmt`, `cargo clippy`, restart, `cargo test`)

## Verification State
- Passed: nothing yet (no edits made)
- Not run: all builds, all phases
- The app is currently in a known-good state on `main`

## Notes for the Next Agent
- The runbook has detailed file checklists with checkbox markers — work through them in order
- Phase 1 is the longest phase (35 files to read) but produces no edits — it builds the mental model for all subsequent phases
- `VibrancyActionButton.swift` uses `.font(.system(size: iconSize))` where `iconSize` is a computed property — this is SF Symbol sizing, not text typography; leave it raw
- `BrandLogomark.swift` uses `.font(.system(size: size))` for the logomark glyph — also leave raw
- `SetupStepRow.swift` uses `.font(.system(size: 18-20))` for SF Symbol icons in the setup checklist — leave raw
- `ShellInstructionsSheet.swift` has `.font(.system(size: 4))` which looks like a spacer hack — investigate before changing
- The app uses `.preferredColorScheme(.dark)` globally — all views assume dark mode
