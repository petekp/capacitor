# Feature Spec: Idea Capture System

## Problem Statement

**The friction of deciding where to record ideas kills momentum.** When inspiration strikes mid-flow, the overhead of choosing between TODO.md, a sticky note, Notion, or just hoping you'll remember creates enough resistance that many ideas die before capture.

**The insight:** Ideas need a dedicated inbox upstream of project creation. Not every idea deserves a full project directory and CLAUDE.md file (the existing "New Idea" feature). Some are quick thoughts, some need refinement, some will never get built—but all deserve to be captured instantly without ceremony.

**The opportunity:** Claude Code already has deep context about your projects, codebase, and working patterns. Use that context to automatically triage, categorize, and prioritize captured ideas—transforming the idea inbox from a dumping ground into an intelligent queue that surfaces the right work at the right time.

---

## User Goals

1. **Instant capture** — Get the idea out of my head in < 5 seconds, no friction
2. **Zero decision paralysis** — Don't make me decide what to do with it right now
3. **Intelligent triage** — Claude figures out priority, effort, and project associations based on context
4. **Safety without slowdown** — Fast path for high-confidence analysis, clear signals when review needed
5. **Contextual discovery** — Ideas appear where they're relevant (under associated projects), not buried in a separate tab
6. **Simple interaction model** — Obvious next actions on hover, no hunting for buttons

---

## Core Design Principles

### 1. Text-First Capture
**Rationale:** Start with the simplest input that works—text. Validates the core value (instant capture + AI triage) before investing in voice infrastructure. Fast to ship, easy to iterate.

**Mechanism:** Hybrid input model
- **Global hotkey** — Press keyboard shortcut anywhere on macOS (Cmd+Shift+I), type in floating field, hit Enter
- **In-app button** — Click "Capture Idea" button in HUD, type into modal, submit
- Both routes produce same result: text → AI analysis → triage

**Future:** When voice is added, go full sci-fi with ElevenLabs—conversational AI, ambient capture, voice synthesis for Claude responses. Not a half-measure.

### 2. Context-Aware AI Triage
**Rationale:** Claude knows your projects, recent work (via git history), current TODO items, and codebase patterns. Use that context to make intelligent inferences about where ideas belong and how important they are.

**Enrichment output:**
- **Priority:** P0 (urgent) / P1 (important) / P2 (nice-to-have) / P3 (someday)
- **Effort estimate:** Small (< 2 hours) / Medium (2-8 hours) / Large (1+ days) / XL (multi-day)
- **Project association:** Which existing project(s) this relates to, or "New Project" if standalone
- **Category/tags:** bug, feature, refactor, polish, experiment, infrastructure, etc.
- **Relationships:** "Related to projects X, Y", "Depends on idea #5", "Similar to work in DONE.md"
- **Confidence score:** 0.0-1.0 on the overall analysis quality

### 3. Confidence Flags as Safety Net
**Rationale:** Fast when confident, careful when uncertain. No blocking confirmation dialogs, but clear visual signals when AI is guessing.

**Mechanism:**
- High confidence (> 0.8): Idea appears with solid styling, ready to act on
- Medium confidence (0.5-0.8): Yellow warning icon, review recommended
- Low confidence (< 0.5): Red flag icon, review required before acting

**User can always edit** any field inline (click to change priority, reassign project, etc.) regardless of confidence level.

### 4. Inline Contextual Display
**Rationale:** Ideas aren't a separate concern—they're work waiting to happen, attached to specific projects. Show them where they belong.

**Design:**
- Ideas appear as **compact cards underneath their associated project**
- Visual hierarchy: lighter background, smaller size, subtle "idea" badge
- Collapsed by default, expandable per-project (or show count badge: "3 ideas")
- Ideas for "New Project" appear in a special section (e.g., at bottom of projects list)

### 5. Hover Actions Pattern
**Rationale:** Single interaction model that scales to multiple card types (ideas, paused projects, active projects, future types). Actions emerge on hover, no clutter at rest.

**Implementation:**
- Every card type shows a subtle action bar on hover with 2-4 context-specific buttons
- **Idea cards:** `[Refine] [Work On This] [×]`
- **Paused projects:** `[Resume] [Archive]`
- **Active projects:** `[Details] [Pause]` (terminal is the primary click)

**Benefits:**
- Consistent mental model across all card types
- No need to remember which cards have which affordances
- Fast workflow (hover → click action → done)
- Infinitely extensible for new card types

---

## Architecture

**⚠️ Core Principle:** Claude HUD is a sidecar. We leverage the user's existing Claude Code installation rather than building standalone API integration.

### Storage: Markdown Files Claude Can Read

**Per-project ideas:** `.claude/ideas.local.md` (personal, gitignored)
**Unassociated ideas:** `~/.claude/hud/inbox-ideas.md` (global inbox)

**Why markdown?**
- Claude sessions can naturally read and update these files
- Human-readable, git-friendly (if user chooses to commit)
- Bidirectional sync: HUD writes, Claude updates, HUD detects changes

**File format example:**
```markdown
<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

### [#idea-01JQXYZ8K6TQFH2M5NWQR9SV7X] Add project search
- **Added:** 2026-01-14T16:45:12Z
- **Effort:** medium
- **Status:** open
- **Triage:** validated
- **Related:** None

Dashboard needs search to find projects quickly when list grows.
Should support fuzzy matching on project name and path.

---
```

**Parsing anchors (stable identifiers):**
- `[#idea-{ULID}]` — Never changes, 26-char base32 ID
- `- **Key:** value` — Metadata lines HUD parses
- `---` — Delimiter between ideas
- `Status: done` — Check-off signal for completion

**See:** `.claude/docs/idea-capture-file-format-spec.md` for complete parsing contract.

### Data Model (Swift → Rust → Markdown)

```swift
// Swift view model (parsed from markdown)
struct Idea: Identifiable, Codable {
    let id: String              // ULID from [#idea-...]
    let createdAt: Date         // From Added: field
    var updatedAt: Date

    // Core content
    let title: String           // From heading after ID
    var description: String     // Body text after metadata

    // Triage metadata (parsed from markdown)
    var priority: Priority      // P0/P1/P2/P3 (inferred from Effort)
    var effort: Effort          // From Effort: field
    var status: IdeaStatus      // From Status: field
    var triageStatus: TriageStatus  // From Triage: field

    // Project association
    var relatedProject: String? // From Related: field

    // Confidence (ephemeral, not stored)
    var confidence: Double?     // From validation/enrichment response
}

enum Effort: String, Codable {
    case unknown, small, medium, large, xl
}

enum IdeaStatus: String, Codable {
    case open          // Not started
    case inProgress    // "Work On This" clicked
    case done          // Completed
}

enum TriageStatus: String, Codable {
    case pending       // Awaiting AI validation/enrichment
    case validated     // AI has reviewed
}
```

**Rust layer** (`core/hud-core/src/ideas.rs`):
- Parses markdown using regex anchors
- Extracts ULID, title, metadata fields, description
- Provides CRUD: `load_ideas()`, `update_idea()`, `move_idea()`
- File watcher detects external changes (Claude edits)

### Text Capture Flow (Sidecar Architecture)

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Trigger                                                      │
│    • In-app "Capture Idea" button (start simple)              │
│    • Global hotkey (Phase 2)                                   │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Text Input (< 1 second)                                     │
│    • Show modal text field                                     │
│    • User types idea                                           │
│    • Submit on Enter                                           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Immediate Save to Markdown (< 1 second)                    │
│    • Generate ULID for stable ID                               │
│    • Smart default: assume current project context            │
│    • Append to .claude/ideas.local.md:                        │
│      ### [#idea-{ULID}] {raw text}                            │
│      - Added: {timestamp}                                      │
│      - Effort: unknown                                         │
│      - Status: open                                            │
│      - Triage: pending                                         │
│      - Related: {current_project or "None"}                   │
│      {raw text as description}                                 │
│      ---                                                        │
│    • HUD displays immediately (triageStatus: pending)          │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Background Validation via Claude CLI (async, ~2 seconds)   │
│    • Extract project context (git log, file tree)             │
│    • Pipe to: claude --print --output-format json \           │
│               --json-schema {...} --tools "" --max-turns 1    │
│    • Parse response: {belongsHere, suggestedProject, ...}     │
│    • If confidence < threshold, show passive notification:    │
│      "💡 Might fit better in project-b"                       │
│    • User clicks notification to accept/dismiss suggestion    │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. Optional Enrichment (Phase 1B - Terminal)                  │
│    • User clicks "Work On This" → launches terminal           │
│    • Claude session can read .claude/ideas.local.md           │
│    • User discusses idea with Claude, Claude updates file     │
│    • HUD file watcher detects changes, refreshes UI           │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Save FIRST (durable, < 1 second), validate SECOND (passive, non-blocking).

### AI Integration via Claude CLI

**Phase 1A: Validation** (~100-200 tokens, ~$0.0005 per idea)
```bash
cat <<EOF | claude --print \
  --output-format json \
  --json-schema '{...belongsHere, suggestedProject, confidence, reasoning...}' \
  --tools "" \
  --max-turns 1
Context: User is browsing project "${PROJECT_NAME}"

Active projects: [list]

Captured idea: "${IDEA_TEXT}"

Does this idea belong to project ${PROJECT_NAME}?
EOF
```

**Phase 1B: Enrichment** (~200-400 tokens, ~$0.001 per idea)
```bash
grep -A 10 "#idea-abc123" .claude/ideas.local.md | claude --print \
  --output-format json \
  --json-schema '{...priority, effort, category, reasoning...}' \
  --tools "" \
  --max-turns 1
```

**Phase 2: Terminal Integration**
- "Work On This" launches terminal: `cd project && claude`
- Claude naturally reads `.claude/ideas.local.md`
- User discusses idea, Claude updates file (check-off, notes, enrichment)
- HUD file watcher detects changes, refreshes UI

**Phase 3: Hook-Triggered Batch Enrichment**
- SessionEnd hook checks for `Triage: pending` ideas
- Enriches all pending ideas in one CLI call
- User expects "wrap-up processing" at session end
- No continuous polling overhead

**See:** `.claude/docs/idea-capture-cli-integration-spec.md` for complete CLI integration details (commands, schemas, error handling).

---

## UI/UX Design

### Component Hierarchy

```
ProjectsView
├── SectionHeader ("Active Projects")
├── Active Projects
│   ├── ProjectCardView (expanded)
│   │   └── [hover: Details, Pause]
│   ├── → IdeaCardList (if project has ideas)
│   │   ├── IdeaCardView (compact)
│   │   │   └── [hover: Refine, Work On This, Dismiss]
│   │   └── IdeaCardView (compact)
│   │       └── [hover: Refine, Work On This, Dismiss]
│   └── ProjectCardView (expanded)
│       └── [hover: Details, Pause]
├── SectionHeader ("Paused Projects")
├── Paused Projects
│   └── CompactProjectCardView
│       └── [hover: Resume, Archive]
└── SectionHeader ("Inbox - New Project Ideas")
    └── IdeaCardList (unassociated ideas)
        └── IdeaCardView (compact)
            └── [hover: Refine, Convert to Project, Dismiss]
```

### IdeaCardView (Compact)

Visual design:
- **Height:** ~60px (vs ~120px for project cards)
- **Background:** `Color.hudCard.opacity(0.5)` (lighter than projects)
- **Border:** 1px solid `Color.hudAccent.opacity(0.3)`
- **Layout:** Horizontal stack
  - Left: Priority badge (P0/P1/P2/P3 with color coding)
  - Center: Summary text + effort chip
  - Right: Confidence indicator (⚠️ if needs review)

Hover state:
- Background brightens to `Color.hudCard.opacity(0.7)`
- Action buttons fade in from right: `[Refine] [Work On This] [×]`
- Smooth animation (0.2s ease-out)

Confidence indicators:
- High (> 0.8): No indicator (clean)
- Medium (0.5-0.8): Yellow ⚠️ with tooltip "Review recommended"
- Low (< 0.5): Red 🚩 with tooltip "Review required"

### Hover Actions Bar

Design pattern for all card types:

```swift
.overlay(alignment: .trailing) {
    if isHovered {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                ActionButton(action: action)
            }
        }
        .padding(.trailing, 12)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
```

Action button styling:
- Small pill buttons (28px height)
- Background: `Color.hudAccent.opacity(0.2)`
- Hover: `Color.hudAccent.opacity(0.4)`
- Icon + optional label (label hidden on narrow cards)
- SF Symbols: `pencil` (Refine), `play.fill` (Work On This), `xmark` (Dismiss)

### Paused Projects Redesign

Apply same hover actions pattern:
- Remove existing action buttons from default view
- Show `[Resume] [Archive]` on hover
- Consistent visual language with idea cards

---

## Technical Implementation (Sidecar Architecture)

### Phase 1A: Capture MVP (Markdown Storage + Display)

**Goal:** Instant text capture → markdown file → HUD display. No AI yet.

**Files to create/modify:**
- `core/hud-core/src/ideas.rs` — NEW: Markdown parser, ULID generation, CRUD
- `core/hud-core/src/types.rs` — Export Idea types via UniFFI
- `core/hud-core/src/engine.rs` — Add `capture_idea()`, `load_ideas()`, `update_idea_status()`
- `apps/swift/Sources/ClaudeHUD/Views/IdeaCapture/TextCaptureView.swift` — NEW: Modal input
- `apps/swift/Sources/ClaudeHUD/Views/Ideas/IdeaCardView.swift` — NEW: Display
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` — Add @Published var ideas

**Effort:** 2-3 hours

**Rust implementation:**
```rust
// core/hud-core/src/ideas.rs
use regex::Regex;
use ulid::Ulid;

pub struct Idea {
    pub id: String,              // ULID
    pub created_at: String,      // ISO8601
    pub title: String,           // From heading
    pub description: String,     // Body text
    pub effort: String,          // unknown, small, medium, large, xl
    pub status: String,          // open, in-progress, done
    pub triage: String,          // pending, validated
    pub related: Option<String>, // project name or None
}

pub fn capture_idea(
    project_path: &str,
    idea_text: &str,
) -> Result<String, HudError> {
    let id = Ulid::new().to_string();
    let timestamp = chrono::Utc::now().to_rfc3339();

    let ideas_file = format!("{}/.claude/ideas.local.md", project_path);

    // Append to Untriaged section
    let entry = format!(
        "### [#idea-{}] {}\n\
         - **Added:** {}\n\
         - **Effort:** unknown\n\
         - **Status:** open\n\
         - **Triage:** pending\n\
         - **Related:** None\n\
         \n\
         {}\n\
         \n\
         ---\n",
        id, idea_text, timestamp, idea_text
    );

    append_to_untriaged(&ideas_file, &entry)?;
    Ok(id)
}

pub fn load_ideas(project_path: &str) -> Result<Vec<Idea>, HudError> {
    let ideas_file = format!("{}/.claude/ideas.local.md", project_path);
    parse_ideas_file(&ideas_file)
}

fn parse_ideas_file(path: &str) -> Result<Vec<Idea>, HudError> {
    let content = std::fs::read_to_string(path)?;

    // Regex: ### [#idea-{ULID}] {title}
    let id_regex = Regex::new(r"### \[#idea-([A-Z0-9]{26})\] (.+)").unwrap();
    let meta_regex = Regex::new(r"- \*\*(.+?):\*\* (.+)").unwrap();

    // Parse ideas using anchors...
    // (See file-format-spec.md for complete implementation)
}

pub fn update_idea_status(
    project_path: &str,
    idea_id: &str,
    new_status: &str,
) -> Result<(), HudError> {
    // Find idea block, update Status: field
    // (See file-format-spec.md for mutation rules)
}
```

**Swift integration:**
```swift
// AppState.swift
@Published var ideas: [String: [Idea]] = [:]  // keyed by project path

func captureIdea(text: String, projectPath: String) {
    guard let engine = engine else { return }
    do {
        let ideaId = try engine.captureIdea(projectPath: projectPath, ideaText: text)
        loadIdeas(for: projectPath)
    } catch {
        print("Failed to capture idea: \(error)")
    }
}

func loadIdeas(for projectPath: String) {
    guard let engine = engine else { return }
    do {
        let projectIdeas = try engine.loadIdeas(projectPath: projectPath)
        ideas[projectPath] = projectIdeas
    } catch {
        print("Failed to load ideas: \(error)")
    }
}
```

---

### Phase 1B: Terminal Integration ("Work On This")

**Goal:** Clicking "Work On This" launches terminal with idea context. Claude reads markdown file naturally.

**Files to modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Ideas/IdeaCardView.swift` — Add "Work On This" button
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` — Add `workOnIdea()` handler

**Effort:** 1-2 hours

**Swift implementation:**
```swift
// AppState.swift
func workOnIdea(_ idea: Idea, projectPath: String) {
    // Update status to in-progress
    guard let engine = engine else { return }
    do {
        try engine.updateIdeaStatus(
            projectPath: projectPath,
            ideaId: idea.id,
            newStatus: "in-progress"
        )
    } catch {
        print("Failed to update idea status: \(error)")
    }

    // Launch terminal with context
    launchTerminal(for: projectPath, initialPrompt: """
        I want to work on this idea:

        \(idea.title)
        \(idea.description)

        The details are in .claude/ideas.local.md if you need to reference them.
        """)
}
```

**User workflow:**
1. Click "Work On This" on idea card
2. Terminal launches with `cd project && claude`
3. HUD pre-fills prompt referencing the idea
4. User discusses with Claude, Claude can read/update `.claude/ideas.local.md`
5. Claude checks off idea: `Status: done`
6. HUD file watcher detects change, marks idea complete

---

### Phase 2: Background Validation (Optional)

**Goal:** After capture, async validation suggests alternative project if confidence low.

**Files to create:**
- `apps/swift/Sources/ClaudeHUD/Services/ClaudeValidationService.swift` — NEW: CLI invocation

**Effort:** 2-3 hours (optional, can defer)

---

### Phase 3: Hook-Triggered Batch Enrichment (Future)

**Goal:** SessionEnd hook enriches all pending ideas in one CLI call.

**Files to create:**
- `~/.claude/scripts/hud-enrich-ideas.sh` — Hook script
- `.claude/settings.json` — Hook registration

**Effort:** 3-4 hours (defer until Phase 1 validated)

**Implementation:** See `.claude/docs/idea-capture-cli-integration-spec.md` § Hook Integration for complete script and permission flow.

---

### Phase 4: Hover Actions & Polish

**Files to create/modify:**
- `apps/swift/Sources/ClaudeHUD/Views/Ideas/IdeaCardView.swift` — Idea cards (ALREADY in Phase 1A)
- `apps/swift/Sources/ClaudeHUD/Views/Shared/HoverActionsBar.swift` — NEW (reusable)
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift` — Add hover actions
- `apps/swift/Sources/ClaudeHUD/Views/Projects/CompactProjectCardView.swift` — Add hover actions

**Effort:** 2-3 hours

**IdeaCardView structure:**
```swift
struct IdeaCardView: View {
    let idea: Idea
    let onRefine: () -> Void
    let onWorkOnThis: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Priority badge
            PriorityBadge(priority: idea.priority)

            // Summary + effort
            VStack(alignment: .leading, spacing: 4) {
                Text(idea.cleanedSummary)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    EffortChip(effort: idea.effort)
                    if !idea.category.isEmpty {
                        Text(idea.category.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Confidence indicator
            if idea.needsReview {
                ConfidenceIndicator(confidence: idea.confidence)
            }
        }
        .padding(12)
        .frame(height: 60)
        .background(Color.hudCard.opacity(0.5))
        .cornerRadius(8)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.hudAccent.opacity(0.3), lineWidth: 1)
        }
        .overlay(alignment: .trailing) {
            if isHovered {
                HoverActionsBar(actions: [
                    .init(icon: "pencil", label: "Refine", action: onRefine),
                    .init(icon: "play.fill", label: "Work On This", action: onWorkOnThis),
                    .init(icon: "xmark", label: nil, action: onDismiss)
                ])
                .padding(.trailing, 12)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.2), value: isHovered)
    }
}
```

**HoverActionsBar (reusable component):**
```swift
struct HoverAction: Identifiable {
    let id = UUID()
    let icon: String
    let label: String?
    let action: () -> Void
}

struct HoverActionsBar: View {
    let actions: [HoverAction]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    HStack(spacing: 4) {
                        Image(systemName: action.icon)
                            .font(.system(size: 12))
                        if let label = action.label {
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.hudAccent.opacity(0.2))
                    .cornerRadius(14)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { isHovered in
                    // Scale up slightly on hover
                }
            }
        }
    }
}
```

**Integration into ProjectsView:**
```swift
// After ProjectCardView in ForEach
if let projectIdeas = appState.ideas.filter({
    $0.projectAssociation.matches(project.path)
}) {
    IdeaCardList(ideas: projectIdeas, appState: appState)
        .padding(.leading, 20) // Indent to show hierarchy
        .padding(.bottom, 8)
}
```

---

## Resolved Decisions (Architecture Finalized)

### ✅ Storage: Per-Project Markdown Files
- **Decision:** `.claude/ideas.local.md` per-project (gitignored), `~/.claude/hud/inbox-ideas.md` for unassociated
- **Rationale:** Claude sessions can naturally read/write these files. Bidirectional sync with terminal workflow.
- **See:** `.claude/docs/idea-capture-file-format-spec.md`

### ✅ AI Integration: Claude CLI, Not Direct API
- **Decision:** Invoke `claude --print --output-format json` with stdin piping, not direct Anthropic API calls
- **Rationale:** Sidecar principle—leverage user's existing Claude Code installation
- **See:** `.claude/docs/idea-capture-cli-integration-spec.md`

### ✅ Capture Flow: Save FIRST, Validate SECOND
- **Decision:** Idea saves to markdown immediately (< 1 second), AI validation runs async (optional)
- **Rationale:** Zero friction capture is non-negotiable. Validation is a nice-to-have.

### ✅ Terminal-Based Workflow
- **Decision:** "Work On This" launches terminal with `claude`, not embedded AI in HUD
- **Rationale:** Interactive work happens in terminal where Claude has full context. HUD observes file changes.

### ✅ Single-Player Experience
- **Decision:** No team features, no shared idea pools
- **Rationale:** Focus on personal productivity first. Team features complicate storage and permissions.

---

## Remaining Open Questions

### UX Decisions

1. **In-app capture trigger:**
   - Button in header (simple, always visible)?
   - Floating action button (modern, might obstruct)?
   - Context menu on project cards ("Capture idea for this project")?
   - **Leaning:** Header button for Phase 1, evaluate after usage

4. **Idea count display:**
   - Always show all ideas under projects (could get cluttered)?
   - Show count badge ("3 ideas") and expand on click?
   - Collapse by default, keyboard shortcut to expand all?
   - **Leaning:** Count badge with click to expand per-project

5. **"Work On This" behavior:**
   - Always launch terminal with context comment?
   - Show modal asking "Add to TODO" vs "Launch Claude" vs "Convert to Project"?
   - Smart choice based on idea size (small → TODO, large → new project)?
   - **Leaning:** Smart choice with escape hatch to override

### Product Decisions

6. **Batch prioritization (future phase):**
   - Manual trigger ("Prioritize my ideas" button)?
   - Automatic nightly batch processing?
   - Triggered on context change (e.g., switching active projects)?
   - **Defer:** Phase 2 concern, validate individual triage first

7. **Idea aging/expiration:**
   - Auto-dismiss ideas older than X days if not reviewed?
   - Surface "stale ideas" report periodically?
   - Never expire, let users manage manually?
   - **Leaning:** Never expire, add "review stale ideas" action later

---

## Success Metrics

**Qualitative:**
- ✅ Capturing an idea takes < 5 seconds from trigger to saved
- ✅ High-confidence ideas (> 0.8) feel accurate, don't require editing
- ✅ Low-confidence ideas (< 0.5) are obviously flagged, editing is easy
- ✅ Hover actions feel natural and fast, no hunting for buttons
- ✅ Ideas appear in sensible locations (under correct projects)

**Quantitative:**
- Target: < 3 seconds from hotkey press to idea saved
- Target: > 80% of ideas correctly associated with projects (measured by user edits)
- Target: > 70% of ideas have confidence > 0.8 (few flags)
- Target: Average 2 or fewer user edits per idea before acting on it

**User feedback questions:**
1. Does voice capture feel faster than typing into TODO.md?
2. Are Claude's priority/effort guesses accurate?
3. Do hover actions feel obvious or hidden?
4. Is the inline display (under projects) helpful or cluttered?
5. What's the most common action you take with captured ideas?

---

## Design Decision: Text-First, Voice Later

**Decision:** Start with text input. When voice is added, go sci-fi with ElevenLabs.

**Rationale:**
- **Faster to ship:** Text input is 3-4 hours vs 6-8 hours for voice. Validates core value (AI triage + contextual display) sooner.
- **Lower risk:** No microphone permissions, speech recognition edge cases, or transcription accuracy issues.
- **Better foundation:** Proves the interaction model and AI analysis quality before layering on voice complexity.
- **No half-measures:** When voice comes, it should be extraordinary—conversational AI with ElevenLabs voice synthesis, ambient capture, full sci-fi experience. Text now, magic later.

---

## Implementation Phases (Revised for Sidecar Architecture)

### Phase 1A: Capture MVP — 2-3 hours
- Markdown parser (Rust: ULID generation, append to Untriaged)
- Text capture modal (Swift UI)
- Display idea cards inline under projects
- File watcher for Claude-initiated changes

**Goal:** Instant capture (< 1 second) → markdown → HUD display. No AI yet.

### Phase 1B: Terminal Integration — 1-2 hours
- "Work On This" button launches terminal with idea context
- Status update: `open` → `in-progress` → `done`
- HUD detects check-offs via file watcher

**Goal:** Claude can naturally work with ideas from terminal.

### Phase 2: Background Validation (Optional) — 2-3 hours
- Swift service invokes `claude --print` with stdin piping
- Passive notification if idea might fit better elsewhere
- User controls final decision (accept/dismiss suggestion)

**Goal:** Smart default + safety net without blocking capture.

### Phase 3: Hook-Triggered Enrichment (Future) — 3-4 hours
- SessionEnd hook script
- Batch enrichment of pending ideas
- Permission flow via Claude Code's review mechanism

**Goal:** Background processing with natural timing (session wrap-up).

### Phase 4: Hover Actions & Polish — 2-3 hours
- HoverActionsBar component (reusable across all card types)
- Apply to ideas, paused projects, active projects
- Visual polish (animations, spacing, confidence indicators)

**Goal:** Cohesive interaction model. Defer until Phase 1 validated.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| AI triage guesses wrong project | Medium | Clear confidence flags, easy inline editing, learn from corrections over time |
| Global hotkey conflicts with other apps | Medium | Make hotkey user-configurable, detect conflicts and warn |
| Ideas accumulate and clutter UI | Medium | Auto-collapse to count badges, add "archive completed ideas" action |
| Users forget captured ideas exist | Low | Add "X unreviewed ideas" notification to header, periodic reminders |
| Performance impact from polling | Low | Use actor isolation, limit context size, cache git history |

---

## Future Enhancements

### Near-term (3-6 months)
- **Idea relationships graph** — Visual map of dependencies and similarities
- **GitHub issue integration** — "Convert to Issue" action for ideas with repos
- **Collaborative prioritization** — Chat with Claude about which idea to work on next
- **Idea templates** — Common patterns (bug report, feature request, refactor) with structured fields

### Long-term (6-12 months)
- **Sci-fi voice capture (ElevenLabs)** — Full conversational AI: speak naturally, Claude responds with voice, ambient capture, voice synthesis. No half-measures—go all the way.
- **Cross-device sync** — Capture ideas on mobile, see in HUD on desktop
- **Team idea sharing** — Shared idea inbox for team projects
- **Automated overnight processing** — Claude reviews and ranks all ideas while you sleep
- **Learning from behavior** — Claude learns your priority patterns and effort accuracy over time

---

## Related Documents

**Executable Specifications (implementation contracts):**
- `.claude/docs/idea-capture-file-format-spec.md` — Markdown format, parsing rules, mutation contract
- `.claude/docs/idea-capture-cli-integration-spec.md` — Claude CLI invocation, JSON schemas, error handling

**Architecture & Design:**
- `docs/architecture-decisions/003-sidecar-architecture-pattern.md` — Why sidecar, not standalone
- `.claude/docs/feature-idea-to-v1-launcher.md` — Downstream project creation flow
- `CLAUDE.md` § Core Architectural Principle — Sidecar philosophy

**Reference:**
- `docs/claude-code/hooks.md` — Hook integration (Phase 3)
- `docs/claude-code-artifacts.md` — Claude Code file formats
- `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift` — Card styling precedent

---

## Next Steps

**Architecture finalized!** Ready for implementation.

1. **Phase 1A Implementation** (2-3 hours):
   - Create `core/hud-core/src/ideas.rs` with markdown parser
   - Build text capture modal in Swift
   - Display idea cards inline under projects
   - Add file watcher for bidirectional sync

2. **Phase 1B Implementation** (1-2 hours):
   - Add "Work On This" button
   - Launch terminal with idea context
   - Test bidirectional sync (HUD → markdown → Claude → markdown → HUD)

3. **Validate Core Value**:
   - Use it yourself for a week
   - Does instant capture reduce friction?
   - Does terminal integration feel natural?
   - Is markdown format robust?

4. **Then Decide**: Phase 2 (validation) or Phase 4 (polish) next?

---

*Last updated: 2026-01-15 (sidecar architecture finalized)*
