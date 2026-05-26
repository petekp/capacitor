# Work Batch Task Delivery Policy

Status: recommendation
Audience: Capacitor maintainers
Scope: newly added Tasks entering an existing Capacitor Work Batch Claude Code session
Date: 2026-05-25

## Decision

Use a hybrid delivery model:

1. Capacitor owns the durable Task queue and Work Batch state.
2. The generated Work Batch Context Mirror tells Claude Code what the current queue is.
3. Claude Code proves pickup by writing a narrow Task claim/status artifact before it starts a queued Task.
4. Capacitor uses resumes or wakeups only as delivery nudges, not as the source of truth.
5. Capacitor does not inject arbitrary text into a live running Claude Code terminal by default.

Plain version: when the user adds a related Task, Capacitor should put it into the right batch immediately and make it visible immediately. It should not pretend the worker is already doing that Task until Claude Code has acknowledged it. Prompts can wake the worker up, but the queue and callback artifacts are what make the system reliable.

## Source-Backed Current Behavior

| Area | Current behavior | Evidence | Product implication |
| --- | --- | --- | --- |
| Product language | A Task is actionable and should enter execution as soon as captured. Checkpoints are the safeguard, not a routine preflight. | `CONTEXT.md:7`, `CONTEXT.md:15`, `CONTEXT.md:127` | The UX should bias toward action while preserving model discretion and checkpoint alignment. |
| Non-disruptive delivery | Adding a Task to an active Work Batch should update context without forcing interruption unless the worker/session/trust boundary calls for it. | `CONTEXT.md:115` | A live running Claude session should not receive surprise input just because a related Task was added. |
| Work Batch ownership | A Work Batch is the related execution lane; a Task Session is bound to one Work Batch; the Batch Worktree isolates that lane. | `CONTEXT.md:71`, `CONTEXT.md:119`, `CONTEXT.md:123` | Delivery should target the batch, not the whole project or an inferred terminal. |
| Routing entrypoint | `routeCapturedTask` serializes routing turns, creates the new Task as `.queued`, classifies it, reapplies state after classifier latency, and persists the route. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:108`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:127`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:156`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:176`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:198` | Capture is already automatic and race-conscious enough to support queue-first delivery. |
| Existing binding path | If a binding exists, Capacitor rewrites `.capacitor/work-batch-context.md`, blocks on duplicate cockpit issues, resumes only some existing bindings, and returns without starting a new session. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:211`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:230`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:238`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:262` | Related Tasks can join an existing batch today, but healthy running sessions are not proactively notified. |
| Resume policy | Existing bindings resume only when `.stale`, `.waiting`, or `.done`; `.launching` and `.running` do not resume from the router. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:852` | This avoids duplicate running sessions, but it also leaves running-session pickup to the mirror and prompt discipline. |
| Context mirror | The mirror tells Claude Code to use it as current Work Batch context, lists Tasks, and defines Done and Checkpoint callback file paths. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:119`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:139`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:141`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:150` | The mirror is the right agent-readable bridge, but it currently has no pickup/claim callback. |
| Launch and resume | New sessions launch with a Capacitor-assigned `--session-id`; existing sessions can be resumed with `--resume <sessionID>` and a resume prompt. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:226`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:252`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:264`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:393`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:478` | Resume is a good recovery primitive when the exact live cockpit is not running. It is not a safe default for every new related Task. |
| Open existing cockpit | Running or launching bindings focus the existing terminal before resume; stale, waiting, or done bindings skip focus and resume. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:461`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:490` | The code already distinguishes re-entry from recovery; delivery should preserve that distinction. |
| Initial/resume prompt | The initial prompt says to read the mirror, start queued Tasks, write Done or Checkpoint reports, re-read before idle/done, and bias toward action. The resume prompt asks Claude to re-read and continue queued/reopened/answered work. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:517`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:521` | Prompt discipline is present, but there is no machine-readable acknowledgement that the prompt was obeyed. |
| Binding reconciliation | The reconciler matches live sessions inside the batch worktree, requires exact session id for healthy binding, marks duplicate same-worktree sessions waiting, marks missing cockpits stale/waiting, and requeues unfinished work when needed. | `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:35`, `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:46`, `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:65`, `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:90`, `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:238` | We have enough structure to recover stale bindings without broad runner behavior. |
| Visible batch projection | Work Batch projection exposes status, queued count, current summary, tasks, checkpoints, and binding. Pending checkpoints win the primary open action before the cockpit. | `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:315`, `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:350`, `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:375` | The UI can show "queued behind current work" and checkpoint-first interruption without new product surface. |
| Callback coverage | Done reports and checkpoint requests/responses are JSON files in `.capacitor` directories inside the batch worktree. | `apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:93`, `apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:118`, `apps/swift/Sources/Capacitor/Models/WorkBatchCheckpointExchange.swift:3`, `apps/swift/Sources/Capacitor/Models/WorkBatchCheckpointExchange.swift:30`, `apps/swift/Sources/Capacitor/Models/WorkBatchCheckpointExchange.swift:122` | The existing callback pattern is narrow and local. Task pickup should use the same pattern. |
| Runtime liveness | Runtime sessions expose session id, pid, cwd/project path, state, activity timestamps, tools in flight, GC reason, and `is_alive`. | `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:478`, `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:814` | Capacitor can distinguish stale/missing/duplicate/possibly idle sessions, but it still lacks a safe generic way to inject into a live prompt. |
| Classification bet | Model-backed classification is accepted; deterministic rules are fallback and guardrails. | `docs/architecture-decisions/006-model-backed-work-batch-classification.md:1` | The delivery policy should assume related Tasks often join existing batches, so pickup semantics matter. |

## Highest-Risk Ambiguity

The dangerous ambiguity is whether "send another prompt into the session" is the queueing mechanism.

It should not be.

The prompt is a wakeup. The queue is the queue. If the prompt is the only delivery mechanism, we get brittle behavior:

- A live Claude session may be in the middle of tool use, editing, or user conversation.
- A `claude --resume` against a live session may create another visible cockpit or confusing state.
- Terminal input injection can land in the wrong place, collide with user typing, or depend on app-specific focus rules.
- Capacitor cannot tell whether Claude saw the new Task unless there is a callback.

Decision: adding a related Task means the Task is durably queued in the Work Batch and visible in Capacitor. It becomes "working" only after Claude Code proves pickup with a claim/status artifact.

## Realistic Scenario Map

| Scenario | Intended behavior | Why |
| --- | --- | --- |
| New unrelated Task, no fitting batch | Create a new Work Batch, new Batch Worktree, and new Claude Code Task Session. | This preserves independent context and avoids mixing unrelated work. |
| Related Task added while the bound Claude session is running | Append the Task to the existing batch, rewrite the mirror, show it as queued, and do not create or resume another session. | This keeps the user experience seamless without causing session sprawl. |
| Related Task added while the bound session is idle or awaiting input | Append and rewrite first; then use a safe wakeup policy only if Capacitor can prove the exact bound session is at an input boundary. | Waking is useful, but only after durable state exists. |
| Related Task added while the bound session is stale, waiting, or done with open Tasks | Append, rewrite, and resume `claude --resume <stored session id>` in the Batch Worktree. | Resume is the right recovery tool when there is no healthy live cockpit. |
| Related Task added while a checkpoint is pending | Append the Task, keep the batch waiting, and keep primary open action checkpoint-first. | Checkpoints are the alignment safeguard; new work should not hide them. |
| User manually opens the Claude cockpit and types instructions | Treat this as normal steering inside the same Work Batch. The Task remains open until claim/done/checkpoint status says otherwise. | There should be no visible "manual takeover" mode. |
| Claude writes Done for one Task while other Tasks remain queued | Mark the completed Task done, keep the batch active, rewrite the mirror, and apply delivery policy to the remaining queued Tasks. | Completion of one Task should not make the batch look finished. |
| Two Claude sessions exist in the same Batch Worktree | Mark the batch waiting with a duplicate-cockpit reason; do not choose silently. | Silent adoption can corrupt the user's mental model and the worktree. |
| A manual Claude session exists in the project root | Do not silently bind it to a Work Batch. Start managed work in a Batch Worktree. | Root sessions lack batch context, batch isolation, and assigned session id. |
| Worktree or mirror write fails | Keep the Task open and the batch waiting with a recovery reason. | The user should see the failure rather than lose the Task. |
| No pickup claim arrives after the session becomes safe to wake | Nudge once using the safe policy; if there is still no claim, show waiting/recovery rather than claiming progress. | This is the line between automation and pretending. |

## Approach Ledger

| Approach | How it works | Strength | Failure mode | Verdict |
| --- | --- | --- | --- | --- |
| Durable queue only | Append Tasks to canonical state and mirror; rely on Claude to re-read before idle/done. | Safest against duplicate sessions and wrong-terminal input. | Running workers may not notice new Tasks promptly. No pickup proof. | Keep as foundation, insufficient alone. |
| Always prompt wakeup | Send a new prompt for every added related Task. | Feels immediate when it works. | Interrupts active work, can race with user input, may produce duplicate resumes, and makes prompt delivery the source of truth. | Reject as default. |
| Resume-based nudge | Use `claude --resume <session id>` with a short prompt after queueing. | Good for stale, waiting, done, or missing live cockpits. Uses Claude's session continuity. | Risky for healthy live sessions because it can create another cockpit or confuse state. | Use only at recovery or clearly safe boundaries. |
| Terminal injection | Send text directly into the visible terminal or tmux pane. | Maximum immediacy. | Wrong target, user typing collisions, app-specific automation, and no guaranteed Claude prompt boundary. | Defer. Only consider later behind exact-session and input-boundary proof. |
| Claim/status artifact | Claude writes a small JSON file when it starts a queued Task. | Gives Capacitor positive pickup proof and clean card summaries. Fits existing Done/Checkpoint artifact pattern. | Requires prompt compliance; malformed claims need validation. | Adopt. This is the missing contract. |
| Done/checkpoint callbacks only | Use existing Done and Checkpoint JSON files. | Already implemented and narrow. | They describe block/end states, not pickup or current work. | Extend with claim/status; do not overload Done/Checkpoint. |
| Callback/report protocol | Define a small family of local JSON callbacks: claim, checkpoint, done. | Clear, local, auditable, compatible with manual cockpit use. | Could drift into broad runner protocol if overdesigned. | Adopt narrowly for Claude Code Work Batches only. |
| Headless runner/flow engine | Capacitor directly executes and schedules each Task. | Centralized control. | Violates the slice, replaces the cockpit, and creates too much product surface too early. | Explicit non-goal. |

## Recommended Protocol

### Canonical State

Canonical Work Batch state stays under `~/.capacitor`. The Work Batch Context Mirror remains an agent-readable mirror inside the Batch Worktree. The mirror should stop calling itself the source of truth and instead say it is the current agent-readable view of Capacitor's canonical state.

### Task Claim Artifact

Add a narrow Task claim/status artifact:

Path:

```text
.capacitor/work-batch-claims/<task-id>.json
```

Shape:

```json
{
  "task_id": "<task-id>",
  "status": "working",
  "summary": "what I am doing now",
  "claimed_at": "2026-05-25T12:00:00Z",
  "context_updated_at": "2026-05-25T12:00:00Z",
  "delivery_generation": "batch-id:2026-05-25T12:00:00Z"
}
```

Rules:

- A claim is valid only when `task_id` belongs to the bound Work Batch.
- `status` must be `working` for the first slice.
- Empty summaries are allowed but should not replace better Capacitor summaries.
- Claims for done or needs-you Tasks are ignored unless the Task was reopened.
- Stale claims are ignored. A claim is stale when `claimed_at` is older than the current Task `updatedAt`, or when `delivery_generation` does not match the current mirror generation if that field is present.
- Invalid or malformed claims are ignored and logged, not surfaced as user errors.
- A valid claim moves the Task from `.queued` to `.working` and can update the batch current activity summary.
- Claims are not completion. The Done report remains the completion callback.

### Delivery State

Add a small delivery watermark to canonical state or the binding record:

- `last_context_written_at`
- `last_delivery_generation`
- `last_delivery_attempt_at`
- `last_delivery_attempt_kind`
- `last_claim_at`

This is not a job scheduler. It is the minimum bookkeeping needed to avoid repeated prompts, ignore stale claim files, and explain the visible state. The same generation should be written into the mirror and accepted in Task claims.

### Mirror Instructions

The Work Batch Context Mirror should add:

- "Before starting a queued Task, write the Task claim described below."
- "If you manually receive user instructions in this Claude session, still keep this file's Tasks in mind and use claim/checkpoint/done artifacts so Capacitor can stay in sync."
- "Before saying the batch is idle or done, re-read this file and pick up any queued Tasks."

### Delivery Policy

Add a small pure policy layer, not a runner:

Inputs:

- Batch status and tasks.
- Batch Cockpit Binding status.
- Binding reconciliation issues.
- Exact live runtime session state, when available.
- Whether the context mirror was successfully written.
- Delivery generation and last delivery attempt, when available.
- Claim age and queued Task age.

Outputs:

- `recordQueuedOnly`: mirror updated; live running session should not be disturbed.
- `resumeExistingSession`: run `claude --resume <stored session id>` in the Batch Worktree with the resume prompt.
- `waitForCheckpoint`: keep checkpoint-first behavior.
- `waitForDuplicateCockpit`: show duplicate session recovery.
- `waitForDeliveryFailure`: mirror/write/recovery failed.
- `safeWakeDeferred`: queued work exists, but no safe delivery boundary yet.

Initial policy:

| Condition | Action |
| --- | --- |
| Mirror write failed | Mark waiting and keep Task queued. |
| Pending checkpoint exists | Mark waiting and open checkpoint first. |
| Duplicate same-worktree sessions exist | Mark waiting with duplicate-cockpit reason. |
| No binding exists | Start a new batch session. |
| Binding is stale/waiting/done and open Tasks exist | Resume stored session id in Batch Worktree. |
| Binding is launching/running and exact live session exists | Queue only; wait for claim/done/checkpoint or later safe boundary. |
| Binding is running but exact live session is missing after grace | Mark stale and resume stored session id. |
| Done report arrives while queued Tasks remain | Mark reported Task done, rewrite mirror, run delivery policy for remaining queued Tasks. |

Later safe wake extension:

- If runtime says the exact bound session is alive, in the Batch Worktree, not using tools, and waiting at an input boundary, Capacitor may send a short wakeup.
- That extension needs its own proof because it depends on terminal/session targeting. It should not be implemented by generic terminal injection first.

### User-Facing Copy

Capacitor should be honest about state:

- Related Task just added to active batch: `Queued <Task> in <Batch>.`
- Claimed Task: `Working on <Task>.`
- Active work plus queue: `Working on <Task>. 1 queued.`
- Stale but recoverable: `Claude Code session needs reconnect.`
- Duplicate cockpit: `Multiple Claude Code sessions match this Work Batch.`
- No claim after safe retry: `Worker has not picked up the queued Task yet.`

This preserves the simple batch-card UX: name, status, queued count, and what is currently happening.

## Prioritized Implementation Plan

### P0: Add Task Claim Callback

Implement:

- `WorkBatchTaskClaim` and `WorkBatchTaskClaimStore`.
- `.capacitor/work-batch-claims` metadata ignore handling, matching Done/Checkpoint stores.
- Claim ingestion in the Work Batch refresh/reconciliation path.
- Delivery generation/watermark storage for claim freshness and retry suppression.
- Valid claim moves queued Task to working and refreshes current activity summary.
- Mirror documents claim path and JSON.

Acceptance:

- A valid claim for a queued Task marks only that Task `.working`.
- A malformed claim is ignored without crashing.
- A claim for a Task outside the batch is ignored.
- A stale claim from before the latest Task update or mirror generation is ignored.
- A claim does not mark a Task done.
- Existing Done and Checkpoint tests still pass.

### P0: Extract Delivery Policy

Implement:

- A pure `WorkBatchDeliveryPolicy` with fixture-style tests.
- The router calls the policy after writing state and mirror.
- Existing `.stale`, `.waiting`, and `.done` resume behavior is expressed through the policy.
- Healthy `.running` bindings with exact live sessions do not launch or resume.
- Delivery attempts update the watermark so the same queued Task is not nudged repeatedly.

Acceptance:

- Related Task into healthy running batch: no new worktree, no new Claude process, mirror updated, queued count increments.
- Related Task into stale batch: `claude --resume <stored session id>` in the Batch Worktree.
- Duplicate cockpit issue: batch becomes waiting with clear reason.
- Pending checkpoint: primary open action remains checkpoint-first.
- Repeated refreshes do not send repeated resume/wakeup attempts for the same delivery generation.

### P0: Follow-Through After Done, Checkpoint, And Unresolve

Implement:

- After ingesting Done, if other Tasks remain queued, rewrite mirror and run delivery policy.
- After checkpoint response, rewrite mirror and run delivery policy.
- After Unresolve, rewrite mirror and run delivery policy.

Acceptance:

- Done for Task A does not idle the batch while Task B is queued.
- Answering a checkpoint resumes or wakes the same batch session when safe.
- Unresolving a Task makes it queued and visible in the same batch.

### P1: No-Claim Watchdog

Implement:

- Track `queued_at`, `last_context_written_at`, `last_delivery_attempt_at`, and `last_claim_at` for a batch or task.
- If a Task has been queued through a safe boundary and no claim appears for the current delivery generation, nudge once through the safe policy.
- If the nudge fails or no claim appears after the retry window, mark the batch waiting with plain copy.

Acceptance:

- Capacitor does not repeatedly spam resumes or prompts.
- The user can see "not picked up yet" instead of a false working state.
- Manual cockpit use still works: if Claude later writes a claim or Done report, Capacitor recovers.

### P1: Safe Wake Boundary

Implement only after the policy and claim artifacts are in place:

- Use runtime exact-session state, `toolsInFlight`, last event/activity, and liveness to decide whether a session is at a safe input boundary.
- Do not use generic terminal injection unless the exact target and input boundary are proven.
- Prefer Claude resume only when the exact live process is absent/stale; prefer no-op plus visible queue when it is actively running.

Acceptance:

- No new Ghostty window or tmux session appears for a healthy visible batch cockpit.
- A stale binding reconnects in the Batch Worktree.
- A live active session is not interrupted mid-tool.

### P1: UI Honesty And Manual Test Script

Implement:

- Batch card copy from claim state rather than stale route summary where available.
- Manual test plan for two related typography Tasks in one project.
- Manual test plan for unrelated Tasks creating separate batches.
- Manual test plan for stale binding resume and duplicate cockpit detection.

Acceptance:

- Adding a second related Task shows the same batch with queued count incremented.
- Opening the batch focuses the existing Claude Code cockpit, not a new unrelated Ghostty window.
- When Claude claims the queued Task, the summary changes to "Working on..."
- When Claude writes Done, the Task becomes Done and Unresolve can reopen it.

## Concrete Next Slice

The next code slice should be P0 Task Claim Callback plus P0 Delivery Policy extraction.

Do not start with terminal injection. It is tempting because it feels immediate, but it solves the wrong layer first. The reliable base is: queue, mirror, claim, done, checkpoint, and narrowly scoped resume/recovery.

This is robust because Capacitor can survive manual intervention, app restarts, stale sessions, and missed prompts without losing the user's Task. It is intuitive because the user only sees batches, queued counts, checkpoints, and completion. It is honest because the UI never claims a Task is being worked until the worker says so.
