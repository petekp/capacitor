# Capacitor Orchestrator Design

**Date:** 2026-03-15
**Status:** Draft

## Vision

The ADE space is converging on complex GUIs for micromanaging agents. Capacitor takes the opposite bet: as model capabilities improve, users won't need to micromanage. Instead, each project gets a "sous chef" — a persistent orchestrating agent that translates the user's intent into action, keeps parallel work on track, and surfaces only decisions and completions.

Capacitor remains a thin layer over Claude Code, leaning into its native features (subagents, worktrees, task lists, headless mode) rather than replacing them. The orchestrator makes Claude Code's evolving capabilities more discoverable and tastefully automatic.

## Core Principles

1. **The filesystem is the durable source of truth.** All orchestration state lives as human-readable files. The runtime service ingests from these files and provides typed, derived views for the UI — consistent with the existing architecture where the runtime service owns ingest/reduce/query. The filesystem is the storage layer; the runtime service is the live query layer. The orchestrator and workers read/write files directly; the UI reads from the runtime service which watches the filesystem. This avoids a split-brain boundary — there is one flow direction: files → runtime service → UI.
2. **Recoverability by default.** Any actor can crash — orchestrator, worker, Capacitor itself — and nothing is lost. State is on disk. Any new session can pick up where the last one left off.
3. **The orchestrator is the single face.** The user talks to one entity per project. Workers are invisible implementation details. Milestones are presented in the orchestrator's voice. Decisions flow through the orchestrator.
4. **Lean into Claude Code.** Don't rebuild what Claude Code already does. Use subagents for small tasks, headless mode (`claude -p`) for workers, MCP for tool integration, `/loop` (Claude Code's built-in scheduled task system) for periodic polling. Capacitor adds value as the nervous system, not the brain.
5. **Decisions and completions, not narration.** The user sees what's done, what needs their input, and what's next. Not a play-by-play of every agent action.

## System Overview

Three actors:

- **Orchestrator** — Interactive Claude Code session, one per project. The user's single point of contact. Has longitudinal memory of the project, proactively suggests next steps, and coordinates work via Capacitor's MCP tools.
- **Workers** — Headless `claude -p` conversations for substantial, independent tasks. A worker is a **conversation** (identified by session_id), not a long-lived process. Each `claude -p` invocation runs the agent loop to completion and exits; `--resume` reopens the same conversation in a new process. This distinction matters for lifecycle management — see Worker Identity Model below. Managed by Capacitor. Invisible to the user except as task status. Report activity via hooks and filesystem.
- **Capacitor** — Persistent macOS app. Runs a **new MCP server** (new infrastructure, separate from the existing authenticated runtime service on port 7474) exposing orchestration tools. Manages worker lifecycle (spawn, monitor, relay, kill), persists workflow state, and surfaces status in the UI. The nervous system and hands.

### Communication Flow

```
User <-> Orchestrator (interactive Claude Code session)
            | MCP tools
         Capacitor MCP Server
            | claude -p / --resume
         Workers (headless Claude Code)
            | hooks + filesystem
         Capacitor (observes, aggregates, surfaces)
```

All local. No external dependencies. The orchestrator is the brain, Capacitor is the nervous system.

## Two-Tier Task Model

The orchestrator chooses the right tool for the job:

- **Subagents** — For quick, bounded tasks that fit within the orchestrator's context window. "Research how this API works," "write tests for this module," "refactor this single file." Native Claude Code subagents, no Capacitor involvement needed. Rule of thumb: if it can be done in ~50 turns or fewer and doesn't need to run independently, it's a subagent.
- **Workers** — For substantial features that need their own context window and sustained independent execution. "Build the settings page," "refactor the auth system." Spawned by Capacitor as headless `claude -p` processes in isolated git worktrees, monitored via hooks, communicated with via `--resume`.

The determining factor is scope and duration, not complexity. If it needs its own context window, it's a worker. The orchestrator's briefing template includes guidance on making this determination, but the orchestrator can use judgment based on the task at hand.

## Mise en Place — Session Bootstrap

When the user clicks a project card with orchestrator mode ON, Capacitor prepares the station:

1. **Gather workflow state** — Read the project's `context/` directory: memory.md, today's daily log, tasks.md.
2. **Gather project state** — Git status, recent commits, open PRs, CI status.
3. **Assemble briefing** — Combine workflow + project state using the project's briefing template.
4. **Verify MCP** — Ensure Capacitor's MCP server is registered in user-level Claude Code settings (`~/.claude/settings.json`). First-run only.
5. **Launch orchestrator** — Open Claude Code in the terminal with `--append-system-prompt` (a Claude Code CLI flag that adds instructions to the system prompt while preserving default behavior) containing the assembled briefing.
6. **Orchestrator greets the user** — Based on the briefing, presents prioritized options for what to work on. Multiple choice, digestible, ADHD-friendly.

If an orchestrator session already exists for this project, Capacitor reconnects to it instead.

## Orchestrator Interface

The orchestrator's behavior is controlled by three inputs. Get these right and the interaction design becomes a tuning problem, not an architecture problem.

### 1. Briefing Template

A composable system prompt assembled by Capacitor at launch. Has slots for:
- Workflow state (from markdown files)
- Project state (git, PRs, CI)
- User preferences
- Behavioral instructions (proactivity level, review cadence, option style)

Stored at `~/.capacitor/projects/{name}/context/briefing/template.md`. Editable by the user. Changing orchestrator personality = editing the template, not changing code.

**Minimum viable template slots:**

```markdown
# Orchestrator Briefing — {{project_name}}

## Who You Are
You are the orchestrator for this project. You are the user's single point of
contact. Workers are invisible to the user — present their work in your voice.

## Workflow State
{{memory.md contents}}

## What Happened Recently
{{today's daily log + yesterday's if early in the day}}

## Active Tasks
{{tasks.md contents}}

## Project State
{{git status, recent commits, open PRs, CI status — assembled by Capacitor}}

## Active Workers
{{worker list with IDs, briefings, and current status — from registry + status.md files}}

## Behavioral Preferences
- Proactivity: suggest next steps after completing work
- Options: present 2-4 multiple choice options when asking the user to decide
- Review cadence: surface milestones as they arrive, batch minor updates
```

This is the starting template. Users can edit it to adjust tone, proactivity level, or add project-specific instructions. Capacitor fills the `{{}}` slots at launch time.

### 2. MCP Tool Surface

Capacitor's MCP server exposes these tools to the orchestrator:

**Worker management:**
- `capacitor_spawn_worker(briefing, working_directory, allowed_tools)` — Creates a git worktree (under `.capacitor/worktrees/`), records the base commit, launches a headless `claude -p` process in it, captures the session_id from the JSON output, persists the full worker record (worker_id, session_id, PID, worktree path, base_commit) to `runtime/registry.json`, and returns `worker_id`. The PID is ephemeral (see Worker Identity Model) — the session_id is the durable handle. On failure (e.g., process fails to start), returns an error with diagnostic info rather than a partial record. Workers receive only Claude Code's native tools (Read, Edit, Write, Bash, Glob, Grep, etc.) plus any explicitly passed in `allowed_tools`. Workers do **not** have access to Capacitor's MCP tools — they cannot spawn sub-workers or interact with the orchestration layer. Default `allowed_tools` if not specified: `Read, Edit, Write, Bash, Glob, Grep`.
- `capacitor_worker_status(worker_id)` — Returns: status (`running`, `paused`, `completed`, `failed`, `killed`), recent files modified and edit frequency, tool call count and error count, time elapsed, time since last meaningful progress, and latest `status.md` content. Status values match the Worker Identity Model lifecycle states exactly. Activity data is derived from Claude Code's hook events (PreToolUse, PostToolUse, Stop) which Capacitor already ingests. For `paused` workers, also returns whether a milestone is pending review.
- `capacitor_send_message(worker_id, message)` — Relays via `claude -p "message" --resume $session_id`. Returns confirmation or error if the session is no longer active.
- `capacitor_kill_worker(worker_id)` — If the worker has a live PID (`running`), terminates the process. If the worker is `paused` (no live process, but conversation is resumable), retires the conversation — marks it `killed` and no further `--resume` calls will be made. In both cases, the git worktree is preserved for inspection; the user or orchestrator can decide to cherry-pick, merge, or discard.
- `capacitor_list_workers()` — All active workers for this project with summary status.

**Project context:**
- `capacitor_project_status()` — git status, open PRs, CI, recent commits

**UI integration:**
- `capacitor_notify(message, level)` — surface a notification in the UI
- `capacitor_update_worker_label(worker_id, label)` — control how a worker appears in the UI

The orchestrator reads and writes workflow state files (memory.md, daily/, tasks.md) directly using Claude Code's built-in Read/Edit tools. No custom MCP tools for state management — fewer moving parts.

### 3. Workflow State as Markdown

Inspired by OpenClaw's approach: plain markdown files are the shared medium between humans and agents. Both can read and write them, they're diffable, git-friendly, and inspectable.

The orchestrator and user co-maintain these files. Capacitor reads them for UI purposes (e.g., showing task status on the project card).

## Filesystem as Shared Backbone

All communication flows through `~/.capacitor/projects/{name}/`. No custom protocols, no databases.

```
~/.capacitor/projects/{name}/
├── context/                        # Durable, syncable (iCloud/Dropbox-safe)
│   ├── memory.md                   # Long-term project context
│   ├── daily/
│   │   └── 2026-03-15.md           # Today's session log (append-only)
│   ├── tasks.md                    # Active tasks and status
│   └── briefing/
│       └── template.md             # Orchestrator system prompt template
├── workers/                        # Durable, syncable
│   └── {worker_id}/
│       ├── briefing.md             # What this worker was tasked with
│       ├── status.md               # Worker self-reports progress
│       ├── milestones/
│       │   └── 01/
│       │       ├── brief.md        # What was done, what decision is needed
│       │       ├── actions.json    # Anticipated next actions (generated by Capacitor)
│       │       └── artifacts/      # Docs, images, prototypes, media
│       └── inbox/
│           └── response-01.md      # User's decision (structured markdown)
└── runtime/                        # Ephemeral, machine-specific, local only
    └── registry.json               # Active worker PIDs, session IDs
```

### Who reads/writes what

| Actor | Reads | Writes |
|---|---|---|
| Orchestrator | everything | memory.md, daily/, tasks.md, workers/{id}/briefing.md |
| Workers | their own briefing.md, inbox responses | status.md, milestones/ |
| Capacitor | everything (via FSEvents) | runtime/registry.json, milestone actions.json, inbox responses |
| User | anything | anything |

### Cloud Sync

The `context/` and `workers/` directories are safe to sync via iCloud, Dropbox, or similar. This enables **read-only continuity** across machines — you can review workflow history, past milestones, and project memory from any machine. However, active worker control (process management, message relay) is machine-local. A second machine can observe synced artifacts but cannot adopt or control workers running on the first machine. The `runtime/` directory stays local since it contains machine-specific ephemeral state (PIDs, session IDs).

Capacitor gracefully handles stale runtime data on startup (reconciles PIDs, cleans up dead workers). If synced worker files show a worker as `running` but no local PID exists, Capacitor treats it as a remote worker and displays status as read-only.

## Milestone Review Flow

When a worker reaches a checkpoint or completes a task, the user needs to review and decide how to proceed. This flow is designed to be rich, media-friendly, and ADHD-friendly.

### How milestones are produced

1. Worker reaches a checkpoint. Writes to its `milestones/` directory: `brief.md` (what happened, what decision is needed) and any artifacts (docs, images, prototypes, recordings).
2. Capacitor detects the new milestone via FSEvents.
3. Capacitor runs a short headless `claude -p` call to generate anticipated next actions (`actions.json`). This call is fed the milestone brief, the project's workflow state, and active task context — giving it broad enough context to suggest smart options.
4. Project card enters milestone mode.

### How milestones are reviewed

1. Project card shows persistent "review needed" indicator (not a transient notification — stays until acted upon).
2. User clicks card. Instead of routing to the terminal, Capacitor opens a **local web page** — the milestone review interface.
3. The review page presents the milestone in the **orchestrator's voice**: "Here's what we've got for the keyboard shortcuts feature. Take a look and let me know how to proceed."
4. Content is rendered appropriately: markdown viewer for docs, image gallery for screenshots, iframe for HTML prototypes, video player for recordings.
5. Anticipated actions are presented as clear buttons/choices derived from `actions.json`. The user picks one, optionally adds notes.
6. On submission, Capacitor writes the decision to the worker's `inbox/` as a structured markdown file (see Inbox Response Format), relays to the worker via `claude -p --resume $session_id`, and focuses the orchestrator's terminal tab. The decision is also written to the project's `context/` directory so the orchestrator can discover it. The orchestrator — either via its `/loop` polling or when the user next speaks to it — reads the decision and acknowledges it: "Going with Option A. I'll pass that along and keep it moving. Want to tackle anything else?" Note: the orchestrator is an interactive session and cannot be programmatically injected into via `--resume`. Discovery happens through filesystem reads, not message injection.

### Option generation

The headless `claude -p` call that generates `actions.json` is a focused, disposable LLM call — not a full worker session. Capacitor assembles the prompt from filesystem context:

**Input:** The milestone's `brief.md`, artifact file paths, the project's `tasks.md` and `memory.md`, and the active worker list with their briefings.

**Output:** A JSON array of 3-4 action objects, each with an `id`, `label` (button text), `description` (one-line rationale), and `type` (approve, choose, request_changes, custom). Framed in the orchestrator's voice.

**On failure:** If the headless call fails or returns malformed output, Capacitor falls back to a default set of actions: "Approve," "Request changes," "Discuss with orchestrator." The milestone review page always renders — it just may have generic options instead of smart ones.

The `--json-schema` flag on the `claude -p` call enforces the output structure. The call runs with `--allowedTools "Read"` so it can inspect artifacts if needed, but cannot modify anything.

## Worker Health Monitoring

The orchestrator monitors worker health by calling `capacitor_worker_status()`, which returns rich activity signals:
- Files modified and frequency
- Tool call count and error rate
- Time elapsed since spawn
- Time since last meaningful progress

The orchestrator — being an LLM with context about the worker's briefing and scope — interprets these signals and makes judgment calls: "The routing test fix seems stuck, it keeps editing the same file. Want me to kill it and try a different approach?"

The orchestrator can set up a `/loop` to periodically poll worker status while work is in flight, enabling proactive detection of stalled or off-track workers without the user having to ask.

Capacitor also surfaces worker health heuristics in the UI for at-a-glance awareness.

## Project Card Modes

The project card evolves from a terminal router to a context-aware entry point:

**Default mode** — Project name, last activity, one-line summary from the most recent daily log. Click opens the orchestrator session (launching with mise en place if needed).

**Active mode** — Work is in flight. Shows task summary at the "decisions and completions" level:
```
capacitor
  Auth refactor — in progress
  Keyboard shortcuts — done, awaiting review  <-
  Last active: 2 min ago
```
Click routes to the orchestrator session.

**Milestone mode** — A decision is needed. Persistent indicator, not dismissable until acted on.
```
capacitor  * review needed
  Keyboard shortcuts — proposal ready
```
Click opens the milestone review page (local web UI). After the user submits a decision, they land in the orchestrator chat.

The card click always takes the user to the **most useful place** — usually the orchestrator, but the review page when a decision is pending.

## Orchestrator Mode

**ON (default)** — Full experience. Capacitor manages an orchestrator session per project, maintains workflow state, MCP tools available, workers, milestones. This is Capacitor.

**OFF** — Terminal router. Project cards map to terminals, clicking routes you there. No orchestrator, no workers, no workflow state. For users who want a fast switcher and nothing more.

## Orchestrator Singleton Contract

Each project has exactly one active orchestrator. Capacitor enforces this via a registry record in `runtime/`:

```json
{
  "project": "capacitor",
  "session_id": "ses-orch-abc123",
  "terminal_tab_id": "ghostty-tab-7",
  "machine_id": "petes-macbook-abc",
  "heartbeat": "2026-03-15T14:32:00Z",
  "started_at": "2026-03-15T10:00:00Z"
}
```

**Liveness detection:**

Hook activity is an *activity* signal, not a *liveness* signal — an orchestrator sitting idle at the prompt is healthy but emits no hooks. Capacitor uses a dedicated liveness probe:

- **Primary:** Process-tree inspection + session identity verification. Capacitor knows the terminal tab/pane and checks whether a `claude` process is running in it (via the tab's shell PID → child process tree). If a process is found, Capacitor verifies it is the *recorded* orchestrator session by matching the process's session ID against the stored `session_id` in the orchestrator registry. Session ID is verified by reading the session metadata files under `~/.claude/projects/` (the canonical source for session identity). This prevents Capacitor from mistaking a different Claude session that was manually started in the same tab for the project orchestrator.
- **Supporting:** Hook heartbeat. Recent hook events confirm the session is actively working, but their absence does not imply the session is dead.

**Enforcement rules:**
- When the user clicks a project card, Capacitor checks for an existing orchestrator record.
- If a record exists, Capacitor runs the liveness probe: check that the terminal tab is open, a `claude` process is in its process tree, AND the process's session ID matches the stored orchestrator record.
- If all three checks pass → route to it (reconnect).
- If a `claude` process exists but the session ID doesn't match (user started a different session in the same tab) → the orchestrator is stale. The existing session is left alone (it's the user's manual session). Clear the orchestrator record and launch a new orchestrator in a new tab.
- If the tab is open but no `claude` process (user exited Claude, sitting at a shell prompt) → the orchestrator is stale. Clear the record and launch a new one in the same tab with a briefing that includes the previous session's context.
- If the tab is gone → the orchestrator is stale. Clear the record and launch a new one.
- If the user manually opens Claude Code in a project directory (outside Capacitor) → that session does not get MCP tools or the orchestrator briefing. It's just a regular Claude Code session. No conflict.

## Edge Cases

### Orchestrator crashes or is terminated
Workers that are actively running (live PID) continue executing — they're Capacitor's child processes, not the orchestrator's. Workers in `paused` state (awaiting input) remain paused with their conversation intact. When the user reopens the project card, Capacitor launches a new orchestrator with a briefing that includes all worker states. The new orchestrator picks up seamlessly using worker session IDs.

### Worker needs input but orchestrator is gone
The worker's `claude -p` process completes (it reached a point where it wrote a milestone and needs input). Its status transitions to `paused`. Capacitor detects the milestone via FSEvents and surfaces it in the UI. When the user reopens the project, the orchestrator's briefing includes the pending question.

### Worker process crashes mid-execution
Capacitor detects the stale PID on its next reconciliation pass. The worker's `session_id` is still valid — the conversation can be resumed via `--resume`. Capacitor marks the worker as `failed` and includes it in the orchestrator's briefing for a retry decision.

### Capacitor restarts
Capacitor reads `runtime/registry.json`, checks each PID with `kill -0`. Live PIDs are reconnected via hooks. Stale PIDs are reconciled per the Worker Identity Model recovery rules. Session IDs are preserved for resumption.

### Worker goes off the rails
Detected via orchestrator's periodic status checks (rich activity signals from `capacitor_worker_status`). Orchestrator recommends action to the user. Workers run in git worktrees, so damage is isolated — inspect, cherry-pick, or discard.

## Worker Identity Model

A worker has two distinct identities that follow different lifecycle rules:

- **Conversation identity** (`session_id`) — Durable. Survives process exits. Can always be resumed via `claude -p --resume $session_id` to continue the conversation in a new process. This is the worker's primary identity.
- **Process identity** (`pid`) — Ephemeral. Valid only while a `claude -p` invocation is actively running. When the agent loop completes, the process exits and the PID becomes stale. A resumed conversation gets a new PID.

**Lifecycle states:**

| State | session_id | pid | Meaning |
|---|---|---|---|
| `running` | valid | valid, live process | Worker is actively executing |
| `paused` | valid | stale (process exited) | Worker completed a run, awaiting resume (e.g., waiting for user input) |
| `completed` | valid | stale | Worker finished its task successfully |
| `failed` | valid | stale | Worker exited with an error |
| `killed` | valid | stale | Retired — process terminated (if running) or conversation abandoned (if paused). Not resumable. |

**Recovery rules:**
- If `pid` is live → worker is actively running, monitor via hooks
- If `pid` is stale but `status` is `running` → worker crashed mid-execution. Capacitor marks it `failed` and includes it in the next orchestrator briefing for decision (retry via `--resume` or abandon)
- If `status` is `paused` → worker can be resumed with new input via `--resume`
- `session_id` is always the resumption key, never `pid`

**Implication for `capacitor_send_message`:** This tool resumes the worker's conversation in a new process. The new PID is captured and the registry is updated. The previous PID is irrelevant.

## Worker Isolation via Git Worktrees

Every worker runs in its own git worktree, created by `capacitor_spawn_worker`. This is a first-class architectural decision, not just an edge case mitigation:

- **No conflicting edits.** Workers cannot modify each other's files because they each have an independent working tree. Merge conflicts are resolved at integration time (worktree merge back to main branch), not during concurrent execution.
- **Damage containment.** A worker that goes off the rails only affects its own worktree. Kill it, inspect the worktree, cherry-pick good work or discard entirely.
- **Clean integration.** When a worker completes, the orchestrator (or user) reviews the diff and merges the worktree branch. This is standard git workflow — no custom merge tooling needed.

## Cost Controls

- **Max concurrent workers:** Configurable per-project, default 3. `capacitor_spawn_worker` returns an error if the limit is reached.
- **Headless option-generation calls:** Capped at 1 concurrent per project. These are short-lived and focused — if one is already running for a milestone, the next milestone queues.
- **No automatic retry.** If a worker or headless call fails, Capacitor reports the failure. The orchestrator or user decides whether to retry.

## Milestone Review Page

The milestone review page is a **local web page served on a separate port from the runtime service** (e.g., port 7475). This is a deliberate trust boundary: the existing runtime service on port 7474 exposes authenticated `/runtime/*` endpoints, while the milestone review page renders worker-produced content that should be treated as untrusted input. Serving them on separate origins prevents worker-authored HTML/JS from accessing the runtime API.

The review page renders milestone content using standard web technologies:
- Markdown → rendered HTML (sanitized)
- Images → gallery/lightbox
- HTML prototypes → sandboxed iframe (`sandbox="allow-scripts"`, no `allow-same-origin`)
- Video → native video player

The page is intentionally simple — it's a viewer with action buttons, not an application. It reads the milestone directory contents and `actions.json` to render. Capacitor serves it; the browser renders it. Worker-produced HTML artifacts are always rendered in sandboxed iframes to prevent script injection into the review page itself.

## Non-Goals

- **Cross-project orchestration.** Each project has its own orchestrator. A meta-orchestrator that coordinates across projects is a future consideration, not part of this design.
- **CI/CD management.** The orchestrator can read CI status (via `capacitor_project_status`) but does not trigger builds, manage pipelines, or auto-merge PRs.
- **Custom editor integration.** Capacitor routes to terminals. It does not embed an editor or compete with VS Code / Cursor.
- **Cloud/remote execution.** All execution is local. Workers are local processes, the filesystem is local (with optional cloud sync for state files).

## Inbox Response Format

When the user makes a decision via the milestone review page, Capacitor writes a response file to the worker's `inbox/` directory:

```markdown
## Decision
Option A — Approve the tabbed layout

## Notes
Make sure the tabs are keyboard-navigable. Also add a "recently used" section.

## Context
- Action ID: approve-tabbed
- Milestone: 01
- Decided at: 2026-03-15T14:32:00
```

The response file is written to the worker's `inbox/` for durable record-keeping. The decision is actively relayed to the worker via `capacitor_send_message` (which uses `claude -p --resume`) — workers do not poll or watch their inbox directory, since headless `claude -p` sessions do not have file-watching capability. The inbox files serve as the audit trail and recovery mechanism (if a worker needs to be restarted, the decisions are on disk). The `## Decision` header is required; `## Notes` and `## Context` are optional.

## Worker Briefing Convention

Workers are headless `claude -p` sessions. Their briefing (passed as the prompt) must include instructions for self-reporting and milestone production. Capacitor assembles this from the orchestrator's request plus standard boilerplate:

```markdown
# Task
{{task description from orchestrator}}

## Reporting

Write progress updates to `status.md` in your working directory. Keep it short —
what you've done, what you're doing next, any blockers.

When you reach a significant checkpoint or need user input, create a milestone
directory at `milestones/NN/` containing:
- `brief.md` — what was done, what decision is needed (if any)
- `artifacts/` — any files for review (docs, images, prototypes)

Update `status.md` whenever your focus shifts to a new sub-task.

## Constraints
{{allowed tools, scope boundaries, files to avoid}}

## Project Context
{{relevant excerpts from memory.md and tasks.md}}
```

The worker's code changes happen in its git worktree (inside the repo). Reporting files (`status.md`, `milestones/`) are written to absolute paths that Capacitor passes in the briefing — specifically `~/.capacitor/projects/{name}/workers/{worker_id}/`. This separates orchestration metadata from code changes. Capacitor watches this directory via FSEvents and uses the reporting files to populate `capacitor_worker_status` responses and trigger milestone mode.

## Runtime Registry Schema

`runtime/registry.json` tracks active worker processes. Schema per worker record:

```json
{
  "worker_id": "w-abc123",
  "session_id": "ses-xyz789",
  "pid": 54321,
  "worktree_path": "/path/to/repo/.capacitor/worktrees/w-abc123",
  "base_commit": "a1b2c3d4",
  "project": "capacitor",
  "briefing_ref": "workers/w-abc123/briefing.md",
  "spawned_at": "2026-03-15T10:32:00Z",
  "status": "running"
}
```

On startup, Capacitor reads this file and reconciles per the Worker Identity Model: live PIDs are reconnected, stale PIDs with `running` status are marked `failed` (crash recovery), and session IDs are always preserved for potential resumption. The `base_commit` field enables clean diff/merge review when a worker completes.

## Open Questions

- How the orchestrator's proactive suggestions improve over time (learning from user patterns)
