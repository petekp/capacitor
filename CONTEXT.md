# Capacitor

Capacitor is a local-first operator surface for steering coding agents through actionable work, checkpoints, and completion.

## Language

**Task**:
An actionable work item captured by the user for Capacitor to execute and manage. A Task is expected to enter execution as soon as it is captured unless Capacitor can tell it is not actionable. "Idea" may appear in older surfaces or code, but the product language should prefer Task because the captured item is expected to move toward execution.
_Avoid_: Idea, note, prompt

**Starting**:
The brief state after a Task is captured while Capacitor chooses and begins the appropriate execution path.
_Avoid_: Queued, pending triage

**Checkpoint**:
A focused interruption where Capacitor asks the user for direction because continued action would be risky, blocked, or meaningfully ambiguous. Checkpoints are the safeguard for action-biased execution, not a routine preflight step.
_Avoid_: Confirmation, form, questionnaire

**Checkpoint Request**:
The narrow callback a Claude Code Task Session writes when it cannot safely or usefully continue without user input. Capacitor ingests the request, marks the Task as Needs You, and presents the question in the Work Batch surface.
_Avoid_: Preflight question, blocking form, generic approval

**Checkpoint Response**:
The user's answer to a Checkpoint Request, written back into the Work Batch Context so the same Task Session can continue with the user's steering.
_Avoid_: Separate chat, detached note, manual terminal-only reply

**Project**:
The stable repository or workspace wrapper for Work Batches. For now, Project Detail should stay simple: a Project shows its Work Batches and their Tasks.
_Avoid_: Primary card, session, task group

**Operator Control Plane**:
Capacitor's product role: the surface that governs Tasks, attention, checkpoints, decisions, completion, and re-entry across agent sessions. It coordinates agent work without trying to replace every native agent interface.
_Avoid_: Replacement IDE, agent clone, dashboard

**Agent Cockpit**:
The native agent surface where a user can directly drive an agent, such as a CLI session or agent app. Opening or using the Agent Cockpit should not create a separate user-facing mode; the Task remains the same Task, and Capacitor continues reflecting its status until it is Done or otherwise resolved.
_Avoid_: Backend, hidden implementation detail, manual takeover

**Claude Code Task Session**:
The first Agent Cockpit type supported by the Work Batch vertical slice: an interactive Claude Code session opened in the Batch Worktree with Work Batch Context available. Headless execution can exist later, but the first slice should prove the live cockpit path.
_Avoid_: Headless-only worker, print-only run

**Batch Cockpit Binding**:
The first-class record that identifies the Agent Cockpit for a Work Batch. Batch Cockpit Binding is distinct from Project-level terminal routing and should be used first when opening a Work Batch.
_Avoid_: Project route, inferred terminal guess, tmux-only binding

**Batch Cockpit Recovery**:
The fallback behavior when a Batch Cockpit Binding is stale. Capacitor should relaunch or reconnect Claude Code in the Batch Worktree with Work Batch Context, then update the binding.
_Avoid_: Opening an unrelated Project session, asking before retry

**Quiet Execution**:
The default Task experience where Capacitor starts and manages agent work without stealing focus or requiring the user to watch the Agent Cockpit. Quiet Execution must still provide an obvious way to open the Agent Cockpit when direct control is needed.
_Avoid_: Hidden execution, unattended mode, background magic

**Work Batch Context**:
The shared tracking context that lets a Work Batch know which Tasks it contains and how to report progress, checkpoints, and Done state back to Capacitor.
_Avoid_: Task-only context, separate checklist, side channel, hidden state

**Work Batch Context Mirror**:
A generated, agent-readable Work Batch Context file inside the Batch Worktree. Capacitor's canonical Work Batch state lives under `~/.capacitor`; the mirror makes the batch self-describing when opened in the Agent Cockpit.
_Avoid_: Canonical state, source of truth

**Batch Routing Slice**:
The first Work Batch product slice: add a Task, classify it into an existing or new Work Batch, show/update the Work Batch card, launch or reuse the batch's Claude Code Task Session with Work Batch Context, and open the correct Agent Cockpit from the card. Checkpoint semantics are outside this first slice.
_Avoid_: Full task platform, checkpoint-complete loop

**Done Report**:
The narrow callback a Claude Code Task Session writes when it believes a Task is Done. The first implementation uses a small JSON file in the Batch Worktree so Capacitor can mark the Task Done, refresh the Work Batch card, notify the user, and preserve Unresolve as the correction path.
_Avoid_: Approval gate, runner callback, broad task platform

**Work Batch**:
A contextually related group of Tasks that should share execution context. Work Batches are the primary cards on Capacitor's main surface; a card should show the batch name, the current card status, queued Task count, and a short summary of what is currently happening.
_Avoid_: Thread, loose session, workflow

**Work Batch Name**:
The visible, editable cognitive handle for a Work Batch. Capacitor may name or rename a Work Batch from its Tasks as the context evolves, while durable identity remains internal.
_Avoid_: Session id, branch name, project name

**Current Activity Summary**:
The short Work Batch card copy describing what is happening now. Prefer an agent-reported current activity summary, with Capacitor inference as a fallback.
_Avoid_: Static batch description, project description

**Work Batch Status**:
The visible status on a Work Batch card. Work Batch Status should reuse Capacitor's current card/session vocabulary: Ready, Working, Waiting, Compacting, and Idle.
_Avoid_: New status taxonomy, custom batch-only labels

**Idle Work Batch**:
A Work Batch with no currently open Tasks. Idle Work Batches may remain visible briefly or be findable later, and adding a Task can revive them.
_Avoid_: Completed batch, closed session, disappeared work

**Open Batch**:
The primary Work Batch card action. Opening a Work Batch should take the user to the bound Agent Cockpit, except when the batch is Waiting on a Checkpoint or recovery choice, in which case it should open the needed decision surface first.
_Avoid_: View details, inspect project, manage session

**Batch Classification**:
The decision that routes a newly captured Task into an existing Work Batch or starts a new Work Batch. Batch Classification should be inferred by Capacitor unless it needs user input.
_Avoid_: Method selection, manual routing, session picking

**Batch Classification Record**:
The inspectable result of Batch Classification. It should record whether the Task was added to an existing Work Batch or started a new one, the selected batch identity or proposed name, confidence, rationale, and a short user-visible summary.
_Avoid_: Hidden routing, untraceable model choice

**Classification Correction**:
The user action that fixes a Batch Classification after Capacitor routes a Task. Low-confidence classification should still act by default, with correction available after the fact unless routing would be genuinely harmful.
_Avoid_: Preflight routing dialog, classification approval

**Global Task Capture**:
The default way to add a Task without first choosing a Work Batch. Capacitor should classify the Task into a Project and Work Batch, or create a new Work Batch when no existing batch fits.
_Avoid_: Idea queue, inbox

**Batch Task Capture**:
Adding a Task while already inside a Work Batch. Batch Task Capture should append to that Work Batch unless Capacitor has a strong reason to suggest a different batch.
_Avoid_: New thread, new session by default

**Non-Disruptive Delivery**:
The default behavior when a Task is added to an active Work Batch. Capacitor updates the Work Batch Context immediately, but should not force an interruption unless the worker, session protocol, or Trust Boundary calls for it.
_Avoid_: Immediate interruption, surprise injection

**Task Session**:
An agent session bound to one Work Batch. A Task Session may be opened in the Agent Cockpit for direct steering, and any direct user input belongs to that Work Batch's active context.
_Avoid_: Manual takeover session, unrelated shared session

**Batch Worktree**:
The isolated git worktree used by one Work Batch. A normal Work Batch should get its own Batch Worktree so concurrent batches in the same Project do not silently overwrite each other.
_Avoid_: Shared checkout, main project checkout

**Model Discretion**:
The worker's authority to choose how to execute a Task and when to ask for a Checkpoint. Capacitor should preserve Model Discretion for ordinary work while enforcing broad trust boundaries that protect the user.
_Avoid_: Manual preflight, rigid workflow, step-by-step approval

**Trust Boundary**:
A user-trust limit where Capacitor should require or strongly prefer a Checkpoint before the worker continues. Trust Boundaries cover actions that are destructive, irreversible, externally costly, credential-sensitive, or likely to surprise the user.
_Avoid_: Preference, setting, method choice

**Done**:
The Task state where the worker claims completion and provides evidence. Done is trusted by default rather than approval-gated by default.
_Avoid_: Awaiting final approval, completed only after review

**Unresolve**:
The user action that reopens a Done Task when they disagree with the worker's completion claim or want follow-up changes. Unresolve is the safeguard that lets Capacitor trust worker completion without forcing review of every Task.
_Avoid_: Reject completion, dispute, fail

**Needs You**:
The Task attention state where Capacitor should interrupt because user input is required, usually through a Checkpoint or failure recovery choice.
_Avoid_: Important, urgent, active

**Recency Signal**:
A compact indication that a Work Batch changed, finished, stalled, or needs input since the user last looked. Recency should influence Field of Work ranking and card copy rather than become a separate "while you were away" report.
_Avoid_: Return Brief, dashboard, activity feed

**Field of Work**:
The main surface where Capacitor presents Work Batch cards. The Field of Work may use attention and recency to order or annotate cards, but it should stay simple rather than becoming a ceremony of summaries or visible status categories.
_Avoid_: Kanban board, project grid, session list
