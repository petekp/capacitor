# Idea Capture UI Integration - Implementation Plan

**Status:** Ready to implement
**Estimated time:** 2-3 hours
**Phase:** 1A - Capture MVP (UI integration only)

---

## Context

Phase 1A backend is complete:
- ✅ Rust `ideas.rs` module with ULID generation, markdown parsing, CRUD
- ✅ Swift bindings generated via UniFFI
- ✅ `AppState` has capture/load methods and state (`projectIdeas`, `showCaptureModal`)
- ✅ `TextCaptureView` (modal) and `IdeaCardView` (display) components built

**This plan:** Wire up the UI in ProjectsView to enable capture → display flow.

---

## User Requirements (from interview)

1. **Capture button placement:** 3 entry points
   - Per-project button in ProjectCardView toolbar
   - Context menu "Capture Idea..." option (right-click)
   - Section header "Capture Idea" button (captures for active project)

2. **Display location:** Inline below each ProjectCardView

3. **Filtering logic:**
   - Show first 5 ideas with status `open` or `in-progress`
   - Display "+ N more ideas" link if more exist
   - Hide `done` ideas automatically

4. **Click behavior:** Nothing yet (Phase 1A scope - just display)

5. **Modal presentation:** Single `.sheet()` at ProjectsView level using existing `appState.showCaptureModal`

---

## Implementation Steps

### 1. Add Modal Presentation to ProjectsView

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

**Location:** Add at the end of `body`, after the ScrollView closing brace

```swift
.sheet(isPresented: $appState.showCaptureModal) {
    if let project = appState.captureModalProject {
        TextCaptureView(
            projectPath: project.path,
            projectName: project.name,
            onCapture: { text in
                appState.captureIdea(for: project, text: text)
            }
        )
    }
}
```

**Why here:** ProjectsView already manages project list state, follows existing pattern for "New Idea" modal.

---

### 2. Add Idea Filtering Helper to ProjectsView

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

**Location:** Add after existing computed properties (after `pausedProjects`)

```swift
private func filteredIdeas(for project: Project) -> ([Idea], Int) {
    let allIdeas = appState.getIdeas(for: project)

    // Filter to open + in-progress only
    let activeIdeas = allIdeas.filter { idea in
        idea.status == "open" || idea.status == "in-progress"
    }

    let displayLimit = 5
    let displayed = Array(activeIdeas.prefix(displayLimit))
    let remaining = max(0, activeIdeas.count - displayLimit)

    return (displayed, remaining)
}
```

**Returns:** Tuple of (ideas to display, remaining count)

---

### 3. Display IdeaCardViews Inline

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

**Location:** Inside `ForEach(activeProjects, id: \.path)` block, immediately after the ProjectCardView

```swift
ForEach(activeProjects, id: \.path) { project in
    ProjectCardView(
        // ... existing props ...
    )
    .id("active-\(project.path)")
    .onDrop(/* ... existing drop delegate ... */)

    // NEW: Display ideas inline
    let (ideas, remaining) = filteredIdeas(for: project)
    if !ideas.isEmpty {
        VStack(spacing: 6) {
            ForEach(ideas, id: \.id) { idea in
                IdeaCardView(idea: idea, onTap: {
                    // Phase 1A: No action yet
                })
                .padding(.horizontal, 12)
            }

            if remaining > 0 {
                Button(action: {
                    // TODO Phase 1B: Navigate to project detail with ideas tab
                    appState.showProjectDetail(project)
                }) {
                    Text("+ \(remaining) more idea\(remaining == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
    }
}
```

**Repeat for `pausedProjects`** - Add the same inline display block after the ProjectCardView in the "Paused" section (around line 123).

---

### 4. Add Per-Project Capture Button to ProjectCardView

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`

**Goal:** Add small "+ Idea" button to card toolbar (near info/browser buttons)

**Option A: If toolbar already exists** - Add button to existing HStack
**Option B: If no toolbar** - Create minimal button row

I need to see the current card structure to recommend exact placement. For now, assume you have a toolbar area. Add this button:

```swift
Button(action: {
    onCaptureIdea()
}) {
    Image(systemName: "lightbulb")
        .font(.system(size: 14))
        .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.6))
}
.buttonStyle(.plain)
.help("Capture Idea")
```

**Add callback parameter** to ProjectCardView struct:
```swift
var onCaptureIdea: (() -> Void)?
```

**Wire up in ProjectsView** when creating ProjectCardView:
```swift
onCaptureIdea: {
    appState.showIdeaCaptureModal(for: project)
}
```

---

### 5. Add Context Menu Option

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`

**Location:** Add `.contextMenu` modifier to the card content

```swift
.contextMenu {
    Button(action: {
        onCaptureIdea?()
    }) {
        Label("Capture Idea...", systemImage: "lightbulb")
    }

    // ... existing context menu items if any ...
}
```

---

### 6. Add Section Header Capture Button

**File:** `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

**Location:** Update SectionHeader initialization (around line 51)

```swift
SectionHeader(
    title: "In Progress",
    count: activeProjects.count,
    showNewIdea: true,
    onNewIdea: { appState.showNewIdea() },
    showCaptureIdea: true,  // NEW
    onCaptureIdea: {         // NEW
        // Capture for most recently active project
        if let activePath = appState.activeProjectPath,
           let project = activeProjects.first(where: { $0.path == activePath }) {
            appState.showIdeaCaptureModal(for: project)
        } else if let firstProject = activeProjects.first {
            // Fallback to first project if no active project
            appState.showIdeaCaptureModal(for: firstProject)
        }
    }
)
```

**Note:** You'll need to update SectionHeader component to accept these new parameters. If that's too much work, skip this button for now and just use per-card + context menu.

---

## Verification Checklist

### Basic Flow
- [ ] Click "+ Idea" button on project card → modal appears
- [ ] Type idea text, click "Capture" → modal dismisses
- [ ] Idea card appears inline below project card
- [ ] Check `.claude/ideas.local.md` in project → idea exists in markdown

### Filtering
- [ ] Create 6 ideas for one project
- [ ] Verify only 5 display inline
- [ ] Verify "+ 1 more idea" link appears
- [ ] Mark 2 ideas as "done" manually in markdown
- [ ] Verify they disappear from display

### Multiple Entry Points
- [ ] Per-card button works
- [ ] Right-click context menu "Capture Idea..." works
- [ ] Section header button captures for active project (if implemented)

### Edge Cases
- [ ] Project with 0 ideas shows no cards (clean)
- [ ] Capture while another modal is open (should queue/replace)
- [ ] Very long idea text truncates properly in IdeaCardView

---

## Performance Considerations

**File watching:** Phase 1A doesn't have real-time file watching yet. Ideas only refresh on:
- App restart
- Manual project reload
- After capturing a new idea (AppState calls `loadIdeas(for:)`)

**Phase 1B** will add FSEvents-based file watching for live updates when Claude edits the markdown.

---

## Next Steps After This Plan

1. **Phase 1B:** Add "Work On This" button to IdeaCardView that launches terminal with idea context
2. **Phase 1C:** Add file watcher for `.claude/ideas.local.md` changes (live updates)
3. **Phase 2:** AI-powered idea triage and enrichment

---

## Open Questions

1. **SectionHeader modification:** Does it already support additional buttons, or do we need to refactor it?
2. **ProjectCardView toolbar:** Where exactly should the lightbulb button go? Need to see current layout.
3. **Error handling:** Should failed captures show an alert, or just log silently?

---

## Critical Files to Modify

1. `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift` - Main integration point
2. `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift` - Add button + context menu
3. `apps/swift/Sources/ClaudeHUD/Views/Header/SectionHeader.swift` - Add capture button (optional)

---

**Ready to implement?** Start with step 1 (modal presentation) and work sequentially. Each step builds on the previous.
