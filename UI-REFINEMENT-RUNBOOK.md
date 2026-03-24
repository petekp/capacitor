# UI Refinement Runbook

> **Purpose**: Exhaustive QA audit + refinement of every production UI surface in Capacitor.
> **Method**: File-by-file reads, catalog inconsistencies, then fix in batches.
> **Branch**: `worktree-ui-refinement`

## Ground Rules

1. **Read before you edit.** Every file listed below must be fully read and audited before any changes are made to it.
2. **Debug views are out of scope.** Everything under `Views/Debug/` is developer tooling — skip it entirely.
3. **Commit per phase.** Each phase below should produce one clean commit so we can review and revert independently.
4. **Build after each phase.** Run `./scripts/dev/restart-alpha-stable.sh` after each phase to confirm compilation.
5. **Don't change behavior.** These are visual-only refinements. No logic changes, no new features.
6. **Don't add comments/docstrings** to code you didn't meaningfully change.

---

## Reference: Design System Tokens

Before starting, read these four files to internalize the canonical design system:

- `apps/swift/Sources/Capacitor/Theme/Typography.swift` — `AppTypography.*` semantic font tokens
- `apps/swift/Sources/Capacitor/Theme/Colors.swift` — `Color.brand`, `.hudBackground`, `.hudCard`, `.hudCardElevated`, status colors
- `apps/swift/Sources/Capacitor/Theme/GlassConfig.swift` — spacing, corner radius, and effect parameters
- `apps/swift/Sources/Capacitor/Theme/Motion.swift` — animation/motion preferences

### Typography Token Map (for migration)

| Raw value | Correct token |
|-----------|--------------|
| `.system(size: 17-18, weight: .semibold)` | `AppTypography.onboardingHeading` |
| `.system(size: 13, weight: .medium)` | `AppTypography.onboardingSubtitle` or `AppTypography.bodyMedium` |
| `.system(size: 13, weight: .semibold)` | `AppTypography.cardTitle` (`.headline`) |
| `.system(size: 12, weight: .medium)` | `AppTypography.bodySecondary` + `.weight(.medium)` or `AppTypography.labelMedium` |
| `.system(size: 12, weight: .semibold)` | `AppTypography.labelMedium` or `AppTypography.badge` |
| `.system(size: 11, weight: .semibold)` | `AppTypography.cardSubtitle` area — evaluate context |
| `.system(size: 11, weight: .medium)` | `AppTypography.cardSubtitle` |
| `.system(size: 10, weight: .semibold)` | `AppTypography.label.weight(.semibold)` or `AppTypography.badge` |
| `.system(size: 10, weight: .medium)` | `AppTypography.labelMedium` |
| `.system(size: 10, design: .monospaced)` | `AppTypography.monoCaption` |
| `.system(size: 14, weight: .medium)` | `AppTypography.bodyMedium` (close enough at callout scale) |
| `.system(size: 14, weight: .bold)` | `AppTypography.cardTitle.bold()` or new token if needed |
| `.system(size: 14, weight: .semibold)` | `AppTypography.cardTitle` |

Use your best judgment — the goal is semantic consistency, not a blind find-replace. If a raw size genuinely doesn't map to an existing token, note it and consider whether a new token should be added to `Typography.swift`.

### Opacity Hierarchy (for audit)

The established text opacity tiers (on `.white`):

| Tier | Opacity | Usage |
|------|---------|-------|
| Primary | 0.9 | Main content text, project names |
| Secondary | 0.7 | Section headers, secondary labels |
| Tertiary | 0.5–0.55 | Hints, placeholders, de-emphasized |
| Quaternary | 0.4 | Subtitles, metadata, disabled |
| Subtle | 0.2–0.3 | Borders, dividers, ghost elements |

Flag any text using opacity values that don't fall cleanly into one of these tiers (e.g., 0.45, 0.6, 0.8, 0.85, 0.95).

---

## Phase 0: Read the Design System

**Read all four theme files cover-to-cover.** Internalize every token. This is the source of truth for all audit decisions.

Files to read:
- [ ] `apps/swift/Sources/Capacitor/Theme/Typography.swift`
- [ ] `apps/swift/Sources/Capacitor/Theme/Colors.swift`
- [ ] `apps/swift/Sources/Capacitor/Theme/GlassConfig.swift`
- [ ] `apps/swift/Sources/Capacitor/Theme/Motion.swift`

---

## Phase 1: Exhaustive Surface Audit

**Goal**: Read every production view file. For each file, document every instance of:
- Raw `.font(.system(size:))` that should use an `AppTypography` token
- `.white.opacity(X)` values that don't match the established tiers
- Hardcoded padding/spacing that could use `GlassConfig` values
- Inconsistent corner radii (should match GlassConfig panel/card radius)
- Inconsistent border weights or opacity
- Inconsistent animation springs (response/damping values)
- Any other visual style that diverges from the patterns in sibling views

**Do not edit files during this phase.** Only read and catalog findings.

Record your findings in a structured format per file, then summarize into categories for Phase 2+.

### 1A: Core Chrome (header, footer, navigation shell)

- [ ] `apps/swift/Sources/Capacitor/ContentView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Header/HeaderView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Footer/FooterView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/AnchorEdgeGlow.swift`

### 1B: Project List & Cards (the primary surface)

- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardComponents.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardModifiers.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardGlow.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardDropDelegate.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/CompactProjectCardView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift`

### 1C: Project Detail & Drill-ins

- [ ] `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/WorkstreamsPanel.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift`

### 1D: Dock Layout (alternate presentation)

- [ ] `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Projects/DockProjectCard.swift`

### 1E: Ideas (capture + queue + detail)

- [ ] `apps/swift/Sources/Capacitor/Views/Ideas/IdeaCapturePopover.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Ideas/IdeaQueueView.swift`

### 1F: Setup & Onboarding

- [ ] `apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Setup/SetupStepRow.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Setup/ShellInstructionsSheet.swift`

### 1G: Settings

- [ ] `apps/swift/Sources/Capacitor/Views/Settings/SettingsView.swift`

### 1H: Shared Components (these affect everything)

- [ ] `apps/swift/Sources/Capacitor/Views/Components/SharedStyles.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/ToastView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/TipTooltipView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/SetupStatusCard.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/QuickFeedbackSheet.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/VibrancyActionButton.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/PageScaffold.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/ScrollEdgeFadeMask.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/BrandLogomark.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/MarkdownTextView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/VibrancyView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/CaptureImageView.swift`
- [ ] `apps/swift/Sources/Capacitor/Views/Components/ScrollViewScrollerInsetsConfigurator.swift`

---

## Phase 2: Typography Migration

**Goal**: Replace every raw `.font(.system(size:))` in production views with the correct `AppTypography` token.

Work through files in the same order as Phase 1 (A→H). For each file:
1. Re-read the file (it's now your turn to edit)
2. Replace each raw font with the mapped token from the table above
3. If a raw size has no good semantic match, add a new token to `Typography.swift` with a clear name — but only if it appears in 2+ places
4. If a size appears exactly once and is truly unique (e.g., an icon font size for SF Symbols), leave it raw but add a brief inline comment explaining why

**After completing all files in this phase:**
- Run `cargo fmt` (Rust side, just in case)
- Run `./scripts/dev/restart-alpha-stable.sh`
- Commit: `Migrate raw font sizes to AppTypography tokens across all production views`

---

## Phase 3: Opacity & Color Consistency

**Goal**: Normalize all `.white.opacity(X)` values in production views to the established tier system.

For each production view file (same A→H order):
1. Re-read the file
2. For every `.white.opacity(X)` or `.foregroundColor(.white.opacity(X))`:
   - If the value is near a tier but slightly off (e.g., 0.45 → 0.4, 0.85 → 0.9, 0.6 → 0.55), snap it to the nearest tier
   - If the value is intentionally between tiers for a specific visual effect (hover state interpolation, animation target), leave it and note why
3. Check for any hardcoded colors that should use semantic tokens from `Colors.swift` (e.g., raw `Color(hue:)` that duplicates a status color)

**Consider**: If you find yourself writing `.white.opacity(0.9)` or `.white.opacity(0.4)` repeatedly, consider whether the design system should define named colors like `Color.textPrimary`, `Color.textSecondary`, etc. If the pattern is clear and pervasive, add them to `Colors.swift`. This is a judgment call — only do it if the improvement is obvious.

**After completing:**
- Run `./scripts/dev/restart-alpha-stable.sh`
- Commit: `Normalize text and element opacity values to consistent tier system`

---

## Phase 4: Spacing & Layout Consistency

**Goal**: Ensure padding, margins, and spacing are consistent across peer surfaces.

Audit dimensions for these groups of sibling views that should share spacing:

1. **Card internal padding**: `ProjectCardView`, `CompactProjectCardView`, `DockProjectCard`, `SetupStatusCard` — should all use consistent internal padding
2. **Section spacing**: `ProjectsView` section gaps, `ProjectDetailView` section gaps, `IdeaQueueView` section gaps — should use the same vertical rhythm
3. **Modal/sheet padding**: `QuickFeedbackSheet`, `IdeaDetailModal`, `IdeaCapturePopover`, `ShellInstructionsSheet` — should share edge insets
4. **Header/footer padding**: `HeaderView` and `FooterView` horizontal padding should match
5. **Corner radii**: All cards should use `GlassConfig.shared.cardCornerRadius` (or equivalent), all panels should use `GlassConfig.shared.panelCornerRadius`

Only fix values that are clearly inconsistent with their peers. Don't force-unify values that are intentionally different (e.g., dock cards being more compact is by design).

**After completing:**
- Run `./scripts/dev/restart-alpha-stable.sh`
- Commit: `Harmonize spacing and padding across peer UI surfaces`

---

## Phase 5: Animation & Interaction Consistency

**Goal**: Ensure spring parameters and interaction feedback are consistent.

Audit:
1. **Hover springs**: All hover scale animations should use the same response/damping
2. **Press springs**: All press feedback should use the same response/damping
3. **Entry animations**: Staggered entry animations across views should use consistent delay increments
4. **Transition animations**: Navigation transitions in `NavigationContainer` vs modal presentations — should feel like the same app

This phase is likely light on changes — the exploration showed fairly consistent spring values already. Focus on any outliers.

**After completing:**
- Run `./scripts/dev/restart-alpha-stable.sh`
- Commit: `Standardize animation springs and interaction feedback`

---

## Phase 6: Cross-Surface Visual QA

**Goal**: Final holistic review — look at how surfaces relate to each other, not just individual file correctness.

This is a read-only pass. Check:
1. Does the **header** feel visually connected to the **project list** below it? (padding alignment, visual weight)
2. Do **project cards** in list mode vs **dock mode** feel like the same design language?
3. Does the **project detail view** feel like a natural drill-in from the card? (typography scale, color continuity)
4. Do **modals/sheets** (feedback, idea capture, idea detail, shell instructions) all feel like they belong to the same family? (background treatment, corner radius, padding, button styles)
5. Does the **setup/onboarding flow** feel consistent with the main app chrome?
6. Do **toast** and **tooltip** notifications match each other?
7. Are **empty states** styled consistently across `ProjectsView`, `DockLayoutView`, `IdeaQueueView`?

If this pass reveals issues, fix them and commit: `Cross-surface visual consistency fixes`

---

## Phase 7: Final Build + Verification

1. Run `cargo fmt`
2. Run `cargo clippy -- -D warnings`
3. Run `./scripts/dev/restart-alpha-stable.sh`
4. Confirm app launches and renders without visual regressions
5. Run `cargo test` to catch any Rust-side issues from the build

If everything passes, the branch is ready for review.

---

## Files Explicitly Out of Scope

These are debug/developer tools and should **not** be touched:

- `Views/Debug/UITuningPanel/UITuningPanel.swift`
- `Views/Debug/UITuningPanel/StickySection.swift`
- `Views/Debug/UITuningPanel/TuningSections.swift`
- `Views/Debug/DebugActivationTraceCard.swift`
- `Views/Debug/DebugActiveStateCard.swift`
- `Views/Debug/DebugProjectListPanel.swift`
- `Views/Debug/DebugSessionStateCard.swift`
- `Views/Debug/RuntimeStatus/RuntimeStatusBadge.swift`
- `Views/Debug/RuntimeStatus/RoutingRolloutBadge.swift`
