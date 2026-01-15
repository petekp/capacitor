# Project Detail View Cleanup & Redesign

**Status:** Ready to implement
**Created:** 2026-01-15
**Scope:** Full cleanup of legacy sections + new focused design

---

## Goal

Strip ProjectDetailView down to essentials and refocus it as the "full view" for a project:
1. Project name
2. AI-generated description (from CLAUDE.md, user-triggered)
3. Complete ideas list grouped by status

Remove all legacy sections from early iteration that no longer fit the product vision.

---

## Decisions Made

| Question | Decision |
|----------|----------|
| Description source | AI-summarized from CLAUDE.md via Haiku |
| Description timing | Manual trigger ("Generate Description" button) |
| Cleanup scope | Full cleanup — delete orphaned files + remove managers |
| Ideas display | All ideas, grouped by status (Open, In Progress, Done) |

---

## Files to Delete

These become orphaned after removing sections from ProjectDetailView:

```
apps/swift/Sources/ClaudeHUD/Views/Projects/
├── HealthCoachingSection.swift      ← DELETE
├── HooksSetupSection.swift          ← DELETE
├── PlansSection.swift               ← DELETE
├── PluginRecommendationSection.swift ← DELETE
├── UsageInsightsSection.swift       ← DELETE
└── TodosSection.swift               ← DELETE
```

---

## Code to Remove from AppState

### Properties to remove:
- `todosManager: TodosManager`
- `plansManager: PlansManager`
- Any `@Published` properties for todos/plans

### Classes to remove (if defined in AppState.swift or separate files):
- `TodosManager` class
- `PlansManager` class

### Utils to evaluate:
- `ClaudeMdHealth.swift` / `ClaudeMdHealthScorer` — check if used elsewhere, delete if orphaned

---

## New ProjectDetailView Structure

```swift
struct ProjectDetailView: View {
    // KEEP: project, appState, floatingMode, appeared
    // REMOVE: devServerPort computed property
    // REMOVE: isLaunchHovered, isLaunchPressed states

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Back button (KEEP)
                BackButton(...)

                // 2. Project name (KEEP, but remove HealthBadge)
                Text(project.name)
                    .font(.system(size: 22, weight: .bold))

                // 3. NEW: Description card
                DescriptionCard(
                    description: project.description,  // cached
                    isGenerating: isGeneratingDescription,
                    onGenerate: { generateDescription() }
                )

                // 4. NEW: Ideas sections
                IdeasListView(
                    openIdeas: openIdeas,
                    inProgressIdeas: inProgressIdeas,
                    doneIdeas: doneIdeas,
                    onWorkOn: { idea in ... },
                    onDismiss: { idea in ... }
                )
            }
        }
    }
}
```

---

## Implementation Steps

### Phase 1: Delete Orphaned Files

1. Delete the 6 section files listed above
2. Build to identify any remaining references
3. Remove any imports or usages that cause build errors

### Phase 2: Clean AppState

1. Remove `todosManager` property and initialization
2. Remove `plansManager` property and initialization
3. Remove any todo/plan-related methods
4. Remove `TodosManager` and `PlansManager` classes (find where defined)
5. Delete `ClaudeMdHealth.swift` if orphaned

### Phase 3: Gut ProjectDetailView

1. Remove all DetailCard sections except back button and name
2. Remove HealthBadge from header
3. Remove unused state variables (isLaunchHovered, isLaunchPressed)
4. Remove devServerPort computed property
5. Keep: BackButton, project name, ScrollView structure, appeared animation

### Phase 4: Add Description Feature

1. Add `projectDescriptions: [String: String]` to AppState (path → description cache)
2. Add `generatingDescriptionFor: Set<String>` for loading state
3. Add `generateProjectDescription(for: Project)` method using Haiku
4. Create `DescriptionCard` component:
   - Shows description if cached
   - Shows "Generate Description" button if not
   - Shows shimmer during generation
5. Wire up in ProjectDetailView

### Phase 5: Add Ideas List

1. Create `IdeasListView` component with grouped sections:
   - "Open" section header + ideas
   - "In Progress" section header + ideas
   - "Done" section header + ideas (collapsed by default?)
2. Reuse existing `IdeaCardView` for individual ideas
3. Add filtering logic to ProjectDetailView to split ideas by status
4. Wire up onWorkOn and onDismiss callbacks

### Phase 6: Verify & Polish

1. Test "Show More" from ProjectsView navigates correctly
2. Test description generation flow
3. Test all idea interactions (Work On This, Dismiss)
4. Verify smooth animations on appear
5. Check empty states (no ideas, no description)

---

## New Components Needed

### DescriptionCard
```swift
struct DescriptionCard: View {
    let description: String?
    let isGenerating: Bool
    let onGenerate: () -> Void

    var body: some View {
        DetailCard {
            if isGenerating {
                ShimmeringText(text: "Generating description...")
            } else if let description = description {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
            } else {
                Button("Generate Description", action: onGenerate)
                    // styled as secondary action
            }
        }
    }
}
```

### IdeasListView
```swift
struct IdeasListView: View {
    let openIdeas: [Idea]
    let inProgressIdeas: [Idea]
    let doneIdeas: [Idea]
    var onWorkOn: ((Idea) -> Void)?
    var onDismiss: ((Idea) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !openIdeas.isEmpty {
                IdeaSection(title: "OPEN", ideas: openIdeas, ...)
            }
            if !inProgressIdeas.isEmpty {
                IdeaSection(title: "IN PROGRESS", ideas: inProgressIdeas, ...)
            }
            if !doneIdeas.isEmpty {
                IdeaSection(title: "DONE", ideas: doneIdeas, isCollapsed: true, ...)
            }
            if openIdeas.isEmpty && inProgressIdeas.isEmpty && doneIdeas.isEmpty {
                EmptyIdeasView()
            }
        }
    }
}
```

---

## Rust Changes Required

### New function in ideas.rs or engine.rs:
- `get_all_ideas(project_path: String) -> Vec<Idea>` (if not already exposed)

### New function for description caching:
- Could reuse existing summary caching pattern
- Or add to hud.json / separate cache file

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Breaking other code that uses deleted managers | Build after each deletion phase, fix errors |
| Losing useful functionality permanently | This is intentional — early iteration features being removed |
| Description generation failures | Same error handling as idea titles (graceful fallback) |

---

## Out of Scope

- Bringing back any of the deleted features
- Adding new project actions (terminal, browser) — removed intentionally
- Real-time idea file watching (separate future work)

---

## Success Criteria

- [ ] ProjectDetailView shows only: name, description, ideas
- [ ] All 6 section files deleted
- [ ] todosManager and plansManager removed from AppState
- [ ] Description generates on button click, caches result
- [ ] Ideas grouped by status with all ideas visible
- [ ] "Show More" from ProjectsView navigates here correctly
- [ ] No build warnings about orphaned code
