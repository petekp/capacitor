# Shell Integration: Ambient Development Awareness

**Status:** DRAFT
**Author:** Claude
**Created:** 2025-01-23
**Last Updated:** 2025-01-23

---

## Executive Summary

Shell integration transforms Claude HUD from a **reactive session monitor** into an **ambient development companion**. By knowing where the user is working at all times—not just when Claude is running—HUD gains the foundation for proactive, AI-powered assistance that anticipates developer needs.

**The core insight:** Every `cd` command is a signal of intent. Aggregated over time, these signals reveal workflow patterns that enable predictive, context-aware features impossible with session-only data.

---

## Problem Statement

### Current State

Claude HUD only knows about the user's work when:
1. Claude Code is actively running (via hooks)
2. User is in tmux (via tmux queries)

This creates blind spots:
- User switches to a project but hasn't started Claude yet
- User works in VSCode/Cursor integrated terminals
- User explores codebases without AI assistance
- User's actual time allocation across projects is invisible

### The Gap

```
What HUD knows:        │  What's actually happening:
                       │
Claude session in      │  User cd's to project-a
project-a              │  Explores code for 10 minutes
                       │  cd's to project-b
                       │  Fixes quick bug (no Claude needed)
Claude session ends    │  cd's back to project-a
                       │  Starts Claude
                       │
[HUD sees nothing      │  [Rich context about user's
 between sessions]     │   workflow and intent]
```

### Impact of the Gap

- **Missed assistance opportunities:** User struggles alone when Claude could help
- **No workflow intelligence:** Can't learn user patterns to predict needs
- **Context discontinuity:** Each Claude session starts cold, no awareness of prior exploration
- **Incomplete picture:** Time tracking, project prioritization, and recent projects are inaccurate

---

## Vision

> Claude HUD becomes an always-aware companion that understands your development workflow, anticipates your needs, and offers assistance at the right moment—not just when you explicitly ask.

### The Ambient Awareness Model

```
┌─────────────────────────────────────────────────────────────────┐
│                     AMBIENT AWARENESS LAYER                     │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐       │
│  │ Shell CWD     │  │ Claude Hooks  │  │ File Activity │       │
│  │ (new)         │  │ (existing)    │  │ (existing)    │       │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘       │
│          │                  │                  │                │
│          └──────────────────┼──────────────────┘                │
│                             ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              UNIFIED CONTEXT ENGINE                      │   │
│  │  • Where is the user?                                    │   │
│  │  • What are they doing?                                  │   │
│  │  • What have they done recently?                         │   │
│  │  • What might they need next?                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                             │                                   │
│                             ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              PROACTIVE INTELLIGENCE                      │   │
│  │  • Contextual suggestions                                │   │
│  │  • Workflow automation                                   │   │
│  │  • Predictive assistance                                 │   │
│  │  • Pattern-based insights                                │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## User Impact

### Primary Persona: The Context-Switching Developer

**Profile:** Works on 3-5 projects regularly. Frequently switches between them. Uses terminal (standalone or IDE-integrated). Values flow state and minimal friction.

**Current pain points:**
- Loses context when switching projects
- Forgets what they were doing in a project days ago
- Starts Claude sessions without HUD knowing the backstory
- No visibility into their own time allocation

**With shell integration:**
- HUD always shows the right project highlighted
- Returning to a project surfaces recent context
- AI suggestions are informed by exploration that happened before Claude started
- Accurate picture of time spent across projects

### Secondary Persona: The AI-Augmented Developer

**Profile:** Heavy Claude user. Wants AI assistance to be proactive, not just reactive. Willing to grant permissions for smarter features.

**Current pain points:**
- Must explicitly start Claude and describe context
- AI doesn't know about exploration done without it
- No "ambient" AI awareness of their work
- Repetitive context-setting across sessions

**With shell integration:**
- Claude sessions inherit context from prior exploration
- Proactive suggestions based on where they've been
- AI can reference "I noticed you were looking at X earlier"
- Reduced friction to getting useful assistance

---

## Capabilities Unlocked

### Tier 1: Immediate Value (Ships with v1)

#### 1.1 Always-Accurate Project Highlighting

**What:** Project cards highlight based on actual terminal activity, not just Claude sessions.

**User experience:**
```
User cd's to ~/Code/my-project
       ↓
HUD immediately highlights "my-project" card
       ↓
User feels: "It knows where I am"
```

**Impact:** Trust-building. Users see HUD as aware and responsive.

#### 1.2 True Recent Projects

**What:** "Recent" reflects actual terminal visits, not just Claude sessions.

**User experience:**
```
Before: Recent shows projects with Claude sessions (incomplete)
After:  Recent shows projects user actually visited (accurate)
```

**Impact:** HUD becomes a reliable project switcher, not just a Claude monitor.

#### 1.3 Universal Terminal Support

**What:** Works in any terminal—standalone apps, VSCode, Cursor, JetBrains, etc.

**User experience:**
```
User in VSCode integrated terminal: HUD works
User in iTerm2: HUD works
User in Warp: HUD works
User SSH'd to remote (local shell): HUD works
```

**Impact:** No more "HUD only works with tmux" limitation. Broader adoption.

---

### Tier 2: Contextual Intelligence (v1.1)

#### 2.1 Session Context Inheritance

**What:** When starting a Claude session, provide context about recent exploration.

**User experience:**
```
User explores ~/Code/my-project/src/auth/ for 5 minutes
User starts Claude
       ↓
Claude receives context:
"User has been in this project for 5 minutes,
 recently visited: src/auth/, src/auth/login.ts, src/auth/oauth.ts"
       ↓
Claude's first response is more contextual:
"I see you've been exploring the auth module. What would you like to work on?"
```

**Technical approach:**
- Track CWD history with timestamps
- When Claude session starts, inject recent CWD history as context
- Could use Claude Code's `--context` flag or a context file

**Impact:** Eliminates cold-start problem. Claude "knows" what you were doing.

#### 2.2 Project Return Briefings

**What:** When returning to a project after time away, surface relevant context.

**User experience:**
```
User cd's to ~/Code/my-project (last visited 3 days ago)
       ↓
HUD shows card with context:
┌─────────────────────────────────────────────────────────────┐
│  my-project                                                 │
│  Last visited: 3 days ago                                   │
│                                                             │
│  Last session:                                              │
│  • "Fixed authentication bug in OAuth flow"                 │
│  • Modified: src/auth/oauth.ts, tests/auth.test.ts         │
│                                                             │
│  [Resume context] [Start fresh]                            │
└─────────────────────────────────────────────────────────────┘
```

**Impact:** Reduces cognitive load of context-switching. Users feel continuity.

#### 2.3 Time Intelligence

**What:** Track and surface time allocation across projects.

**User experience:**
```
Weekly summary (in HUD or notification):

This week you spent:
  my-project       ████████████████  8.5 hrs
  client-work      ████████          4.2 hrs
  side-project     ████              2.1 hrs

You started 12 Claude sessions across 4 projects.
Most productive day: Wednesday (4.5 hrs deep work)
```

**Impact:** Self-awareness. Users understand their actual work patterns.

---

### Tier 3: Proactive AI Assistance (v2.0)

These features represent the strategic vision—where ambient awareness enables genuinely proactive AI.

#### 3.1 Contextual Nudges

**What:** Gentle suggestions based on observed behavior.

**Scenarios:**

```
Scenario A: Extended exploration without Claude

User has been in ~/Code/my-project for 15 minutes
No Claude session started
User has cd'd to 5+ different directories (exploring)
       ↓
HUD surfaces subtle nudge:
"Exploring my-project? [Start Claude to help]"
```

```
Scenario B: Return to stuck point

User was in ~/Code/my-project/src/auth/ 2 days ago
Claude session ended with unresolved error
User returns to same directory
       ↓
HUD surfaces:
"Last time here, you hit an OAuth token refresh issue.
 Want to pick up where you left off?"
```

```
Scenario C: Pattern-based suggestion

User typically starts dev server when entering my-project
User cd's to my-project
       ↓
HUD offers:
"Start dev server? (You usually do this)"
```

**Design principle:** Nudges are dismissible and learn from dismissals. Never annoying.

#### 3.2 Ambient Summarization

**What:** AI-generated summaries of work periods, available on demand or scheduled.

**User experience:**
```
End of day, HUD offers:
"Summarize today's work?"
       ↓
User clicks yes
       ↓
AI generates:
"Today you worked on 3 projects:

my-project (4.2 hrs):
- Fixed OAuth token refresh bug
- Added unit tests for auth flow
- Explored caching options (didn't implement)

client-work (2.1 hrs):
- Reviewed PR #234
- Responded to feedback on API design

side-project (0.5 hrs):
- Quick dependency update
- Ran tests (all passing)

Unfinished: You were investigating Redis caching in my-project
            but didn't complete it. Continue tomorrow?"
```

**Impact:** Effortless documentation. Helps with standup reports, time tracking, personal reflection.

#### 3.3 Predictive Session Preparation

**What:** Pre-load context before user asks.

**Technical approach:**
- Observe user cd's to a project
- In background, prepare relevant context (recent changes, open PRs, failing tests)
- When user starts Claude, context is ready instantly

**User experience:**
```
User cd's to my-project
       ↓
(Background: HUD checks git status, recent commits, open PRs)
       ↓
User starts Claude
       ↓
Claude immediately knows:
- There are 2 open PRs awaiting review
- Last commit was "WIP: caching implementation"
- CI is failing on the main branch
       ↓
"I see you have some work in progress on caching, and CI is failing.
 Want to fix the CI issue first, or continue the caching work?"
```

**Impact:** Claude feels omniscient. Reduces "let me check git status" back-and-forth.

#### 3.4 Cross-Session Learning

**What:** AI learns user's patterns and preferences over time.

**Examples:**
- "User always wants tests when implementing new functions"
- "User prefers functional style over class-based"
- "User usually works on auth first, then UI"
- "User's projects follow monorepo structure with apps/ and packages/"

**User experience:**
```
After several sessions in my-project:
       ↓
Claude starts suggesting patterns:
"Based on your style in this project, I'll write functional components
 with hooks rather than class components. I'll also add tests alongside
 the implementation since that's your pattern here."
```

**Privacy consideration:** Learning is local, per-project, user-controlled, and transparent.

#### 3.5 Intelligent Interruption Prevention

**What:** Know when NOT to disturb the user.

**Signals of flow state:**
- Rapid file changes (from file activity)
- Staying in same directory subtree
- Not context-switching
- Claude session active with frequent tool use

**User experience:**
```
User is in flow state (rapid coding detected)
       ↓
HUD suppresses non-critical notifications
Background processes don't steal focus
       ↓
After 30 minutes, flow state ends (user takes break)
       ↓
HUD surfaces accumulated items:
"While you were focused:
 - PR #234 was approved
 - CI passed on main
 - New issue assigned to you"
```

**Impact:** Respects focus. HUD becomes a guardian of flow state.

---

## Technical Architecture

### Data Model

```
~/.capacitor/
├── sessions.json          # Claude session state (existing)
├── shell-cwd.json         # Shell CWD reports (new)
├── shell-history.json     # CWD history for analysis (new)
├── workflow-patterns.json # Learned patterns (future)
└── file-activity.json     # File changes (existing)
```

### Shell CWD State (New)

```json
{
  "version": 1,
  "shells": {
    "54321": {
      "cwd": "/Users/you/Code/my-project",
      "tty": "/dev/ttys003",
      "parent_app": "cursor",
      "updated_at": "2024-01-15T10:30:00Z"
    }
  }
}
```

### CWD History (New)

```json
{
  "version": 1,
  "entries": [
    {
      "cwd": "/Users/you/Code/my-project",
      "entered_at": "2024-01-15T10:30:00Z",
      "exited_at": "2024-01-15T10:45:00Z",
      "duration_secs": 900,
      "shell_pid": 54321,
      "parent_app": "cursor"
    }
  ],
  "retention_days": 30
}
```

### Component Responsibilities

```
┌─────────────────────────────────────────────────────────────────┐
│  hud-hook (Rust binary)                                         │
│  ├── handle    → Claude hook events (existing)                  │
│  └── cwd       → Shell CWD reports (new)                        │
│      ├── Update shell-cwd.json (current state)                  │
│      ├── Append to shell-history.json (historical)              │
│      └── Detect parent app (process tree walk)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  HUD App (Swift)                                                │
│  ├── ShellStateStore     → Read shell-cwd.json                  │
│  ├── HistoryAnalyzer     → Analyze shell-history.json           │
│  ├── ContextEngine       → Combine all signals                  │
│  └── ProactiveFeatures   → Surface suggestions                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## User Setup & Onboarding

### Installation Flow

```
1. User installs HUD (existing flow)
       ↓
2. Setup card shows:
   ┌─────────────────────────────────────────────────────────────┐
   │  Enhanced Project Tracking                                   │
   │                                                              │
   │  Enable shell integration to track your active project       │
   │  across all terminals—not just when Claude is running.       │
   │                                                              │
   │  [Show me how] [Not now] [Don't ask again]                  │
   └─────────────────────────────────────────────────────────────┘
       ↓
3. If "Show me how":
   ┌─────────────────────────────────────────────────────────────┐
   │  Add this to your ~/.zshrc:                                 │
   │                                                              │
   │  ┌────────────────────────────────────────────────────────┐ │
   │  │ # Claude HUD shell integration                         │ │
   │  │ if [[ -x "$HOME/.local/bin/hud-hook" ]]; then         │ │
   │  │   _hud_precmd() {                                      │ │
   │  │     "$HOME/.local/bin/hud-hook" cwd "$PWD" ...        │ │
   │  │   }                                                    │ │
   │  │   precmd_functions+=(_hud_precmd)                      │ │
   │  │ fi                                                     │ │
   │  └────────────────────────────────────────────────────────┘ │
   │                                                              │
   │  [Copy to clipboard] [Add automatically] [View bash/fish]   │
   └─────────────────────────────────────────────────────────────┘
       ↓
4. After setup, verification:
   ┌─────────────────────────────────────────────────────────────┐
   │  ✓ Shell integration active                                 │
   │                                                              │
   │  Open a new terminal and cd to a project.                   │
   │  You should see it highlight in HUD.                        │
   └─────────────────────────────────────────────────────────────┘
```

### Opt-In Philosophy

- Shell integration is **opt-in** (user must add to shell config)
- Proactive features have individual toggles
- History retention is configurable (default: 30 days)
- User can clear history at any time
- No data leaves the machine

---

## Success Metrics

### Adoption Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Shell integration adoption | 60% of active users | Users with shell-cwd.json activity |
| Terminal coverage | 80% of terminal sessions tracked | Shell reports vs Claude sessions |
| Cross-tool usage | 30% using in IDE terminals | parent_app field distribution |

### Engagement Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Project highlighting accuracy | 95% | User corrections / auto-highlights |
| Contextual nudge acceptance | 40% | Nudges acted on / nudges shown |
| Session context usage | 50% | Sessions using inherited context |

### Outcome Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Time to productive Claude session | -30% | Time from cd to first useful Claude response |
| Context-switch recovery time | -50% | Time to resume work after project switch |
| User-reported workflow improvement | +NPS | Survey: "HUD helps me work more effectively" |

---

## Risks & Mitigations

### Risk: Privacy Concerns

**Concern:** Users uncomfortable with CWD tracking.

**Mitigation:**
- Explicit opt-in (must add to shell config)
- Local-only storage (never transmitted)
- Clear data controls (view, export, delete history)
- Transparent about what's collected

### Risk: Performance Impact

**Concern:** Shell hook slows down prompt.

**Mitigation:**
- Background execution (`&!` / `&`)
- Binary is fast Rust, not script
- Minimal work in hot path (just file write)
- Benchmark: < 5ms added latency

### Risk: Notification Fatigue

**Concern:** Proactive features become annoying.

**Mitigation:**
- Conservative defaults (minimal nudges)
- Learn from dismissals
- User controls for each feature type
- "Focus mode" to suppress non-critical

### Risk: Complexity Creep

**Concern:** Feature scope expands beyond core value.

**Mitigation:**
- Tiered rollout (Tier 1 before Tier 2 before Tier 3)
- Each tier must prove value before next
- User research between tiers
- Kill features that don't perform

---

## Rollout Plan

### Phase 1: Foundation (v1.0)

**Scope:** Shell integration infrastructure + immediate value features

**Deliverables:**
- [ ] `hud-hook cwd` subcommand
- [ ] Shell snippets (zsh, bash, fish)
- [ ] ShellStateStore in Swift app
- [ ] Project highlighting from shell CWD
- [ ] Recent projects from shell history
- [ ] Setup card for shell integration
- [ ] Documentation

**Success gate:** 40% of active users enable shell integration within 2 weeks.

### Phase 2: Intelligence (v1.1)

**Scope:** Contextual features that use shell history

**Deliverables:**
- [ ] CWD history tracking and analysis
- [ ] Session context inheritance
- [ ] Project return briefings
- [ ] Time tracking dashboard
- [ ] Parent app detection (VSCode/Cursor awareness)

**Success gate:** Positive user feedback on context features; measurable reduction in context-switch time.

### Phase 3: Proactive AI (v2.0)

**Scope:** AI-powered proactive features

**Deliverables:**
- [ ] Contextual nudges system
- [ ] Ambient summarization
- [ ] Predictive session preparation
- [ ] Cross-session learning
- [ ] Flow state detection

**Success gate:** Users report HUD "anticipates their needs" in surveys.

---

## Open Questions

1. **History retention:** What's the right default retention period? 30 days? 90 days? Forever with user control?

2. **AI integration approach:** For proactive AI features, should we:
   - Call Claude API directly from HUD?
   - Invoke Claude Code CLI?
   - Use a local model for some features?

3. **Cross-device sync:** If user works on multiple machines, should shell history sync? Privacy implications?

4. **IDE extension priority:** When should we invest in VSCode/Cursor extension vs. shell integration covering most cases?

5. **Nudge UX:** What's the right UI pattern for proactive suggestions? Inline in project cards? Separate notification area? System notifications?

---

## Appendix: Competitive Landscape

| Product | Ambient Awareness | Proactive AI | Developer Focus |
|---------|-------------------|--------------|-----------------|
| Claude HUD (with shell integration) | ✅ | ✅ (planned) | ✅ |
| Fig | ✅ (shell integration) | ❌ | ✅ |
| Warp | ✅ (built-in) | Partial | ✅ |
| GitHub Copilot | ❌ (editor only) | ❌ | ✅ |
| Raycast | Partial (app focus) | ❌ | ❌ |
| Linear | ❌ | ❌ | Partial |

**Opportunity:** No tool combines ambient development awareness with proactive AI assistance. Claude HUD can own this space.

---

## Appendix: Shell Integration Snippets

### zsh (~/.zshrc)

```bash
# Claude HUD shell integration
if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
  _hud_precmd() {
    "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$TTY" 2>/dev/null &!
  }
  precmd_functions+=(_hud_precmd)
fi
```

### bash (~/.bashrc)

```bash
# Claude HUD shell integration
if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
  _hud_prompt_command() {
    "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$(tty)" 2>/dev/null &
  }
  PROMPT_COMMAND="_hud_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
```

### fish (~/.config/fish/config.fish)

```fish
# Claude HUD shell integration
if test -x "$HOME/.local/bin/hud-hook"
  function _hud_postexec --on-event fish_postexec
    "$HOME/.local/bin/hud-hook" cwd "$PWD" "$fish_pid" (tty) 2>/dev/null &
  end
end
```
