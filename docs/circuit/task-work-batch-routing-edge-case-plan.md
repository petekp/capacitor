# Task-to-Work-Batch Routing Edge-Case Plan

Status: implementation plan
Audience: Capacitor maintainers
Scope: Capacitor-managed Tasks, Work Batches, batch worktrees, and Claude Code sessions
Date: 2026-05-25

## Product Stance

Adding a Task should start useful work without asking the user to understand execution plumbing.

The model is:

1. A Task is the user's unit of intent.
2. A Work Batch is an execution lane for related Tasks.
3. A Work Batch owns one managed worktree and one Claude Code cockpit.
4. Related new Tasks join the existing batch lane.
5. Unrelated new Tasks create separate visible batch lanes.
6. Manual user intervention is allowed, but Capacitor only cares whether the Task eventually gets finished or needs input.

This slice stays Claude Code only. It must not introduce old Circuit runtime, a runner or flow engine, a task DAG, broad memory, generalized multi-host routing, or SaaS workflow framing.

## Current Code Findings

| Area | Current behavior | Evidence | Product meaning |
| --- | --- | --- | --- |
| Capture starts routing | `captureIdeaHandler` saves the Task and immediately calls `startWorkBatchRouting`. | `apps/swift/Sources/Capacitor/Models/AppState.swift:204-211` | The main UX promise is already wired: saving a Task begins automatic routing. |
| Router serializes captures | `routeCapturedTask` takes a route turn before reading/writing state. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:43-55`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:197-216` | Concurrent captures should not overwrite each other. |
| Classification is model-backed | The classifier invokes Claude with `--print --model haiku`; the prompt tells it to choose existing vs new batch and to treat Task text as data. | `apps/swift/Sources/Capacitor/Models/WorkBatchClassifier.swift:39-48`, `apps/swift/Sources/Capacitor/Models/WorkBatchClassifier.swift:81-107` | This matches the accepted bet in `docs/architecture-decisions/006-model-backed-work-batch-classification.md`. |
| Existing batch context is persisted | Work Batch state and classifications are stored under the project data directory. | `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:194-233` | Batches survive app restarts, but state needs reconciliation with live sessions. |
| Bindings are per batch | `WorkBatchCockpitBindingStore` stores one binding per `batchID`. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:50-116` | Batch identity, not project identity, is the cockpit ownership boundary. |
| New batch launches a worktree session | New sessions create `.capacitor/worktrees/<batch>`, launch Claude with assigned `--session-id`, and persist a binding. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:330-383` | This is the right long-term shape: batch-specific worktree plus deterministic session id. |
| Existing binding is reused | If a batch binding exists, the router writes the context mirror and does not start a new session. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:112-149` | Related Tasks can join a batch without session sprawl. |
| Stale/waiting/done bindings resume | Router resumes existing bindings only for `.stale`, `.waiting`, or `.done`. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:229-236` | Relaunch/reconnect is already the default for stale batch cockpits. |
| Running bindings focus before resume | Opening a running or launching cockpit first tries to focus the visible terminal, falling back to `claude --resume` only if focus fails. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:400-430` | This reduces duplicate-session creation, but focus failure can still create a second process. |
| Batch context mirror exists | The generated `.capacitor/work-batch-context.md` tells Claude to read current Tasks and ask for checkpoints only when needed. | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:119-172`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:447-449` | This is the manual-intervention bridge and the main durable handoff artifact. |
| Worktrees are managed under the repo | `WorktreeService` creates managed worktrees under `.capacitor/worktrees` with a `pkp/<worktree>` branch. | `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift:151-177` | The batch worktree is intentionally local and project-owned. |
| Runtime sessions expose cwd and liveness | Runtime snapshot sessions map `session_id`, `pid`, `cwd`, `project_path`, `workspace_id`, state, activity, and `is_alive`. | `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:478-504`, `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:814-860` | The data needed for binding reconciliation mostly exists. |
| Project detail shows batches | Project detail renders `WorkBatchListSection`; clicking a batch opens the cockpit. | `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift:39-45` | The first visible batch-card surface exists. |
| Batch rows show core state | Batch rows show status, name, queued count, summary, and the first four Tasks. | `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift:7-83` | Good enough for the first slice, but not yet a full top-level work landscape. |
| Project cards prefer Work Batch summary | Project cards pass `workBatchSummary` and resolve it ahead of legacy session summary. | `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:478-485`, `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardContextLineResolver.swift:45-54` | This prevents legacy session summaries from winning, but it does not by itself prove the chosen Work Batch summary is fresh or related. |
| Batch summaries can still be stale or wrong | Existing-batch routing writes `Added <task title>.`, new-batch routing writes `Starting <task title>.`, and projection only repairs placeholder summaries containing `...`. | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:253-289`, `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:293-317`, `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:276-298` | If the card says unrelated work, the likely failure is wrong batch selection, stale persisted batch summary, or card priority among multiple active batches. The next slice must make this inspectable and testable. |
| Manual session matching already considers managed worktrees | Ghostty matching refuses to treat two different managed worktrees as equivalent. | `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift:872-902` | This supports batch-specific cockpit routing. |

## Highest-Risk Unhandled Edge Case

The riskiest gap is delivery into an existing healthy running batch.

Current behavior:

- A related Task classified into an existing running batch updates `state.json`.
- It writes the latest Tasks to `.capacitor/work-batch-context.md`.
- It does not start a new session.
- It does not safely notify the live Claude session.
- The initial prompt asks Claude to re-read the mirror before declaring the batch idle or done.

That is defensible as a queue, but not yet strong enough for the UX promise that adding a Task causes execution. A running worker may not notice the newly queued Task until much later.

Intended behavior:

- If the bound Claude session is actively working, Capacitor should not start a duplicate session.
- The Task should become visibly queued in the batch and the batch summary should say it was added.
- If the session reaches an input-ready, idle, stale, or done boundary, Capacitor should resume or nudge the same batch cockpit in the batch worktree.
- If Capacitor cannot prove safe delivery, the batch should become `waiting` with a plain reason, not silently pretend the Task is being worked.

The next implementation slice should therefore be binding reconciliation plus delivery policy, not a broader runner.

## Routing Policy

### New Task With No Related Batch

Policy:

- Create a new Work Batch.
- Create a new managed worktree for that batch.
- Launch Claude Code in that worktree with a Capacitor-assigned session id.
- Show a visible batch row immediately.

Acceptance:

- New unrelated Tasks create separate batches.
- Each batch has a distinct `batchID`, worktree path, branch, context mirror, and Claude session id.
- The project card summary names the newest active batch work, not stale legacy session activity.
- If worktree or launch fails, the Task remains open and the batch becomes `waiting` with a clear recovery action.

### Related Task With Healthy Running Binding

Policy:

- Append the Task to the existing batch.
- Rewrite the context mirror.
- Do not create another Claude process while a live bound session is running.
- Mark the Task as queued until pickup is proven.
- Show "Added <Task>" or "Queued <Task> in <Batch>" rather than claiming the worker is already doing it.

Acceptance:

- No second worktree is created.
- No second Claude session is launched.
- Batch row queued count increments.
- The mirror contains all active Tasks.
- A later reconciliation pass can see the live session and decide whether a safe pickup nudge is needed.

### Related Task With Stale, Waiting, Or Done Binding

Policy:

- Reuse the existing batch and worktree.
- Rewrite the context mirror.
- Resume Claude with the stored `claudeSessionID` in the batch worktree.
- If resume fails, keep the batch visible as `waiting` and keep all unfinished Tasks queued.

Acceptance:

- The resume command uses `--resume <stored session id>`.
- The working directory is the batch worktree.
- No new batch is created for the same related work.
- The UI says reconnect/resume is needed if launch fails.

### Pre-Existing Manual Claude Session In Project Root

Policy:

- Do not silently bind it to a new Work Batch.
- It may inform project-level summaries or classification context later.
- New Capacitor-managed execution still gets a batch worktree and batch session.

Rationale:

Manual root sessions do not have a batch context mirror, batch worktree isolation, or a known Capacitor-owned session id. Auto-adopting them would make the user feel "seamless" briefly but would blur ownership and make duplicate/overlap bugs harder to explain.

Acceptance:

- A root manual session does not prevent creation of a managed batch for a new Task.
- The batch card remains the primary place to open the managed cockpit.
- Manual root work can resolve Tasks only through an explicit future callback or Task status update, not hidden inference.

### Pre-Existing Manual Claude Session In A Batch Worktree

Policy:

- If it is in the exact managed worktree and matches the stored Claude session id, reconcile it as the batch cockpit.
- If it is in the exact managed worktree but has a different Claude session id, mark possible duplicate instead of silently adopting.
- If there is no binding yet but the worktree has the context mirror and only one live Claude session, adoption can be offered later, but should not be part of the next slice.

Acceptance:

- Exact binding match becomes `running`.
- Different session id in the same worktree becomes `waiting` or exception with "possible duplicate cockpit".
- No arbitrary root or sibling worktree session is adopted.

### User Manually Intervenes In The Bound Batch Session

Policy:

- Intervention is normal.
- Capacitor should continue to show the batch, session state, and queued Tasks.
- If the agent finishes, Capacitor needs a narrow way to mark Tasks done.
- Until that exists, Tasks remain open unless the user manually resolves them.

Acceptance:

- Stopping, resuming, or typing in the bound Claude session does not detach the batch.
- If the session remains live in the batch worktree, the binding stays healthy.
- If the session disappears, the batch becomes stale/waiting and can be resumed.

### Duplicate Or Overlapping Sessions

Policy:

- One batch should have at most one active Claude cockpit.
- Capacitor should prefer the stored binding's exact session id in the exact batch worktree.
- Extra sessions in the same worktree should be treated as suspicious.
- Sessions in different managed worktrees should never be merged by shared repo identity.

Acceptance:

- Reconciliation flags duplicate same-worktree sessions.
- Project-level activation does not jump into a sibling batch worktree.
- `openWorkBatchCockpit` focuses the exact batch when visible; it does not create a new tmux/session surface if a healthy cockpit is already visible.

### Worktree Collision Or Missing Worktree

Policy:

- Batch worktree path collisions should be repaired deterministically before launch when possible.
- If the stored worktree is missing, stale, or invalid, the batch should become `waiting` with "recreate or reconnect needed".
- Do not create a second batch merely because the worktree is broken.

Acceptance:

- Branch/path collision either gets a deterministic suffix or leaves a waiting batch with clear text.
- Existing Tasks remain attached to the original batch.
- Recovery does not hide or duplicate Tasks.

### Duplicate Task Capture Or Reroute

Policy:

- Routing the same source Task twice should be idempotent.
- If a Task is rerouted, old `taskIDs` references should be cleaned from the prior batch.
- The latest classification record may be appended, but visible state should not show ghost Tasks.

Acceptance:

- Same Task id appears in only one batch's task list.
- Repeated capture/routing does not create multiple visible rows for one Task.
- A reroute leaves an audit trail in classifications but no dangling batch membership.

### Stale Or Unrelated Visible Summary

Policy:

- The visible batch/card summary must describe the latest actionable state of the selected batch.
- A newly queued Task should be reflected immediately in the batch row.
- If multiple batches are active, the project card should choose the most attention-worthy batch deterministically, not simply the first persisted active batch.
- If a classifier routes a Task into an unexpected batch, the route record should make the decision inspectable.

Acceptance:

- Capturing "add a green border around the mobile prototype" cannot leave the selected Work Batch card saying unrelated prior work such as a footer breakpoint fix.
- A test covers multiple active batches and proves waiting or newly queued work wins over older working summaries.
- A test covers stale persisted summaries and proves adding a new Task updates the visible summary.
- Classification rationale/confidence can be inspected in debug/proof state without asking the user to pick a method.

## Prioritized Edge-Case Ledger

| Priority | Edge case | Current handling | Intended handling | Acceptance for next slice |
| --- | --- | --- | --- | --- |
| P0 | Related Task added to running batch is not delivered to live Claude | Mirror updates, no resume for `.running` or `.launching` | Queue visibly, reconcile session health, nudge/resume only at safe boundary | Test proves no duplicate session and visible queued state; test proves stale boundary resumes same session id. |
| P0 | Binding status is not reconciled from runtime sessions | Binding is created as `.launching`; no clear source-owned status updater in Work Batch code | Reconcile bindings from runtime `RuntimeSession` cwd/session/liveness | Tests cover launching->running, running->stale, stale->running after resume. |
| P0 | Focus failure can resume a running binding and create overlap | `openExistingSession` resumes when focus fails even if status is `.running` | Running + live-but-unfocusable should surface "could not focus" before spawning a duplicate | Test covers focus failure with live runtime evidence and no resume. |
| P0 | Worktree creation collision blocks launch | `git worktree add` throws, router marks waiting | Deterministic suffix or explicit waiting repair state | Test covers branch/path collision and no lost Task. |
| P1 | Manual root Claude session exists before Task capture | Not considered by classification or binding | Do not auto-adopt; create managed batch; optionally include summary as classifier context later | Test classifier request excludes manual root session as bindable candidate. |
| P1 | Manual Claude session exists inside exact batch worktree | Not reconciled | Adopt only when session id matches stored binding; otherwise flag duplicate | Tests cover exact match and different session id. |
| P1 | Same Task is routed twice | Task record is replaced, old batch membership may remain | Idempotent membership cleanup | Test proves one Task id belongs to one batch. |
| P1 | Related Task enters stale batch with missing worktree | Mirror write or resume can fail and mark launch failed | Keep batch waiting with missing-worktree reason and recovery action | Test covers missing worktree path, queued Task retained. |
| P1 | Classifier chooses invalid existing batch | Parser falls back to new batch | Keep fallback, but record low-confidence reason visibly | Test proves fallback summary is surfaced in batch metadata. |
| P1 | Low-confidence classification | Confidence stored, not used in UI/policy | Still bias action, but record confidence and make route inspectable | Acceptance: no user prompt; route record inspectable in debug/proof. |
| P1 | Multiple project sessions in same repo/worktrees | Session projection treats repo identity carefully; Ghostty worktree matching distinguishes managed worktrees | Keep batch worktree exactness stronger than repo fallback | Tests cover sibling managed worktree not focused for wrong batch. |
| P1 | Visible card shows unrelated stale work | Work Batch summary wins over legacy session summary, but selected summary may still be stale or from the wrong active batch | Summary follows latest actionable batch state; route rationale is inspectable | Tests cover stale persisted summary repair and multiple active batch priority. |
| P2 | Project card has multiple active batches | Card uses first non-idle batch summary | Show the most attention-worthy batch; detail view lists all | Test covers ordering by waiting > newly queued > working > ready > idle, then updated time. |
| P2 | Done batch receives related Task | Router resumes `.done` binding | Treat as reopening the batch, not permanent completion | Test proves status becomes working/waiting and Task queued. |
| P2 | User removes/dismisses Task while queued in batch | Task status can be updated through idea dismissal; batch cleanup is not defined | Keep removal explicit and clean up batch queue/mirror | Acceptance later: dismissed Task disappears from mirror. |
| P2 | Model prompt injection in Task body | Prompt says Task body is data, not instructions | Keep, add tests for prompt structure | Existing test covers prompt guard; expand with hostile body fixture. |

## Next Implementation Slice

Slice name: Work Batch Binding Reconciliation and Delivery Policy.

Goal:

Make Work Batch cards reflect whether the bound Claude cockpit actually exists, avoid duplicate running sessions, and make related Tasks added to existing batches visibly queued until the same batch session can safely pick them up.

Non-goals:

- No multi-host abstraction.
- No old Circuit runtime.
- No runner, flow engine, task DAG, or retry platform.
- No broad memory store.
- No attempt to infer "done" from vague transcript summaries.

### Step 1: Add A Pure Reconciler

Add `WorkBatchBindingReconciler`.

Inputs:

- `WorkBatchStateSnapshot`
- `[WorkBatchCockpitBinding]`
- `[RuntimeSession]`
- current time

Outputs:

- updated bindings
- updated batch statuses/summaries
- warnings for duplicate/missing/unfocusable cockpits

Matching rules:

1. Exact stored `claudeSessionID` plus exact normalized `worktreePath` wins.
2. Exact `worktreePath` with different session id is a duplicate warning.
3. Project root sessions are not bindable Work Batch cockpits.
4. Sibling managed worktrees are never bindable.
5. No live session for a non-terminal binding marks it stale/waiting after a short launch grace window.

Acceptance:

- Unit tests cover each matching rule.
- Reconciler is pure and does not launch terminals.
- Binding status transitions are deterministic and timestamped.

### Step 2: Wire Reconciliation Into App Refresh

Call reconciliation after runtime snapshots are applied and before project/batch projections are read.

Acceptance:

- Opening Capacitor after a restart updates visible Work Batch statuses without user action.
- A killed Claude process eventually makes the batch waiting/stale.
- A resumed exact batch session makes the batch running again.

### Step 3: Tighten Route Delivery For Existing Bindings

When a Task routes to an existing batch:

- Always rewrite the context mirror.
- If binding is running/launching and reconciler says the exact cockpit is alive, do not resume.
- If binding is stale/waiting/done, resume in the batch worktree with stored session id.
- If binding is running but cannot be focused and runtime says it is alive, show a focus error instead of launching a second process.
- If runtime says it is not alive, resume.

Acceptance:

- Related Task to healthy running batch creates no new process.
- Related Task to stale batch resumes with `--resume <session id>`.
- Focus failure does not create duplicate sessions when runtime liveness says the session is alive.
- User-facing toast/card copy says queued, waiting, or resumed accurately.

### Step 4: Repair Idempotency And Membership

Make route application idempotent by source Task id.

Acceptance:

- Re-routing a Task removes it from old batch `taskIDs`.
- Re-routing does not duplicate the Task row.
- Classification history remains append-only enough for debugging.

### Step 5: Visible Batch-Card Rules

Keep the first surface simple:

- Project detail lists all batches and their Tasks.
- Project card shows the most attention-worthy active batch summary.
- A waiting/stale batch beats a merely working batch.
- A newly queued Task beats older working summaries when the user has just captured it.
- A newly queued Task appears in the batch row immediately.

Acceptance:

- Work Batch list shows status, name, queued count, summary, and Tasks.
- Project card does not show stale unrelated legacy session summaries when a batch has active queued work.
- Project card does not show stale unrelated Work Batch summaries when a newer queued Task needs attention.
- Multiple batches remain visible in project detail.

## Manual Test Plan For The Slice

Run after implementation:

1. Add a Task to a project with no batches.
   - Expected: new batch row, managed worktree, Claude Code launches, project card summary names the Task.
2. Add an unrelated Task to the same project.
   - Expected: second visible batch, second worktree, no merge.
3. Add a related Task to the first batch while its Claude session is alive.
   - Expected: same batch row queued count increments, mirror updates, no duplicate Claude process.
4. Kill the bound Claude process, then add a related Task.
   - Expected: same batch resumes by session id in the same worktree.
5. Start a manual Claude session in the project root, then add a Task.
   - Expected: Capacitor creates a managed batch and does not bind the root manual session.
6. Start or resume a Claude session manually in the exact batch worktree with the stored session id.
   - Expected: Capacitor reconciles the batch as running.
7. Create a second Claude session in the same batch worktree with a different session id.
   - Expected: Capacitor flags possible duplicate cockpit instead of silently adopting it.
8. Click a batch card.
   - Expected: focuses the correct visible Claude Code session when healthy; does not open a new window unless the session is stale or missing.

## Implementation Order

1. `WorkBatchBindingReconciler` pure model and tests.
2. Router delivery policy changes backed by reconciler output.
3. Idempotent membership cleanup.
4. Project/batch card projection priority updates.
5. Manual verification on `arc-design-studio`.

This order tightens the safety model before adding richer UI. The product should feel more automatic, but the implementation should get more conservative about when it creates or resumes sessions.
