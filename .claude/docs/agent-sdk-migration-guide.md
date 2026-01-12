# Claude Agent SDK Migration Guide for HUD

> **Purpose:** Reference document for migrating Claude HUD features to use the Anthropic Agent SDK.
> **Created:** 2025-01-11
> **Status:** Research complete, ready for implementation planning

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [What is the Agent SDK?](#what-is-the-agent-sdk)
3. [SDK vs CLI Comparison](#sdk-vs-cli-comparison)
4. [CLI and SDK Coexistence](#cli-and-sdk-coexistence) ⭐ *Important context*
5. [Session Sharing: Critical Clarification](#session-sharing-critical-clarification) ⭐ *Important context*
6. [State Tracking Migration: Why Not to Do It](#state-tracking-migration-why-not-to-do-it) ⭐ *Critical constraint*
7. [Core SDK Features](#core-sdk-features)
8. [HUD Migration Opportunities](#hud-migration-opportunities)
9. [Implementation Patterns](#implementation-patterns)
10. [Architecture Recommendations](#architecture-recommendations)
11. [Migration Roadmap](#migration-roadmap)
12. [API Reference](#api-reference)
13. [Resources](#resources)

---

## Executive Summary

The Claude Agent SDK (formerly "Claude Code SDK") provides programmatic access to the same agentic capabilities that power the Claude Code CLI. For Claude HUD, this opens significant new possibilities:

| Current State | With SDK |
|---------------|----------|
| HUD observes via file artifacts | HUD can drive agents directly |
| Shell script hooks for state | Native function callbacks |
| Subprocess calls for summaries | Integrated SDK queries |
| Manual session resumption | Programmatic session management |

**Key insight:** The SDK solves HUD's "daemon dilemma"—getting structured state data without replacing the user's interactive TUI.

**Recommended first migration targets:**
1. Summary generation (replace subprocess with SDK)
2. Session ID capture and storage
3. "Resume Session" feature using `resume: sessionId`

---

## What is the Agent SDK?

The Agent SDK is Claude Code packaged as a library for Python and TypeScript. It provides:

- **Built-in tool execution** - Claude reads files, runs commands, edits code autonomously
- **Streaming message output** - Real-time structured JSON of all agent activity
- **Session management** - Create, resume, and fork conversation sessions
- **Lifecycle hooks** - Callbacks at key execution points (PreToolUse, Stop, etc.)
- **Subagent orchestration** - Spawn specialized agents for focused subtasks
- **Permission control** - Fine-grained control over what agents can do

### Installation

```bash
# TypeScript
npm install @anthropic-ai/claude-agent-sdk

# Python
pip install claude-agent-sdk
```

**Prerequisite:** Claude Code must be installed (the SDK uses it as runtime).

```bash
# Install Claude Code
brew install --cask claude-code
# or
npm install -g @anthropic-ai/claude-code
```

### Authentication

```bash
# Option 1: API key
export ANTHROPIC_API_KEY=your-api-key

# Option 2: If Claude Code is authenticated, SDK uses that automatically

# Option 3: Cloud providers
export CLAUDE_CODE_USE_BEDROCK=1  # Amazon Bedrock
export CLAUDE_CODE_USE_VERTEX=1   # Google Vertex AI
```

---

## SDK vs CLI Comparison

### Feature Matrix

| Feature | CLI | Agent SDK |
|---------|-----|-----------|
| Interactive terminal | ✅ Yes | ❌ No (programmatic only) |
| Structured output | Via `--output-format stream-json` (replaces TUI) | ✅ Always available |
| Tool execution | ✅ Yes | ✅ Yes (same tools) |
| Session resumption | `--resume` flag | `resume: sessionId` option |
| Hooks | Shell script callbacks | Native function callbacks |
| Permission modes | Interactive prompts | `permissionMode` option |
| Subagents | Via Task tool | Programmatic definition |
| MCP servers | Config file | Programmatic configuration |
| CLAUDE.md support | ✅ Yes | ✅ Yes (with `settingSources: ['project']`) |

### Key Architectural Difference

```
CLI Approach:
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│ User types  │ ──▶ │ Claude Code  │ ──▶ │ Pretty TUI  │
│ in terminal │     │ (interactive)│     │ output      │
└─────────────┘     └──────────────┘     └─────────────┘

SDK Approach:
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│ Your code   │ ──▶ │ Agent SDK    │ ──▶ │ JSON stream │
│ calls query │     │ (headless)   │     │ (structured)│
└─────────────┘     └──────────────┘     └─────────────┘
```

### Why This Matters for HUD

**Current HUD problem:** To get structured state from Claude, we'd need `--output-format stream-json`, but that replaces the TUI. Users lose their interactive experience.

**SDK solution:** Structured streaming is the default. If HUD drives the agent via SDK, we get full visibility without sacrificing anything. Users can still use the CLI for interactive work; HUD uses SDK for programmatic features.

---

## CLI and SDK Coexistence

### The Mental Model

**The CLI and SDK are complementary, not competing.** Users will continue using the CLI for interactive development; the SDK enables HUD to provide programmatic features.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        USER'S WORKFLOW                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌─────────────────────┐         ┌─────────────────────────────┐   │
│   │   Claude Code CLI   │         │        Claude HUD            │   │
│   │   (Interactive)     │         │   (Dashboard + Automation)   │   │
│   │                     │         │                              │   │
│   │  • User types in    │         │  • Observes all projects     │   │
│   │    terminal         │         │  • Shows status at a glance  │   │
│   │  • Pretty TUI       │         │  • Generates summaries       │   │
│   │  • Real-time        │    ▲    │  • Resumes sessions          │   │
│   │    interaction      │    │    │  • Runs quick actions        │   │
│   │                     │    │    │                              │   │
│   └──────────┬──────────┘    │    └──────────────┬───────────────┘   │
│              │               │                   │                   │
│              │ writes        │ reads             │ uses              │
│              ▼               │                   ▼                   │
│   ┌──────────────────────────┴───────────────────────────────────┐   │
│   │                    ~/.claude/                                 │   │
│   │  • Session files (JSONL transcripts)                         │   │
│   │  • State files (hud-session-states.json)                     │   │
│   │  • Hook outputs                                              │   │
│   └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Usage Scenarios

| Scenario | CLI Role | HUD/SDK Role |
|----------|----------|--------------|
| **Pure CLI User** | Primary development tool | Passive dashboard (observes via files) |
| **CLI + HUD Helper** | Primary development tool | Auxiliary features (summaries, quick actions) |
| **HUD-Driven Agent** | Not needed | Drives agent directly (no terminal required) |

### Typical Workflow

```
Morning routine with SDK-enabled HUD:

1. Open HUD → See all projects at a glance
2. Notice "project-x" is Ready (waiting for input from yesterday)
3. Option A: Click "Open in Terminal" → Use CLI normally
   Option B: Click "Resume Session" → HUD runs SDK, shows activity panel
4. Later: Click "Generate Summary" → SDK does it in background
```

### Key Insight

Think of it like this:
- **CLI** = User driving manually (interactive, hands-on)
- **SDK** = HUD acting as autopilot for specific tasks (programmatic, automated)

Users can switch between them freely. The CLI remains primary for interactive work; the SDK enables HUD to *do things*, not just *show things*.

---

## Session Sharing: Critical Clarification

### Sessions Are Sequential, Not Concurrent

**⚠️ Important:** The CLI and SDK **cannot interact with the same session simultaneously**. Sessions are shared in the sense that they use the same storage and can be resumed by either, but only one process can be active on a session at a time.

```
Timeline (Correct Usage):
─────────────────────────────────────────────────────────────────────►

  CLI Session Active                    CLI Stopped
  ┌──────────────────┐                 ┌─────────┐
  │ $ claude         │                 │ Session │
  │ > Help me with X │ ───────────────►│ saved   │
  │ [Claude works]   │                 │ (JSONL) │
  │ [User exits]     │                 └────┬────┘
  └──────────────────┘                      │
                                            │ Later...
                                            ▼
                                   ┌─────────────────┐
                                   │ HUD resumes via │
                                   │ SDK with same   │
                                   │ session ID      │
                                   └─────────────────┘
```

### What "Shared Sessions" Actually Means

| ✅ You CAN | ❌ You CANNOT |
|-----------|---------------|
| Start session in CLI → Stop → Resume in SDK (HUD) | Have CLI and SDK both active on same session |
| Start session in SDK (HUD) → Stop → Resume in CLI | Send messages to an active CLI session from HUD |
| Read session transcript while CLI is active (read-only) | Write to session while another process owns it |

### Why Not Concurrent?

A session is a **conversation transcript** stored as JSONL. When Claude resumes, it loads that transcript into context and continues. There's only one active process at a time.

```
Session File (~/.claude/projects/{path}/{session-id}.jsonl):
┌────────────────────────────────────────────────────────────┐
│ {"type": "user", "content": "Help me refactor auth"}       │
│ {"type": "assistant", "content": "I'll analyze..."}        │
│ {"type": "tool_use", "name": "Read", "input": {...}}       │
│ {"type": "tool_result", "content": "file contents..."}     │
│ ... (conversation history)                                  │
└────────────────────────────────────────────────────────────┘
                              │
                              ▼
              When resumed, this transcript is loaded
              into Claude's context window as history
```

If two processes tried to write simultaneously → corruption.

### What HUD Can Do While CLI Is Active

Even though HUD can't join an active CLI session, it can still:

| Feature | Mechanism |
|---------|-----------|
| Show live status ("Working", "Ready") | Hooks write to state file → HUD reads |
| Display current activity | Parse session JSONL as it's written (read-only) |
| Show other projects | Each project has separate sessions |
| Detect active session | Check for process or recent writes |

### HUD UX Implications

Design HUD for **handoffs, not hijacks**:

```
When CLI session is ACTIVE:
┌─────────────────────────────────────────────────────────────┐
│ project-x                                                    │
│                                                              │
│ Status: 🟢 Active in Terminal                               │
│ Working on: "Refactoring auth module"                        │
│                                                              │
│ [Focus Terminal]  [View Activity]                           │
│                                                              │
│ ─────────────────────────────────────────────────────────── │
│ ℹ️ Session active elsewhere. Resume available when stopped.  │
└─────────────────────────────────────────────────────────────┘

When CLI session is STOPPED:
┌─────────────────────────────────────────────────────────────┐
│ project-x                                                    │
│                                                              │
│ Status: ⏸️ Ready (waiting 18h)                              │
│ Last: "Refactoring auth module"                              │
│                                                              │
│ [Resume Session]  [Open in Terminal]  [Generate Summary]    │
└─────────────────────────────────────────────────────────────┘
```

### Session Continuity Across CLI and SDK

The powerful part: **context is preserved across handoffs**.

```
Yesterday (CLI):
┌─────────────────────────────────────────┐
│ $ claude                                │
│ > Help me refactor the auth module      │
│ [Claude works for 20 minutes]           │
│ > I've created a plan, here's what...   │
│ [User closes terminal, goes home]       │
└─────────────────────────────────────────┘
         ↓
    Session ID: abc-123 saved

Today (HUD via SDK):
┌─────────────────────────────────────────┐
│ User clicks "Resume Session" in HUD     │
│         ↓                               │
│ SDK: query({                            │
│   prompt: "Continue where we left off", │
│   options: { resume: "abc-123" }        │
│ })                                      │
│         ↓                               │
│ Claude continues WITH FULL CONTEXT      │
│ from yesterday's CLI session            │
└─────────────────────────────────────────┘
```

### Summary Table

| Question | Answer |
|----------|--------|
| Will users still use CLI? | **Yes.** CLI remains primary for interactive work. |
| Does SDK replace CLI? | **No.** SDK is for programmatic/automated features. |
| Can HUD work without SDK? | **Yes.** Current file-watching mode still works. |
| What does SDK add to HUD? | Ability to *do things* (resume, summarize, run agents). |
| Are session files shared? | **Yes.** Same JSONL storage used by both. |
| Can both access same live session? | **No.** One active process at a time. |
| Can sessions be handed off? | **Yes.** CLI → SDK or SDK → CLI seamlessly. |

---

## State Tracking Migration: Why Not to Do It

### The Question

A natural question when adopting the SDK: "Can we replace the shell-based hook system (`hud-state-tracker.sh`) with SDK native hooks?"

### The Short Answer

**No, not fully.** The SDK can only provide hooks for sessions it drives. CLI sessions (user runs `claude` directly) will always need the shell-based hooks.

### The Fundamental Constraint

The SDK operates at a different level than CLI hooks:

| Aspect | CLI Hooks | SDK Hooks |
|--------|-----------|-----------|
| When active | User runs `claude` in terminal | HUD calls `query()` via SDK |
| Hook execution | Inside CLI process | Inside SDK process |
| Can observe CLI sessions? | ✅ Yes (they ARE the CLI) | ❌ **No** |
| Can observe SDK sessions? | ❌ No (separate process) | ✅ Yes |

```
CLI Session:                     SDK Session:
┌─────────────┐                  ┌─────────────┐
│   claude    │                  │  HUD App    │
│    CLI      │                  │  (query())  │
│  ┌───────┐  │                  │  ┌───────┐  │
│  │ Hooks │──┼──► shell script  │  │ Hooks │──┼──► native callback
│  └───────┘  │                  │  └───────┘  │
└─────────────┘                  └─────────────┘
     │                                │
     ▼                                ▼
Same state file, different sources
```

**The SDK isn't running during CLI sessions, so it cannot observe or intercept CLI hooks.**

### Current State Tracking Architecture

The current system uses shell hooks configured in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "Notification": [{ "matcher": "idle_prompt", "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "PreCompact": [{ "matcher": "auto", "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/scripts/hud-state-tracker.sh" }] }]
  }
}
```

The shell script (`~/.claude/scripts/hud-state-tracker.sh`, ~246 lines):
- Parses hook input JSON
- Updates `~/.claude/hud-session-states.json` with state changes
- Spawns a background process holding a `flock` for session detection
- On `Stop`: generates `working_on`/`next_step` summary via Haiku

This system works reliably and has been production-tested.

### Migration Options Analysis

#### Option A: Full SDK Replacement ❌

**Would require:** All Claude usage goes through HUD (no direct CLI).

**Why this doesn't work:**
- Users want their interactive terminal (the whole point of Claude Code)
- HUD would need to provide a full terminal emulator
- Massive scope increase, defeats purpose of HUD as dashboard

**Verdict:** Not feasible.

#### Option B: Hybrid Approach ⚠️

**Architecture:** Keep shell hooks for CLI, use SDK hooks for HUD-driven sessions.

```
┌─────────────────────────────────────────────────────────────────────┐
│                 HYBRID: Shell Hooks + SDK Hooks                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  PATH A: User runs `claude` in terminal (unchanged)                 │
│  ─────────────────────────────────────────────────                  │
│           │                                                          │
│           ▼                                                          │
│  ┌─────────────────┐     shell hooks      ┌────────────────────┐    │
│  │  Claude CLI     │ ──────────────────►  │ hud-state-tracker  │    │
│  │  (interactive)  │                      │ .sh                │    │
│  └─────────────────┘                      └─────────┬──────────┘    │
│                                                     │               │
│                                                     ▼               │
│                                           ┌─────────────────────┐   │
│                                           │ hud-session-states  │   │
│  PATH B: User clicks "Resume" in HUD      │ .json               │   │
│  ─────────────────────────────────────    └─────────────────────┘   │
│           │                                         ▲               │
│           ▼                                         │               │
│  ┌─────────────────┐                               │               │
│  │  HUD App        │                               │               │
│  │  ┌───────────┐  │     SDK native hooks          │               │
│  │  │ SDK query │──┼───────────────────────────────┘               │
│  │  └───────────┘  │  (writes to same state file)                  │
│  └─────────────────┘                                                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**What this means:**
- CLI sessions continue using shell hooks (no change)
- HUD-driven sessions use SDK hooks (native TypeScript callbacks)
- Both write to the same `hud-session-states.json` format
- HUD reads from one place regardless of session source

**Effort required:**
| Component | Effort |
|-----------|--------|
| SDK bridge with state hooks | 2-3 days |
| Port shell logic to TypeScript | 1 day |
| Session lock mechanism in TS | 1 day |
| Testing both paths | 1-2 days |
| **Total additional work** | **~7-8 days** |

**What you gain:**
- Native callbacks for HUD-driven sessions (faster, easier to debug)
- TypeScript instead of bash (for HUD sessions only)

**What you DON'T gain:**
- Cannot remove shell hooks (still needed for CLI)
- Cannot simplify architecture (now have two systems)
- Cannot remove bash dependency

**Verdict:** Technically feasible but adds complexity for marginal benefit.

### Recommendation

**Don't prioritize state tracking migration.**

The shell-based system:
- Works reliably in production
- Is only ~246 lines of bash
- Has been debugged and refined
- Handles edge cases (recursive hooks, compacting, lock files)

The SDK integration effort should focus on features that **add new capabilities**:
1. Summary generation (cleaner than subprocess, model selection)
2. Session ID capture and resumption
3. Embedded agent panel
4. Quick actions

These provide user-facing value. Replacing working infrastructure does not.

### If You Still Want SDK Hooks for HUD Sessions

For HUD-driven sessions only, here's what SDK hooks would look like:

```typescript
// apps/sdk-bridge/src/state-hooks.ts

const STATE_FILE = `${homedir()}/.claude/hud-session-states.json`;

function updateState(projectPath: string, updates: Partial<ProjectState>) {
  const stateFile = JSON.parse(readFileSync(STATE_FILE, "utf-8"));
  const timestamp = new Date().toISOString();

  stateFile.projects[projectPath] = {
    ...stateFile.projects[projectPath],
    ...updates,
    state_changed_at: timestamp,
  };

  writeFileSync(STATE_FILE, JSON.stringify(stateFile, null, 2));
}

export const stateTrackingHooks = {
  UserPromptSubmit: [{
    hooks: [async (input: any) => {
      updateState(input.cwd, { state: "working", thinking: true, session_id: input.session_id });
      return {};
    }]
  }],

  PostToolUse: [{
    hooks: [async (input: any) => {
      // Heartbeat - keep thinking=true, update timestamp
      updateState(input.cwd, { thinking: true, thinking_updated_at: new Date().toISOString() });
      return {};
    }]
  }],

  Stop: [{
    hooks: [async (input: any) => {
      updateState(input.cwd, { state: "ready", thinking: false });
      // Generate summary async (like shell script does)
      generateSummaryInBackground(input.cwd, input.transcript_path);
      return {};
    }]
  }],

  Notification: [{
    matcher: "idle_prompt",
    hooks: [async (input: any) => {
      updateState(input.cwd, { state: "ready", thinking: false });
      return {};
    }]
  }],

  PreCompact: [{
    matcher: "auto",
    hooks: [async (input: any) => {
      updateState(input.cwd, { state: "compacting", thinking: true });
      return {};
    }]
  }]
};

// Use in SDK queries:
for await (const message of query({
  prompt: "...",
  options: {
    hooks: stateTrackingHooks,
    // ... other options
  }
})) {
  // ...
}
```

This would work for HUD-driven sessions while shell hooks continue handling CLI sessions.

### Summary Table

| Question | Answer |
|----------|--------|
| Can SDK fully replace shell hooks? | **No** - SDK isn't active during CLI sessions |
| What's the viable approach? | **Hybrid** - Shell for CLI, SDK for HUD-driven |
| Is this worth doing? | **Probably not** - Shell hooks work, adds complexity |
| What should be prioritized? | **New SDK features** (resume, summaries, agents) |
| When might full migration make sense? | Only if HUD becomes the only way to use Claude |
| Current shell script size | ~246 lines, battle-tested |
| Additional effort for hybrid | ~7-8 days |

---

## Core SDK Features

### 1. The `query()` Function

The main entry point for all agent interactions:

```typescript
import { query } from "@anthropic-ai/claude-agent-sdk";

for await (const message of query({
  prompt: "Find and fix bugs in auth.py",
  options: {
    allowedTools: ["Read", "Edit", "Bash"],
    permissionMode: "acceptEdits",
    cwd: "/path/to/project"
  }
})) {
  console.log(message);
}
```

```python
import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions

async def main():
    async for message in query(
        prompt="Find and fix bugs in auth.py",
        options=ClaudeAgentOptions(
            allowed_tools=["Read", "Edit", "Bash"],
            permission_mode="acceptEdits",
            cwd="/path/to/project"
        )
    ):
        print(message)

asyncio.run(main())
```

### 2. Built-in Tools

| Tool | Purpose | Example Use |
|------|---------|-------------|
| `Read` | Read file contents | Examining code |
| `Write` | Create new files | Generating code |
| `Edit` | Modify existing files | Bug fixes, refactoring |
| `Bash` | Run terminal commands | Tests, builds, git |
| `Glob` | Find files by pattern | `**/*.ts`, `src/**/*.py` |
| `Grep` | Search file contents | Find usages, patterns |
| `WebSearch` | Search the web | Current information |
| `WebFetch` | Fetch web pages | Documentation |
| `Task` | Spawn subagents | Delegate subtasks |
| `AskUserQuestion` | Ask clarifying questions | Multiple choice prompts |

### 3. Permission Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `default` | Prompts for unmatched tools | Interactive approval |
| `acceptEdits` | Auto-approve file edits | Trusted development |
| `dontAsk` | Auto-deny unless allowed | CI/CD pipelines |
| `bypassPermissions` | Auto-approve everything | Fully automated |

### 4. Session Management

**Capturing session ID:**
```typescript
let sessionId: string | undefined;

for await (const message of query({ prompt: "..." })) {
  if (message.type === 'system' && message.subtype === 'init') {
    sessionId = message.session_id;
    // Store this for later resumption
  }
}
```

**Resuming a session:**
```typescript
for await (const message of query({
  prompt: "Continue where we left off",
  options: { resume: savedSessionId }
})) {
  // Full context from previous session is restored
}
```

**Forking a session:**
```typescript
for await (const message of query({
  prompt: "Try a different approach",
  options: {
    resume: savedSessionId,
    forkSession: true  // Creates new branch, preserves original
  }
})) {
  // Explore alternative without modifying original session
}
```

### 5. Hooks

Hooks are callbacks that fire at lifecycle events:

| Hook | When It Fires | Common Use |
|------|---------------|------------|
| `PreToolUse` | Before tool executes | Block dangerous operations |
| `PostToolUse` | After tool executes | Audit logging |
| `Stop` | Agent stops | Save state |
| `SessionStart` | Session begins (TS only) | Initialize resources |
| `SessionEnd` | Session ends (TS only) | Cleanup |
| `Notification` | Status messages (TS only) | Progress updates |
| `SubagentStop` | Subagent completes | Aggregate results |
| `UserPromptSubmit` | User sends prompt | Inject context |
| `PreCompact` | Before context compaction | Archive transcript |

**Hook example:**
```typescript
const hooks = {
  PreToolUse: [{
    matcher: 'Edit|Write',  // Regex for tool names
    hooks: [async (input, toolUseId, { signal }) => {
      const filePath = input.tool_input?.file_path;
      if (filePath?.includes('.env')) {
        return {
          hookSpecificOutput: {
            hookEventName: input.hook_event_name,
            permissionDecision: 'deny',
            permissionDecisionReason: 'Cannot modify .env files'
          }
        };
      }
      return {};
    }]
  }],
  PostToolUse: [{
    hooks: [async (input) => {
      console.log(`Tool completed: ${input.tool_name}`);
      return {};
    }]
  }]
};

for await (const message of query({
  prompt: "...",
  options: { hooks }
})) { /* ... */ }
```

### 6. Subagents

Define specialized agents that the main agent can invoke:

```typescript
const agents = {
  "code-reviewer": {
    description: "Expert code reviewer for security and quality",
    prompt: "You are a code review specialist. Focus on security, performance, and best practices.",
    tools: ["Read", "Grep", "Glob"],  // Read-only
    model: "sonnet"
  },
  "test-runner": {
    description: "Runs and analyzes test suites",
    prompt: "You run tests and analyze results.",
    tools: ["Bash", "Read", "Grep"]
  }
};

for await (const message of query({
  prompt: "Review auth.py for security issues",
  options: {
    allowedTools: ["Read", "Grep", "Glob", "Task"],  // Task required for subagents
    agents
  }
})) { /* ... */ }
```

### 7. Streaming Input Mode

For long-lived interactive sessions:

```typescript
async function* generateMessages() {
  yield {
    type: "user",
    message: { role: "user", content: "First message" }
  };

  // Wait for user input or conditions
  await waitForUserInput();

  yield {
    type: "user",
    message: { role: "user", content: "Follow-up message" }
  };
}

for await (const message of query({
  prompt: generateMessages(),  // Generator instead of string
  options: { maxTurns: 10 }
})) { /* ... */ }
```

---

## HUD Migration Opportunities

### 1. Summary Generation (High Priority)

**Current implementation** (in `apps/sdk-bridge/` or Swift app):
```rust
fn generate_session_summary_sync(transcript: &str) -> Result<String, String> {
    let output = Command::new("/opt/homebrew/bin/claude")
        .arg("--output-format").arg("text")
        .arg("-p").arg(prompt)
        .output()?;
    // ...
}
```

**SDK replacement:**
```typescript
import { query } from "@anthropic-ai/claude-agent-sdk";

async function generateSessionSummary(transcript: string): Promise<string> {
  let result = "";

  for await (const message of query({
    prompt: `Summarize this Claude Code session:\n\n${transcript}`,
    options: {
      maxTurns: 1,
      model: "haiku",  // Cheaper for summaries
      allowedTools: []  // No tools needed
    }
  })) {
    if (message.type === "result") {
      result = message.result;
    }
  }

  return result;
}
```

**Benefits:**
- Model selection (Haiku = cheaper)
- Proper error handling
- No subprocess spawning
- Can stream partial results to UI

### 2. Session ID Storage (High Priority)

**New HUD feature:** Store session IDs with projects for resumption.

**Data model addition:**
```typescript
// In hud.json or new session store
interface ProjectSession {
  projectPath: string;
  sessionId: string;
  lastActivity: number;
  lastPrompt: string;
  state: "active" | "completed" | "abandoned";
}
```

**Implementation:**
```typescript
// When starting a new session
let currentSession: ProjectSession | null = null;

for await (const message of query({
  prompt: userPrompt,
  options: { cwd: projectPath }
})) {
  if (message.type === 'system' && message.subtype === 'init') {
    currentSession = {
      projectPath,
      sessionId: message.session_id,
      lastActivity: Date.now(),
      lastPrompt: userPrompt,
      state: "active"
    };
    await saveSession(currentSession);
  }
  // ...
}
```

### 3. Resume Session Feature (High Priority)

**New HUD UI element:** "Resume Last Session" button in ProjectDetailView.

**Implementation:**
```typescript
async function resumeSession(project: Project): Promise<void> {
  const session = await loadLastSession(project.path);
  if (!session?.sessionId) {
    throw new Error("No session to resume");
  }

  for await (const message of query({
    prompt: "Continue where we left off",
    options: {
      resume: session.sessionId,
      cwd: project.path
    }
  })) {
    // Stream to HUD activity panel
    hudActivityPanel.append(message);
  }
}
```

### 4. Real-Time State Tracking (Medium Priority)

**Replace shell hooks with SDK hooks:**

**Current:** `~/.claude/scripts/hud-state-tracker.sh` writes to `~/.claude/hud-session-states.json`

**SDK approach:**
```typescript
interface HudStateUpdate {
  projectPath: string;
  state: "working" | "ready" | "waiting" | "idle";
  tool?: string;
  timestamp: number;
}

const stateTrackingHooks = {
  PreToolUse: [{
    hooks: [async (input) => {
      await updateHudState({
        projectPath: input.cwd,
        state: "working",
        tool: input.tool_name,
        timestamp: Date.now()
      });
      return {};
    }]
  }],
  Stop: [{
    hooks: [async (input) => {
      await updateHudState({
        projectPath: input.cwd,
        state: "ready",
        timestamp: Date.now()
      });
      return {};
    }]
  }],
  Notification: [{
    matcher: "idle_prompt",
    hooks: [async (input) => {
      await updateHudState({
        projectPath: input.cwd,
        state: "waiting",
        timestamp: Date.now()
      });
      return {};
    }]
  }]
};
```

### 5. Embedded Agent Panel (Medium Priority)

**New HUD feature:** A view that runs agents directly from HUD.

```typescript
// HUD launches agent for project
async function launchAgentForProject(
  project: Project,
  task: string
): Promise<void> {
  const claudeMd = await readFile(`${project.path}/CLAUDE.md`);

  for await (const message of query({
    prompt: task,
    options: {
      cwd: project.path,
      allowedTools: ["Read", "Edit", "Bash", "Glob", "Grep"],
      permissionMode: "acceptEdits",
      systemPrompt: claudeMd,
      hooks: stateTrackingHooks
    }
  })) {
    // Render in HUD activity panel
    if (message.type === "assistant") {
      for (const block of message.message?.content ?? []) {
        if ("text" in block) {
          hudPanel.appendText(block.text);
        } else if ("name" in block) {
          hudPanel.appendToolCall(block.name, block.input);
        }
      }
    }
  }
}
```

### 6. Activity Timeline (Lower Priority)

**New HUD feature:** Detailed log of all agent activity.

```typescript
interface ActivityEntry {
  timestamp: number;
  type: "tool_start" | "tool_complete" | "thinking" | "result";
  tool?: string;
  file?: string;
  summary?: string;
}

const activityLog: ActivityEntry[] = [];

const activityHooks = {
  PreToolUse: [{
    hooks: [async (input) => {
      activityLog.push({
        timestamp: Date.now(),
        type: "tool_start",
        tool: input.tool_name,
        file: input.tool_input?.file_path
      });
      return {};
    }]
  }],
  PostToolUse: [{
    hooks: [async (input) => {
      activityLog.push({
        timestamp: Date.now(),
        type: "tool_complete",
        tool: input.tool_name,
        summary: summarizeToolResult(input.tool_response)
      });
      return {};
    }]
  }]
};
```

### 7. HUD-Defined Agents (Lower Priority)

**New HUD feature:** Quick-action agents invokable from UI.

```typescript
const hudAgents = {
  "project-status": {
    description: "Generate project status report",
    prompt: `Analyze the project and report:
      - Current state of work in progress
      - Pending tasks from TODOs and issues
      - Recent git activity
      - Build/test status`,
    tools: ["Read", "Glob", "Grep", "Bash"]
  },
  "quick-fix": {
    description: "Fix common issues (lint, type errors)",
    prompt: "Find and fix linting errors and type issues",
    tools: ["Read", "Edit", "Bash"]
  },
  "update-deps": {
    description: "Check and update dependencies",
    prompt: "Check for outdated dependencies and update them safely",
    tools: ["Read", "Edit", "Bash"]
  }
};

// UI: Dropdown of quick actions
async function runQuickAction(actionName: string, project: Project) {
  for await (const message of query({
    prompt: `Use the ${actionName} agent`,
    options: {
      cwd: project.path,
      agents: hudAgents,
      allowedTools: ["Read", "Edit", "Bash", "Glob", "Grep", "Task"]
    }
  })) {
    // Handle results
  }
}
```

---

## Implementation Patterns

### Pattern 1: Collecting Full Result

When you don't need streaming, collect the final result:

```typescript
async function collectResult(prompt: string, options: ClaudeAgentOptions): Promise<string> {
  let result = "";

  for await (const message of query({ prompt, options })) {
    if (message.type === "result") {
      result = message.result ?? "";
    }
  }

  return result;
}
```

### Pattern 2: Progress Callback

For UI updates during execution:

```typescript
type ProgressCallback = (update: {
  type: "thinking" | "tool" | "result";
  content: string;
}) => void;

async function queryWithProgress(
  prompt: string,
  options: ClaudeAgentOptions,
  onProgress: ProgressCallback
): Promise<string> {
  let result = "";

  for await (const message of query({ prompt, options })) {
    if (message.type === "assistant") {
      for (const block of message.message?.content ?? []) {
        if ("text" in block) {
          onProgress({ type: "thinking", content: block.text });
        } else if ("name" in block) {
          onProgress({ type: "tool", content: `Running: ${block.name}` });
        }
      }
    } else if (message.type === "result") {
      result = message.result ?? "";
      onProgress({ type: "result", content: result });
    }
  }

  return result;
}
```

### Pattern 3: Timeout and Cancellation

```typescript
async function queryWithTimeout(
  prompt: string,
  options: ClaudeAgentOptions,
  timeoutMs: number
): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    let result = "";
    for await (const message of query({
      prompt,
      options: { ...options, signal: controller.signal }
    })) {
      if (message.type === "result") {
        result = message.result ?? "";
      }
    }
    return result;
  } finally {
    clearTimeout(timeout);
  }
}
```

### Pattern 4: Error Handling

```typescript
async function safeQuery(prompt: string, options: ClaudeAgentOptions): Promise<{
  success: boolean;
  result?: string;
  error?: string;
}> {
  try {
    let result = "";
    for await (const message of query({ prompt, options })) {
      if (message.type === "result") {
        if (message.subtype === "error") {
          return { success: false, error: message.result };
        }
        result = message.result ?? "";
      }
    }
    return { success: true, result };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}
```

### Pattern 5: Rust FFI Bridge

Since HUD's core is Rust but SDK is TypeScript/Python, you'll need a bridge:

**Option A: Sidecar Process**
```rust
// In hud-core
use std::process::{Command, Stdio};

pub fn query_sdk(prompt: &str, project_path: &str) -> Result<String, Error> {
    let output = Command::new("node")
        .arg("--experimental-specifier-resolution=node")
        .arg("-e")
        .arg(format!(r#"
            import {{ query }} from '@anthropic-ai/claude-agent-sdk';
            let result = '';
            for await (const m of query({{
                prompt: `{}`,
                options: {{ cwd: `{}` }}
            }})) {{
                if (m.type === 'result') result = m.result;
            }}
            console.log(result);
        "#, prompt.replace('`', r"\`"), project_path))
        .stdout(Stdio::piped())
        .output()?;

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
```

**Option B: TypeScript Daemon with IPC**
```typescript
// apps/sdk-bridge/src/index.ts
import { query } from "@anthropic-ai/claude-agent-sdk";
import * as net from "net";

const server = net.createServer(async (socket) => {
  socket.on("data", async (data) => {
    const request = JSON.parse(data.toString());

    for await (const message of query(request)) {
      socket.write(JSON.stringify(message) + "\n");
    }
    socket.end();
  });
});

server.listen("/tmp/hud-sdk.sock");
```

---

## Architecture Recommendations

### Recommended Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HUD Frontend (Swift)                          │
│  - Project list, details, artifacts                              │
│  - Activity panel (streamed from SDK)                            │
│  - Quick action buttons                                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │ IPC / UniFFI
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    hud-core (Rust)                               │
│  - Project/session/stats management (existing)                   │
│  - SDK bridge coordinator                                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │ Unix socket / stdio
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SDK Bridge (TypeScript)                       │
│  - Long-running process                                          │
│  - Handles SDK queries                                           │
│  - Streams results back                                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Claude Agent SDK                              │
│  - Spawns Claude Code runtime                                    │
│  - Executes tools                                                │
│  - Manages sessions                                              │
└─────────────────────────────────────────────────────────────────┘
```

### Integration Points

| HUD Component | SDK Integration |
|---------------|-----------------|
| `generate_session_summary_sync()` | Replace with SDK query |
| `ProjectDetails.sessions` | Add `sessionId` field for resumption |
| State tracking hooks | Optionally replace with SDK hooks |
| New: Activity panel | Stream SDK messages |
| New: Quick actions | Predefined SDK agents |

### Keeping Existing Functionality

The SDK integration should be **additive**, not a replacement of working systems:

1. **Keep shell hooks for passive monitoring** - They work, low maintenance
2. **Add SDK for active features** - Summaries, resumption, embedded agents
3. **Migrate incrementally** - Start with summaries, prove the pattern

---

## Migration Roadmap

### Phase 1: Foundation (1-2 days)

- [ ] Create `apps/sdk-bridge/` TypeScript project
- [ ] Implement basic IPC server
- [ ] Add Rust client in hud-core
- [ ] Test round-trip communication

### Phase 2: Summary Migration (1 day)

- [ ] Replace `generate_session_summary_sync()` with SDK call
- [ ] Add model selection (Haiku for summaries)
- [ ] Update error handling
- [ ] Test summary generation

### Phase 3: Session Management (2-3 days)

- [ ] Add `sessionId` to data model
- [ ] Capture session IDs from SDK queries
- [ ] Store sessions in `hud-sessions.json`
- [ ] Implement "Resume Session" in UI
- [ ] Test resumption flow

### Phase 4: Activity Panel (3-4 days)

- [ ] Design activity panel UI component
- [ ] Implement message streaming from SDK
- [ ] Add progress indicators
- [ ] Handle tool calls display
- [ ] Test with real workflows

### Phase 5: Quick Actions (2-3 days)

- [ ] Define HUD agent presets
- [ ] Add quick action UI (dropdown/buttons)
- [ ] Implement agent invocation
- [ ] Test various agents

### Phase 6: Optional - State Tracking Migration

- [ ] Evaluate if hook migration is worth it
- [ ] If yes, implement SDK-based state tracking
- [ ] Remove shell script hooks
- [ ] Update documentation

---

## API Reference

### ClaudeAgentOptions (TypeScript)

```typescript
interface ClaudeAgentOptions {
  // Core options
  model?: "sonnet" | "opus" | "haiku";
  cwd?: string;
  systemPrompt?: string;
  maxTurns?: number;

  // Tools and permissions
  allowedTools?: string[];
  permissionMode?: "default" | "acceptEdits" | "dontAsk" | "bypassPermissions";

  // Session management
  resume?: string;           // Session ID to resume
  forkSession?: boolean;     // Fork instead of continue
  continue?: boolean;        // Continue last session

  // Hooks
  hooks?: {
    PreToolUse?: HookMatcher[];
    PostToolUse?: HookMatcher[];
    Stop?: HookMatcher[];
    SessionStart?: HookMatcher[];
    SessionEnd?: HookMatcher[];
    Notification?: HookMatcher[];
    SubagentStop?: HookMatcher[];
    UserPromptSubmit?: HookMatcher[];
    PreCompact?: HookMatcher[];
  };

  // Subagents
  agents?: Record<string, AgentDefinition>;

  // MCP servers
  mcpServers?: Record<string, McpServerConfig>;

  // Settings sources
  settingSources?: ("project" | "user")[];
}
```

### AgentDefinition

```typescript
interface AgentDefinition {
  description: string;  // When to use this agent
  prompt: string;       // System prompt
  tools?: string[];     // Allowed tools (inherits if omitted)
  model?: "sonnet" | "opus" | "haiku" | "inherit";
}
```

### HookMatcher

```typescript
interface HookMatcher {
  matcher?: string;              // Regex for tool names
  hooks: HookCallback[];         // Callback functions
  timeout?: number;              // Timeout in seconds (default: 60)
}

type HookCallback = (
  input: HookInput,
  toolUseId: string | null,
  context: { signal: AbortSignal }
) => Promise<HookOutput>;
```

### Message Types

```typescript
// System init message (contains session ID)
{ type: "system", subtype: "init", session_id: string }

// Assistant message (Claude's response)
{ type: "assistant", message: { content: ContentBlock[] } }

// Result message (final output)
{ type: "result", subtype: "success" | "error", result: string }

// Tool result
{ type: "tool_result", tool_use_id: string, content: string }
```

---

## Resources

### Official Documentation

- [Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Quickstart Guide](https://platform.claude.com/docs/en/agent-sdk/quickstart)
- [Sessions](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [Hooks](https://platform.claude.com/docs/en/agent-sdk/hooks)
- [Permissions](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents)
- [Streaming vs Single Mode](https://platform.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)

### SDK Repositories

- [TypeScript SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
- [Python SDK](https://github.com/anthropics/claude-agent-sdk-python)
- [Example Agents](https://github.com/anthropics/claude-agent-sdk-demos)

### Related HUD Documentation

- [HUD State Tracking Architecture](../docs/architecture-decisions/001-state-tracking-approach.md)
- [HUD Daemon Design](../../docs/hud-daemon-design.md)
- [Claude Code Artifacts Reference](../../docs/claude-code-artifacts.md)

---

## Changelog

| Date | Change |
|------|--------|
| 2025-01-11 | Added state tracking migration analysis: why SDK can't replace shell hooks for CLI |
| 2025-01-11 | Added hybrid approach architecture diagram and effort estimates |
| 2025-01-11 | Added SDK hook code examples for HUD-driven sessions |
| 2025-01-11 | Added recommendation: prioritize new features over infrastructure replacement |
| 2025-01-11 | Added CLI/SDK coexistence section explaining complementary relationship |
| 2025-01-11 | Added session sharing clarification: sequential (resume), not concurrent |
| 2025-01-11 | Added HUD UX implications for active vs stopped sessions |
| 2025-01-11 | Initial research and documentation |
