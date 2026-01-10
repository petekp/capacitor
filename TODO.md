# TODO

## Goals
- Eliminate cognitive overhead of context-switching between projects
- Surface project context automatically (no manual tracking)
- Enable instant resume: see status at a glance → pick project → jump in with full context in seconds
- Optimize users' Claude Code experience by closing the gap between novice and expert setups

## High Priority

(none currently)

## Medium Priority

### Platform Features
- [ ] Explore: surface Claude's plan files (make visible and editable from HUD)
- [ ] Brainstorm: first-class todos feature — allow users to see and edit todos per project
- [ ] Brainstorm: potential uses for Claude Agent SDK — start by digesting official docs and popular tutorials

## Research / Exploration

### Strategic (Larger Explorations)
- [ ] Exploratory session: rethink the IA of the main Projects view to best achieve the goal of managing many Claude Code projects in parallel. Leverage all relevant skills (design, UX, interaction design, etc.). Nothing off limits — platform choice is open too, though desktop presence likely needed
- [ ] Design "Claude Code Coach" capability: optimize users' Claude Code experience by detecting suboptimal setups and guiding improvements. Key areas: CLAUDE.md quality (goals, architecture, commands), plugin recommendations, hooks setup, usage pattern insights. Surface via health scores on project cards, onboarding wizard for new projects, and inline suggestions. Position HUD as an active enhancer, not just a viewer.

## Completed

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
