# TODO

## Goals
- Eliminate cognitive overhead of context-switching between projects
- Surface project context automatically (no manual tracking)
- Enable instant resume: see status at a glance → pick project → jump in with full context in seconds
- Optimize users' Claude Code experience by closing the gap between novice and expert setups

## High Priority

(All items completed — see Completed section below)

## Medium Priority

### Platform Features (Researched - Ready for Implementation)

#### Plan Files Integration
**Research complete.** Plan files are stored in `~/.claude/plans/{adjective-animal}.md` (e.g., `zesty-frolicking-yeti.md`). They're permanent Markdown documents created via Plan Mode (`--permission-mode plan` or `Shift+Tab`).

**Implementation options:**
- [x] Add "Plans" section to Artifacts tab (alongside Skills, Commands, Agents)
- [x] Show project-associated plans in Project Detail view
- [x] Add plan search/filter by name, date, or content
- [x] Enable in-app plan viewing with Markdown rendering
- [x] Optional: status tracking (implemented/in-progress/archived)

#### Todos Feature
**Research complete.** Two todo systems exist:
1. **Session-scoped**: TodoWrite tool (not persisted after session)
2. **Persistent**: `~/.claude/todos/{uuid}-agent-{uuid}.json` files

**Implementation options:**
- [x] Parse and display `~/.claude/todos/*.json` files per project
- [x] Add "Todos" section to Project Detail view
- [x] Show todo completion status on project cards (e.g., "3/7 tasks")
- [x] Optional: Allow marking todos complete from HUD
- [x] Optional: Create new todos from HUD (writes to project's todos.json)

#### Agent SDK
**Research complete.** Already have custom SDK implementation in `apps/daemon/` based on `--output-format stream-json`. Reserved for mobile/remote client integration.

**Architecture decision:** Local sessions use hooks (preserves TUI), remote/mobile will use daemon with SDK.

**Future implementation:**
- [ ] Complete relay WebSocket server for mobile client sync
- [ ] Build mobile companion app that connects to relay
- [ ] Consider background agent spawning for parallel tasks

## Research / Exploration

### Strategic Explorations (Researched - Ready for Design/Implementation)

#### Projects View IA Redesign
**Analysis complete.** Current Recent/Dormant split optimizes for recency but users need urgency.

**Key insight:** A project "Ready" for 18h is more urgent than one "Working" for 5m.

**Recommended IA:**
```
Summary Bar: "3 need input • 2 working • 15 paused"
├── NEEDS YOUR INPUT (Ready state) — full cards, prominent
├── IN PROGRESS (Working/Compacting) — full cards
├── BLOCKED (has blocker text) — full cards with warning
└── PAUSED (idle >24h or manual) — compact rows, collapsed
```

**Key changes:**
- [x] Add summary bar with action-required counts
- [x] Group by urgency (Ready > Blocked > Working > Paused) not recency
- [x] Make "working on" text primary, project name secondary
- [x] Add "stale" indicator for Ready >24h
- [x] Rename "Dormant" to "Paused" with context preservation
- [ ] Consider alternative views: Kanban, Agenda, Focus Mode

#### Claude Code Coach
**Design complete.** Transform HUD from passive viewer to active enhancer.

**Four pillars:**

1. **CLAUDE.md Health Score** (A/B/C/D/F badge on cards)
   - Checks: description, commands, architecture, style rules, freshness
   - [x] Implement health scoring algorithm
   - [x] Add badge to project cards
   - [x] Create improvement suggestions with templates (popover with copy-to-clipboard)

2. **Hooks Setup Wizard**
   - Detects current hook configuration
   - [x] One-click "Install HUD Hooks" button (copy config to clipboard)
   - [x] Show setup status (None/Basic/Complete/Custom)
   - [x] Diff preview before applying changes

3. **Plugin Recommendations**
   - Analyzes project files for tech stack
   - [x] Detect project type from files (package.json, Cargo.toml, etc.)
   - [x] Cross-reference with plugin registry
   - [x] Show contextual "Recommended Plugins" section

4. **Usage Insights**
   - Parse session JSONL for metrics
   - [x] Weekly digest: sessions, tokens, estimated cost
   - [x] Trend sparklines and anomaly alerts
   - [x] Coaching tips based on patterns

**Implementation phases:** Health Score → Hooks Wizard → Plugins → Insights

## Completed

- [x] Artifacts Browser: Skills, Commands, Agents (January 2026):
  - Skills tab shows all skills from ~/.claude/skills/ directories
  - Commands tab shows all commands from ~/.claude/commands/*.md files
  - Agents tab shows all agents from ~/.claude/agents/*.md files
  - Each artifact displays: name, description, source (user/plugin), file path
  - Expandable cards show full file content with syntax highlighting
  - Copy to clipboard and open in editor actions
  - Search filtering across name and description
  - Lazy content loading for performance
  - Uses hud-core Rust library via UniFFI for artifact discovery
  - Consistent with Plans tab UX patterns

- [x] CLAUDE.md Health Score + Coaching (January 2026):
  - Health scoring algorithm analyzes CLAUDE.md content for: project description, workflow/commands, architecture info, style rules, sufficient detail
  - Grades: A (90+), B (75-89), C (60-74), D (40-59), F (<40), None (no CLAUDE.md)
  - Color-coded circular badge on project cards (green=A, yellow=C, red=F)
  - Click badge for detailed popover showing pass/fail status for each criterion
  - Copy-to-clipboard templates for missing sections (one-click improvement)

- [x] Plans Integration (January 2026):
  - PlansManager scans `~/.claude/plans/` for plan files
  - PlansSection in Project Detail shows recent plans with Markdown preview
  - Sorted by modification date
  - Full Artifacts view with Plans tab featuring:
    - Search/filter by name or content
    - Sort by date, name, or size (plus status)
    - Expandable plan cards with full content preview
    - Copy to clipboard and open in editor actions
  - Plan status tracking:
    - Four status types: Active, In Progress, Implemented, Archived
    - Status filter chips with counts
    - Click status badge to change via dropdown menu
    - Status persists in ~/.claude/hud-plan-statuses.json
    - Color-coded borders and badges

- [x] Todos Integration (January 2026):
  - TodosManager parses `~/.claude/todos/*.json` files
  - TodosSection in Project Detail shows todos with completion status
  - Groups: In Progress, Pending, Completed
  - Interactive todo management:
    - Click checkbox to toggle completed/pending status
    - Menu to set todo as "in_progress" or "completed"
    - Add new todos via + button and inline text field
    - Changes write back to original todo JSON files

- [x] Usage Insights (January 2026):
  - UsageInsightsManager parses session JSONL files for token usage
  - Weekly digest: sessions this week, tokens this week, estimated cost
  - 7-day sparkline showing daily activity
  - Average tokens per session metric
  - Pricing based on Claude API rates (input $3/M, output $15/M, cache $0.30/M)
  - Coaching tips based on usage patterns:
    - Cache efficiency tips (encourages prompt caching when cache ratio is low)
    - Session size guidance (suggests smaller sessions for very long averages)
    - Power user recognition (celebrates high activity)
    - Welcome back prompts (when no sessions this week)
    - Cost awareness warnings (for high estimated costs)
    - Output ratio analysis (suggests focused prompts for high output ratios)

- [x] Plugin Recommendations (January 2026):
  - ProjectTypeDetector scans project files (package.json, Cargo.toml, requirements.txt, etc.)
  - Detects tech stack: React, Next.js, TypeScript, Tailwind, Rust, Python, Go, Ruby, Docker
  - PluginRecommender suggests relevant plugins based on detected tech
  - PluginRecommendationSection in Project Detail shows contextual recommendations

- [x] Hooks Setup Wizard (January 2026):
  - HooksManager detects current hooks configuration from ~/.claude/settings.json
  - HooksSetupSection shows status (None/Basic/Complete/Custom) with visual indicator
  - Shows which hooks are configured (UserPromptSubmit, PostToolUse, Stop, Notification)
  - One-click copy-to-clipboard for recommended hooks configuration
  - Setup sheet with full configuration preview
  - Diff preview showing current vs recommended hooks (added/removed highlighting)

- [x] Projects View IA Redesign (January 2026):
  - Urgency-based grouping: "Needs Input" (Ready) → "In Progress" (Working/Waiting/Compacting) → "Paused" (everything else)
  - Summary bar shows counts: "3 need input • 2 working • 15 paused"
  - Stale indicator for Ready state >24h (subtle "stale" pill badge)
  - Paused section collapsed by default with expand/collapse toggle
  - Renamed "Dormant" to "Paused" throughout
  - Typography: "working on" text now primary (13pt semibold), project name secondary (11pt regular 55% opacity)
  - Removed drag-and-drop reordering (projects now auto-sorted by urgency)

- [x] Dark UI polish pass (January 2026):
  - Border glow made thinner (0.75/1.25 lineWidth vs previous 1.5/2.5)
  - Added 7 tunable parameters in GlassTuningPanel for border glow (inner/outer width, blur, base opacity, pulse intensity, rotation multiplier)
  - Removed blur from breathing dot (configurable shadow radius, default 0)
  - Breathing dot scaling speed already controlled via rippleSpeed parameter
  - Tabs moved to bottom iOS-style with folder.fill and sparkles icons
  - Section headers simplified: removed orange dot/line, font 11 medium with 0.5 tracking
  - Search bar removed from Projects view
  - Dormant projects redesigned: minimal text rows, click anywhere to activate, smooth scale+opacity transitions
  - Info icon: hover effect simplified to opacity-only, moved next to title
  - Refactored SwiftUI: removed HoverButtonStyle, NavigationDirection, ViewTransition.swift, sectionLine gradient
  - tmux integration improved: detects attached clients, switches sessions or launches new terminal with `tmux new-session -A`
  - Added Ghostty terminal support, proper fallback order for terminal apps

- [x] Focused project detection: highlights the project card matching the currently focused terminal window
  - Backend polls frontmost app via AppleScript
  - Detects Warp, Terminal.app, iTerm2 working directories
  - Matches against pinned projects
  - Shows lighter background on focused card
- [x] UI polish pass: improved scannability and reduced visual noise
  - Working state: Claude-colored border (no animation), card not dimmed
  - Ready state: green pulsing glow border
  - "Your turn" label changed to "Ready"
  - Orange accent color replaced with neutral gray throughout
  - Project name font size increased from 13px to lg (18px)
  - Context usage indicator removed (not helpful)
- [x] Visual state indicators: animated borders (working=amber glow, ready=blue pulse, compacting=shimmer), color-coded state labels, context % display
- [x] Typography improvements: proper hierarchy (name 15px → working on 13px → next step 12px → stats 10px), color-coded states, tighter spacing
- [x] Context tracking: hooks write state to centralized file, status line provides context %, real-time file watching
- [x] Remove the Global tab and view entirely
- [x] Remove the Refresh button
- [x] Move Plugins into the Artifacts page as another tab
- [x] Fix project list badges readability in dark mode (now uses low alpha backgrounds, prominence matches state)
- [x] Add loading state when adding a new project (shows feedback during stats computation)
- [x] Terminal detection for play button: now detects existing terminals in project directory and focuses them instead of opening new ones (uses sysinfo crate for process detection, AppleScript for window focus)
- [x] Swift App feature parity: interactive cards, terminal launch, navigation, blocker display, breathing animations, Recent/Dormant sections, flash on state change, compact cards, relative time, staggered animations, left accent bar, search filter
- [x] Swift App: smooth navigation transitions with spring animations (response: 0.35, damping: 0.86)
  - Custom push/pop slide transitions based on navigation direction
  - Polished back button with hover state and Cmd+[ keyboard shortcut
- [x] Swift App: removed project path text from cards (cleaner visual hierarchy)
- [x] Swift App: manual dormant control via context menu
  - Right-click Recent card → "Move to Dormant"
  - Right-click Dormant card → "Move to Recent" (only shown for manually bumped projects)
  - Persists in UserDefaults, animated transitions between sections
- [x] Swift App: window resizing with intelligent content adaptation
  - Min: 280×400, Ideal: 360×700, Max: 500×∞
  - Uses .windowResizability(.contentSize)
- [x] Swift App: drag-and-drop project sorting in Recent section
  - Custom order persists to UserDefaults
  - Spring animations during reordering
- [x] Swift App: fancy native color effects for status pills
  - Gradient fills with top-to-bottom opacity variation
  - Subtle borders and drop shadows on active states
- [x] Swift App: press feedback on project cards
  - PressableButtonStyle with 0.98 scale effect
  - Spring animation for tactile feel
- [x] Swift App: transparent chrome mode (⌘⇧T)
  - NSVisualEffectView with .hudWindow material
  - Cards float on blurred desktop background
  - Persists via @AppStorage
- [x] Swift App: dev environment automation
  - Auto-detects dev servers via HTTP probing (works remotely, no local process access needed)
  - Parses package.json to infer expected port from dev scripts (vite, next, angular, --port flags)
  - Shows `:port` button on project cards when dev server is running
  - "Open in Browser" context menu option focuses existing browser tab
  - Project detail view with Quick Actions section
  - "Launch Full Environment" button opens terminal + browser together
  - Uses AppleScript to find and focus existing browser tabs (Arc, Chrome, Safari)
