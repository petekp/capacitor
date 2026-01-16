# Completed Work

Archive of completed features and improvements. See `TODO.md` for active work.

---

## January 2026

### Dock Mode Polish Sprint (Round 1)
- Restored mono font on project title (sectionTitle.monospaced)
- Bumped all typography up one step in the type scale
- Reduced card height by 20% (158→126px, dropped 4:3 ratio)
- Moved port pill under title; session summary to bottom
- Added elegant `.contentTransition(.interpolate)` when summary changes
- Removed transition on active session outline (now instant)

### Visual Polish Sprint 🎨
*Cohesive refinement pass for organic, flowing interface.*

- State change visual effects now fade in/out gracefully (0.4s easeInOut transitions for Ready border glow)
- Section headers ("IN PROGRESS", "PAUSED") use small caps treatment (10pt semibold, 1.2 tracking, uppercase)
- Paused section spacing fixed (wrapped in VStack with 0 spacing, dividers provide equidistant separation)
- Project card summary text more subtle (12pt regular, 60% opacity vs previous full white)
- Project card titles use monospace font (14pt medium monospaced)
- Ready sound refined to "wooden knock" character:
  - Warmer fundamental (680Hz vs 880Hz), inharmonic overtones (2.3x, 4.1x)
  - Fast percussive attack (3ms), exponential decay
  - Subtle noise burst for organic texture
  - Slight vibrato wobble for natural resonance

### Header UX Improvements
- Replaced remote sync button with "Add Project" button in header
- New button uses NSOpenPanel for native macOS folder picker
- Projects can now be added anytime (not just from empty state)
- Removed RelayStatusIndicator and associated relay UI from header
- Remote sync features deprioritized; code remains in codebase for future use

### State Resolver Matching Logic Refinement (8 Iterations)
**ADR:** `docs/architecture-decisions/002-state-resolver-matching-logic.md`

Comprehensive fixes to session state detection through iterative ChatGPT review:

**Core Changes:**
- Three-way matching: Exact > Child > Parent (removed sibling due to cross-project contamination risk)
- Root path matches any descendant (not just immediate children): `/` ↔ `/a/b/c` works
- Timestamp-based lock selection: when multiple locks share PID, picks newest by `started`
- PID-only fallback includes exact matches (not just children)
- Deterministic tie-breaker: freshness → match type → session_id

**Issues Fixed:**
1. Root special-case only matched immediate children (broke `/` ↔ `/foo/bar`)
2. PID-only lock matching nondeterministic (returned first match, not newest)
3. Sibling matching depth guard insufficient (still allowed cross-project contamination)
4. Exact locks excluded from PID-only search (could pair wrong lock)
5. Test helper used same timestamp (timestamp selection not validated)
6. Docstrings mentioned removed sibling matching

**Testing:**
- 94 tests passing (removed 3 sibling tests, added 2 root nesting tests)
- Test coverage for root ↔ nested paths, multi-lock scenarios, timestamp selection
- `create_lock_with_timestamp()` helper for deterministic tests

**Trade-offs:**
- ✅ No cross-project contamination (safe)
- ✅ Deterministic behavior (reliable)
- ✅ Root nesting works (arbitrary depth)
- ❌ cd ../sibling won't match (must cd back to parent) - acceptable for safety

**Files Modified:**
- `core/hud-core/src/state/resolver.rs` - Matching logic, root special-cases
- `core/hud-core/src/state/lock.rs` - Timestamp selection, exact+child scanning
- Test helpers and comprehensive test coverage

### Projects View Polish Pass
- Session summary text changed to normal weight (was semibold)
- Section counts hidden when only 1 item (show "In Progress" not "In Progress (1)")
- Paused items polish: fixed height (no vertical growth on hover), balanced spacing, Revive button hover state
- Health badge moved from project cards to Project Details view (next to project title)
- Card→Paused transitions: auto-expand Paused section when project added; distinct view IDs ensure proper style switching
- Paused→Card transitions: distinct IDs ("active-{path}" vs "paused-{path}") for clean view replacement

### Projects View Simplification
- Consolidated three sections (Needs Input, In Progress, Paused) into two (In Progress, Paused)
- Removed summary bar from top of main view
- Left-aligned section headers with inline counts (e.g., "In Progress (3)")
- Made project titles more prominent (14pt semibold, 0.9 opacity)
- Removed animated dots from status indicator; just show text
- Removed comma from port numbers (show "3000" not "3,000")
- Added separators between project names in Paused section
- Removed time display from Paused rows; added "Revive" button on hover
- Re-implemented drag-and-drop sorting with persistent order
- Style transitions: card → row when moving to Paused, row → card when moving to In Progress

### Artifacts Browser: Skills, Commands, Agents
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

### CLAUDE.md Health Score + Coaching
- Health scoring algorithm analyzes CLAUDE.md content for: project description, workflow/commands, architecture info, style rules, sufficient detail
- Grades: A (90+), B (75-89), C (60-74), D (40-59), F (<40), None (no CLAUDE.md)
- Color-coded circular badge on project cards (green=A, yellow=C, red=F)
- Click badge for detailed popover showing pass/fail status for each criterion
- Copy-to-clipboard templates for missing sections (one-click improvement)

### Plans Integration
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

### Todos Integration
- TodosManager parses `~/.claude/todos/*.json` files
- TodosSection in Project Detail shows todos with completion status
- Groups: In Progress, Pending, Completed
- Interactive todo management:
  - Click checkbox to toggle completed/pending status
  - Menu to set todo as "in_progress" or "completed"
  - Add new todos via + button and inline text field
  - Changes write back to original todo JSON files

### Usage Insights
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

### Plugin Recommendations
- ProjectTypeDetector scans project files (package.json, Cargo.toml, requirements.txt, etc.)
- Detects tech stack: React, Next.js, TypeScript, Tailwind, Rust, Python, Go, Ruby, Docker
- PluginRecommender suggests relevant plugins based on detected tech
- PluginRecommendationSection in Project Detail shows contextual recommendations

### Hooks Setup Wizard
- HooksManager detects current hooks configuration from ~/.claude/settings.json
- HooksSetupSection shows status (None/Basic/Complete/Custom) with visual indicator
- Shows which hooks are configured (UserPromptSubmit, PostToolUse, Stop, Notification)
- One-click copy-to-clipboard for recommended hooks configuration
- Setup sheet with full configuration preview
- Diff preview showing current vs recommended hooks (added/removed highlighting)

### Projects View IA Redesign
- Urgency-based grouping: "Needs Input" (Ready) → "In Progress" (Working/Waiting/Compacting) → "Paused" (everything else)
- Summary bar shows counts: "3 need input • 2 working • 15 paused"
- Stale indicator for Ready state >24h (subtle "stale" pill badge)
- Paused section collapsed by default with expand/collapse toggle
- Renamed "Dormant" to "Paused" throughout
- Typography: "working on" text now primary (13pt semibold), project name secondary (11pt regular 55% opacity)
- Removed drag-and-drop reordering (projects now auto-sorted by urgency)

### Dark UI Polish Pass
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

### Core Features (Earlier)
- Focused project detection: highlights the project card matching the currently focused terminal window
  - Backend polls frontmost app via AppleScript
  - Detects Warp, Terminal.app, iTerm2 working directories
  - Matches against pinned projects
  - Shows lighter background on focused card
- UI polish pass: improved scannability and reduced visual noise
  - Working state: Claude-colored border (no animation), card not dimmed
  - Ready state: green pulsing glow border
  - "Your turn" label changed to "Ready"
  - Orange accent color replaced with neutral gray throughout
  - Project name font size increased from 13px to lg (18px)
  - Context usage indicator removed (not helpful)
- Visual state indicators: animated borders (working=amber glow, ready=blue pulse, compacting=shimmer), color-coded state labels, context % display
- Typography improvements: proper hierarchy (name 15px → working on 13px → next step 12px → stats 10px), color-coded states, tighter spacing
- Context tracking: hooks write state to centralized file, status line provides context %, real-time file watching
- Remove the Global tab and view entirely
- Remove the Refresh button
- Move Plugins into the Artifacts page as another tab
- Fix project list badges readability in dark mode (now uses low alpha backgrounds, prominence matches state)
- Add loading state when adding a new project (shows feedback during stats computation)
- Terminal detection for play button: now detects existing terminals in project directory and focuses them instead of opening new ones (uses sysinfo crate for process detection, AppleScript for window focus)

### Swift App Feature Parity
- Interactive cards, terminal launch, navigation, blocker display, breathing animations
- Recent/Dormant sections, flash on state change, compact cards, relative time
- Staggered animations, left accent bar, search filter
- Smooth navigation transitions with spring animations (response: 0.35, damping: 0.86)
  - Custom push/pop slide transitions based on navigation direction
  - Polished back button with hover state and Cmd+[ keyboard shortcut
- Removed project path text from cards (cleaner visual hierarchy)
- Manual dormant control via context menu
  - Right-click Recent card → "Move to Dormant"
  - Right-click Dormant card → "Move to Recent" (only shown for manually bumped projects)
  - Persists in UserDefaults, animated transitions between sections
- Window resizing with intelligent content adaptation
  - Min: 280×400, Ideal: 360×700, Max: 500×∞
  - Uses .windowResizability(.contentSize)
- Drag-and-drop project sorting in Recent section
  - Custom order persists to UserDefaults
  - Spring animations during reordering
- Fancy native color effects for status pills
  - Gradient fills with top-to-bottom opacity variation
  - Subtle borders and drop shadows on active states
- Press feedback on project cards
  - PressableButtonStyle with 0.98 scale effect
  - Spring animation for tactile feel
- Transparent chrome mode (⌘⇧T)
  - NSVisualEffectView with .hudWindow material
  - Cards float on blurred desktop background
  - Persists via @AppStorage
- Dev environment automation
  - Auto-detects dev servers via HTTP probing (works remotely, no local process access needed)
  - Parses package.json to infer expected port from dev scripts (vite, next, angular, --port flags)
  - Shows `:port` button on project cards when dev server is running
  - "Open in Browser" context menu option focuses existing browser tab
  - Project detail view with Quick Actions section
  - "Launch Full Environment" button opens terminal + browser together
  - Uses AppleScript to find and focus existing browser tabs (Arc, Chrome, Safari)
