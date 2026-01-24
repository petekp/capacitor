# Shell Integration: Ambient Development Awareness

**Status:** DONE
**Companion Doc:** [Shell Integration Engineering](./ACTIVE-shell-integration-engineering.md)
**Created:** 2025-01-23
**Last Updated:** 2025-01-24

---

## Executive Summary

Shell integration transforms Capacitor from a **reactive session monitor** into an **ambient development companion**. By letting the shell push CWD changes as they happen, Capacitor always knows where you're working—not just when Claude is running.

**Core insight:** Every `cd` command is a signal of intent. The shell knows exactly when and where you navigate. We just need to listen.

---

## Problem Statement

### Current State

Capacitor only knows about your work when:
1. Claude Code is actively running (via hooks)
2. You're using tmux (via tmux queries)

This creates blind spots:
- Working in VSCode/Cursor integrated terminals
- Exploring codebases before starting Claude
- Quick fixes that don't need AI
- Any terminal without tmux

### The Gap

```
What Capacitor sees:         What's actually happening:

Claude session in            User cd's to project-a
project-a                    Explores code for 10 mins
                             cd's to project-b
                             Quick bug fix (no Claude)
Claude session ends          cd's back to project-a
                             Starts Claude

[Nothing between sessions]   [Rich workflow context]
```

### Impact

- **Wrong project highlighted:** User is in project-b, Capacitor shows project-a
- **No workflow intelligence:** Can't learn patterns or predict needs
- **Missed opportunities:** User struggles alone when Claude could help
- **Incomplete picture:** Time tracking and recent projects are wrong

---

## Vision

> Capacitor becomes an always-aware companion that knows where you're working, regardless of whether Claude is running.

### Before & After

**Before (tmux-dependent):**
```
Terminal app frontmost?
    ↓ yes
tmux running?
    ↓ yes
Query tmux sessions
    ↓
Fuzzy-match session name to project
    ↓
Maybe highlight the right project
```

**After (shell-push):**
```
Shell precmd hook fires
    ↓
hud-hook writes CWD to state file
    ↓
Capacitor reads state file
    ↓
Correct project highlighted
```

Simple. Accurate. Universal.

---

## User Impact

### Primary Persona: Context-Switching Developer

**Profile:** Works on 3-5 projects. Switches frequently. Uses any terminal.

**Pain points solved:**
- ✅ Project highlighting works in VSCode/Cursor terminals
- ✅ Works without tmux installed
- ✅ Accurate recent projects list
- ✅ Returning to project shows correct context

### Secondary Persona: AI-Augmented Developer

**Profile:** Heavy Claude user. Wants proactive assistance.

**Pain points solved:**
- ✅ Claude sessions inherit prior exploration context
- ✅ AI can reference "I see you were in src/auth earlier"
- ✅ Workflow patterns enable smarter suggestions

---

## Features

### Tier 1: Core Shell Integration (v1.0)

#### 1.1 Always-Accurate Project Highlighting

The right project card highlights when you `cd` to it—in any terminal.

```
User cd's to ~/Code/my-project
    ↓
HUD immediately highlights "my-project"
```

**Works in:** iTerm, Terminal, Ghostty, Alacritty, kitty, Warp, VSCode, Cursor

#### 1.2 True Recent Projects

"Recent" reflects where you've actually been, not just Claude sessions.

```
Before: Recent = projects with Claude sessions
After:  Recent = projects you've visited in shell
```

#### 1.3 Parent App Awareness

Capacitor knows which app hosts your terminal:

```
Shell in Cursor → parentApp = "cursor"
Shell in iTerm  → parentApp = "iterm2"
```

Enables future features like "show Cursor projects" or IDE-specific integrations.

---

### Tier 2: Contextual Intelligence (v1.1)

#### 2.1 Session Context Inheritance

When starting Claude, provide context about recent exploration:

```
User explores ~/Code/my-project/src/auth/ for 5 minutes
User starts Claude
    ↓
Claude receives: "User recently visited src/auth/, login.ts, oauth.ts"
    ↓
Claude: "I see you've been exploring the auth module. How can I help?"
```

#### 2.2 Project Return Briefings

When returning to a project after time away:

```
User cd's to my-project (last visited 3 days ago)
    ↓
Card shows:
┌─────────────────────────────────────────────────┐
│  my-project                                     │
│  Last: 3 days ago                               │
│  "Fixed OAuth token refresh bug"                │
│  Modified: oauth.ts, auth.test.ts               │
└─────────────────────────────────────────────────┘
```

#### 2.3 Time Intelligence

Track and surface time allocation:

```
This week:
  my-project    ████████████████  8.5 hrs
  client-work   ████████          4.2 hrs
  side-project  ████              2.1 hrs
```

---

### Tier 3: Proactive AI (v2.0)

These features represent the strategic vision—where ambient awareness enables genuinely proactive AI.

#### 3.1 Contextual Nudges

Gentle suggestions based on observed behavior:

```
User in ~/Code/my-project for 15 minutes, no Claude started
    ↓
"Exploring my-project? [Start Claude to help]"
```

```
User returns to directory where Claude session ended with error
    ↓
"Last time here, you hit an OAuth issue. Pick up where you left off?"
```

#### 3.2 Predictive Session Preparation

Pre-load context when user enters a project:

```
User cd's to my-project
    ↓
Background: Check git status, recent commits, open PRs
    ↓
User starts Claude
    ↓
Claude immediately knows: "CI is failing, 2 PRs need review"
```

---

## Technical Approach

### Architecture: Push, Not Pull

**Old (pull):** Poll tmux every 500ms, walk process trees, fuzzy-match.

**New (push):** Shell hook fires on every prompt, writes CWD to file.

```
Shell → hud-hook cwd → ~/.capacitor/shell-cwd.json → Capacitor reads
```

Benefits:
- **Simpler:** No subprocess spawning, no process walking
- **Faster:** File read vs. multiple `ps` calls
- **Accurate:** Exact CWD, no guessing
- **Universal:** Works in any terminal

### What Gets Removed

| Component | Reason |
|-----------|--------|
| `TerminalTracker.swift` | Replaced by shell push |
| tmux session queries | Shell CWD is authoritative |
| Process tree walking | Parent app detected by hook |
| Fuzzy session matching | No longer needed |

### Shell Snippets

Users add a small snippet to their shell config:

**zsh (~/.zshrc):**
```bash
if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
  _capacitor_precmd() {
    "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$TTY" 2>/dev/null &!
  }
  precmd_functions+=(_capacitor_precmd)
fi
```

The hook runs in the background (`&!`), so users never wait.

---

## User Setup

### Onboarding Flow

```
1. User installs Capacitor
    ↓
2. Setup card appears:
   ┌─────────────────────────────────────────────────┐
   │  🔧 Shell Integration                           │
   │                                                 │
   │  Track your active project across all          │
   │  terminals—not just when Claude is running.    │
   │                                                 │
   │  [Set Up Now]                                  │
   └─────────────────────────────────────────────────┘
    ↓
3. Instructions sheet:
   ┌─────────────────────────────────────────────────┐
   │  Add to ~/.zshrc:                               │
   │                                                 │
   │  ┌─────────────────────────────────────────────┐│
   │  │ # Capacitor shell integration               ││
   │  │ if [[ -x "$HOME/.local/bin/hud-hook" ]]...  ││
   │  └─────────────────────────────────────────────┘│
   │                                                 │
   │  [Copy to Clipboard]                            │
   │                                                 │
   │  Then restart your terminal.                    │
   └─────────────────────────────────────────────────┘
    ↓
4. Verification:
   ┌─────────────────────────────────────────────────┐
   │  ✓ Shell integration active                     │
   │                                                 │
   │  cd to any project to see it highlight.         │
   └─────────────────────────────────────────────────┘
```

### Privacy & Control

- **Opt-in:** User must add snippet (we don't modify shell config)
- **Local-only:** CWD data stays on machine, never transmitted
- **Transparent:** User can inspect `~/.capacitor/shell-cwd.json`
- **Deletable:** Clear history anytime

---

## Success Metrics

### Adoption

| Metric | Target |
|--------|--------|
| Shell integration enabled | 70% of active users |
| Terminal coverage | 90% of terminal sessions tracked |
| IDE terminal usage | 40% include Cursor/VSCode |

### Accuracy

| Metric | Target |
|--------|--------|
| Project highlighting accuracy | 99% |
| False positives (wrong project) | < 1% |

### Engagement

| Metric | Target |
|--------|--------|
| Time to first highlight after cd | < 1 second |
| User corrections needed | < 5% of sessions |

---

## Risks & Mitigations

### Risk: Users Don't Set Up Shell Integration

**Mitigation:**
- Prominent setup card on first launch
- Clear, copy-paste instructions
- "Fix All" button that explains what to do
- Graceful degradation (Claude sessions still work)

### Risk: Performance Impact on Shell

**Mitigation:**
- Hook runs in background (`&!` / `&`)
- Binary is fast Rust (< 15ms total)
- Minimal work in hot path

### Risk: State File Corruption

**Mitigation:**
- Atomic writes (temp file + rename)
- Version field for schema evolution
- Defensive parsing on read

---

## Rollout

### Phase 1: Foundation (v1.0)
- `hud-hook cwd` subcommand
- `ShellStateStore` reading state
- `ActiveProjectResolver` combining signals
- Project highlighting from shell CWD
- Setup card and instructions

### Phase 2: Intelligence (v1.1)
- Shell history tracking
- Recent projects from history
- Session context inheritance
- Time tracking basics

### Phase 3: Proactive (v2.0)
- Contextual nudges
- Predictive session prep
- Cross-session learning

---

## Open Questions

1. **History retention:** 30 days default? User-configurable?

2. **Context injection:** How to pass shell context to Claude sessions? `--context` flag? Context file?

3. **Multi-machine:** If user works on multiple machines, should history sync? (Probably no—privacy concerns)

4. **Nudge UX:** What's the right UI for proactive suggestions? Inline in cards? Notification area?

---

## Appendix: Competitive Landscape

| Product | Shell Awareness | AI Proactive | Dev Focus |
|---------|-----------------|--------------|-----------|
| Capacitor (with shell) | ✅ | ✅ (planned) | ✅ |
| Warp | ✅ (built-in) | Partial | ✅ |
| Fig (deprecated) | ✅ | ❌ | ✅ |
| GitHub Copilot | ❌ (editor) | ❌ | ✅ |
| Raycast | Partial | ❌ | ❌ |

**Opportunity:** No tool combines ambient shell awareness with proactive AI assistance. Capacitor owns this space.
