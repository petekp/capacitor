# Work Batch Task Delivery Implementation Spec

Status: implementation spec
Audience: Capacitor maintainers
Scope: Work Batch Task delivery into Capacitor-managed Claude Code Task Sessions
Date: 2026-05-25

## Product Goal

Users add Tasks. Capacitor routes them into the right visible Work Batch, keeps related Tasks in the same batch/session, starts or resumes Claude Code when that is safe, and uses checkpoints when the worker needs the user's direction. The user should not choose methods, sessions, prompts, or terminal plumbing.

Claude Code is the only worker host for this slice.

## Best Implementation Path

Implement the current recommendation in this order:

1. Add a local Task claim/status callback.
2. Add delivery-generation bookkeeping so claims and wakeups are tied to the latest mirror.
3. Ingest claims and update Task state from queued to working only after a valid claim.
4. Extract a pure delivery policy that decides queue-only, resume, checkpoint wait, duplicate-cockpit wait, or delivery failure.
5. Call that policy after every queue-changing event: capture route, Done ingest, Checkpoint response, and Unresolve.
6. Update UI copy and manual test coverage after the state contract is stable.

Do not start with live terminal injection. Prompts and resumes are wakeups, not state. The queue, mirror, claims, Done reports, and Checkpoint requests are the state contract.

## Source-Backed Baseline

| Current source | Finding | Implementation consequence |
| --- | --- | --- |
| `CONTEXT.md:7`, `CONTEXT.md:15`, `CONTEXT.md:115`, `CONTEXT.md:127` | Tasks are actionable, checkpoints are the safeguard, non-disruptive delivery should update context without surprise interruption, and model discretion should be preserved. | Delivery should bias toward action without forcing preflight dialogs or injecting into busy sessions. |
| `apps/swift/Sources/Capacitor/Models/AppState.swift:204` | Capturing an Idea/Task immediately calls `startWorkBatchRouting`. | The product entrypoint already matches the desired UX; the spec should improve delivery, not add a new user step. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:127`, `:156`, `:198` | Routing creates a queued Task, classifies it, applies the route, and saves state. | Queue-first is already the natural baseline. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:211`, `:230`, `:238`, `:262` | Existing bindings rewrite the mirror, block on duplicate cockpit issues, optionally resume stale/waiting/done bindings, and return without starting a new session. | Related Tasks can join existing batches today, but running-session pickup is unproved. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:852` | `.running` and `.launching` bindings are not resumed by the router. | Preserve this for healthy live sessions; avoid duplicate Claude sessions. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:119`, `:139`, `:141`, `:143`, `:146` | The mirror lists Tasks and existing Done/Checkpoint callback paths, but currently calls itself the source of truth and has no pickup callback. | Add claim instructions and fix mirror wording to describe it as the agent-readable view of canonical state. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:252`, `:264`, `:393`, `:478` | New sessions use assigned `--session-id`; resumes use `--resume <session id>` in the Batch Worktree. | Resume is the recovery primitive for stale/waiting/done, not the default for healthy running sessions. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:35`, `:46`, `:65`, `:90`, `:238` | Reconciliation has exact-session matching, duplicate-cockpit detection, stale marking, and unfinished Task requeueing. | Delivery policy should reuse these facts rather than inventing a runner. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:26`, `:73`, `:217`, `:315`, `:350`, `:375` | State has queued/working/needs-you/done Tasks, batches, checkpoints, projections, checkpoint-first open action, and priority ordering. | Add minimal delivery state without changing the visible status taxonomy. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:93`, `:118`; `WorkBatchCheckpointExchange.swift:3`, `:30`, `:122` | Done and Checkpoint already use small local JSON files under `.capacitor/`. | Task claim should follow this same local callback pattern. |
| `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:344`, `:379`, `:447`, `:589` | Done ingest, Unresolve, and Checkpoint response all change queue state and rewrite the mirror. | Delivery policy must run after all of these, not only after initial route. |
| `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:478`, `:814` | Runtime session snapshots expose session id, cwd/project path, state, activity, tools in flight, GC reason, and liveness. | Enough data exists for safe resume/no-resume decisions, but not enough to justify generic live prompt injection. |
| `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift:3`, `:69`, `:76`, `:97`, `:207` | The current UI already shows batch status, queued count, summary, checkpoints, and Task rows. | The first UI change should be honest copy from delivery state, not a new surface. |
| `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:426`, `:441`, `:476`, `:515`, `:557`, `:593`, `:614` | Project card summary, opening, Unresolve, Checkpoint response, Done toasts, resume rules, and route toasts are all in one AppState extension. | Keep user-facing wording and auto-resume behavior consistent there after policy extraction. |

## Ambiguities Resolved

| Ambiguity | Decision |
| --- | --- |
| Does adding a related Task mean "send another prompt"? | No. It means durably queue the Task, update the mirror, and wake/resume only when policy says it is safe. |
| When does a queued Task become working? | Only after a valid Task claim or after starting a brand-new session for the first Task. Related Tasks added to an existing running batch stay queued until claimed. |
| What if claim, Done, and Checkpoint artifacts arrive in one refresh? | Done and Checkpoint beat claim for the same Task. Claim is pickup only; it must never overwrite completion or needs-you state. |
| Where should delivery state live? | Prefer `WorkBatchStateSnapshot` for versioned canonical state because delivery generation belongs to batch/task visibility. Binding can keep session facts only. |
| Can old state files load after adding delivery state? | Yes. Add optional/default decoding so version 1 snapshots load with empty delivery records. Do not break existing state. |
| Should healthy running sessions be resumed if focus fails? | No for automatic delivery. Focus failure on user open may stay as current behavior, but auto-delivery must not spawn another session for a live exact binding. |
| How do Done, Checkpoint, and Unresolve continue execution? | Each rewrites the mirror and runs the same delivery policy after updating state. No separate ad hoc resume decisions. |
| Do we need a safe wake in the first code slice? | No. The first testable solution is queue + mirror + claim + safe resume. Safe wake for exact idle/input-boundary sessions can be a later phase after claim/policy exists. |

## Phase 0: Baseline And Safety Net

Purpose: lock in the existing behavior before adding new state.

Files to inspect or update:

- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchStateTests.swift`

Steps:

1. Run the current focused tests before editing.
2. Add failing tests only if a current promise is undocumented.
3. Do not change source in this phase except test names or narrow regression fixtures if needed.

Automated tests:

```bash
swift test --package-path apps/swift --filter WorkBatchAutoRouterTests
swift test --package-path apps/swift --filter WorkBatchTaskSessionTests
swift test --package-path apps/swift --filter WorkBatchBindingReconcilerTests
swift test --package-path apps/swift --filter WorkBatchStateTests
```

Acceptance:

- Current related-task routing test still proves an existing running batch updates the mirror and does not launch.
- Current stale-binding test still proves `--resume <session id>` is used in the Batch Worktree.
- Current duplicate-cockpit tests still prove same-worktree duplicates block delivery.

Rollback risks:

- None if this phase is tests-only.

Completion criteria:

- Baseline tests pass before implementation work begins.

## Phase 1: Task Claim Callback Contract

Purpose: give Capacitor positive proof that Claude Code picked up a queued Task.

Files to add or update:

- Add `apps/swift/Sources/Capacitor/Models/WorkBatchTaskClaim.swift`
- Add `apps/swift/Tests/CapacitorTests/WorkBatchTaskClaimTests.swift`
- Update `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift`
- Update `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift`

Implementation:

1. Add `WorkBatchTaskClaim` with:
   - `taskID`
   - `status`
   - `summary`
   - `claimedAt`
   - `contextUpdatedAt`
   - optional `deliveryGeneration`
2. Add `WorkBatchLoadedTaskClaim`.
3. Add `WorkBatchTaskClaimStore`.
4. Use `.capacitor/work-batch-claims` as the relative directory.
5. Use the same JSON/date handling style as Done and Checkpoint stores.
6. Install `.capacitor/` ignore metadata through `WorkBatchMetadataIgnoreInstaller`.
7. Load only `.json` files and ignore malformed records.
8. Accept only `status == "working"` in this slice.
9. Add optional `WorkBatchContextMirror.deliveryGeneration`.
10. Update mirror copy:
    - It is an agent-readable view of Capacitor's canonical Work Batch state.
    - Claude should write a claim before starting a queued Task.
    - Claude should still use claim/checkpoint/done artifacts when the user manually steers in the cockpit.
11. Update initial and resume prompts to mention claim writing, while keeping prompts single-line.

Automated tests:

- `WorkBatchTaskClaimTests.testClaimStoreWritesAndLoadsClaimsFromBatchWorktree`
- `WorkBatchTaskClaimTests.testClaimStoreIgnoresMalformedJson`
- `WorkBatchTaskClaimTests.testClaimStoreIgnoresUnsupportedStatus`
- `WorkBatchTaskClaimTests.testClaimStoreInstallsLocalGitIgnoreForCapacitorMetadata`
- `WorkBatchTaskSessionTests.testContextMirrorRendersTaskClaimGuidance`
- `WorkBatchTaskSessionTests.testInitialPromptMentionsTaskClaim`
- `WorkBatchTaskSessionTests.testResumePromptMentionsTaskClaim`

Acceptance:

- A valid claim writes to `.capacitor/work-batch-claims/<task-id>.json`.
- Unsupported status does not load as an actionable claim.
- Mirror includes claim path and JSON shape, with delivery generation present when supplied.
- Mirror no longer says it is canonical source of truth.
- Initial/resume prompts stay single-line and include claim guidance.

Manual test:

- None required beyond automated tests for this phase.

Rollback risks:

- Prompt wording could become too long or noisy. Keep one concise sentence.
- Mirror wording could confuse canonical ownership. Keep `~/.capacitor` canonical and worktree mirror agent-readable.

Completion criteria:

- New claim-store tests and existing `WorkBatchTaskSessionTests` pass.

## Phase 2: Delivery Generation State

Purpose: make claims fresh, retries bounded, and visible state explainable.

Files to update:

- `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchStateTests.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`

Implementation:

1. Add `WorkBatchDeliveryRecord` to canonical Work Batch state:
   - `batchID`
   - `lastContextWrittenAt`
   - `lastDeliveryGeneration`
   - `lastDeliveryAttemptAt`
   - `lastDeliveryAttemptKind`
   - `lastClaimAt`
2. Add `[WorkBatchDeliveryRecord]` to `WorkBatchStateSnapshot`.
3. Decode old snapshots with `deliveryRecords = []`.
4. Keep file `version` at `1` if decoding remains backward-compatible; bump only if an old reader would break.
5. Add helper methods or narrow functions for:
   - getting record for batch
   - updating context-write generation
   - recording delivery attempt
   - recording claim
6. Generate delivery id as `"<batchID>:<ISO8601 updatedAt>"` or an equivalent deterministic value tied to mirror write time.
7. Change the router's private `writeContextMirror` helper to return a small result containing at least `updatedAt` and `deliveryGeneration`.
8. Update every router mirror-write call path to save the returned generation in the matching delivery record.

Automated tests:

- `WorkBatchStateTests.testStateStorePersistsDeliveryRecords`
- `WorkBatchStateTests.testStateStoreLoadsOlderSnapshotsWithoutDeliveryRecords`
- `WorkBatchAutoRouterTests.testDeliveryGenerationChangesWhenMirrorIsRewritten`

Acceptance:

- Existing state files without delivery records load.
- Saving state includes delivery records.
- Mirror generation is deterministic for tests.
- Rewriting the mirror updates `lastContextWrittenAt` and `lastDeliveryGeneration` through the router helper.

Manual test:

- None required beyond automated tests for this phase.

Rollback risks:

- State decoding is the main risk. Keep all new fields optional/defaulted.
- Generation tied to wall-clock time can make tests flaky. Inject `now` everywhere.

Completion criteria:

- `WorkBatchStateTests` pass.
- Existing Work Batch router tests still compile without broad fixture churn.

## Phase 3: Claim Ingestion

Purpose: convert valid worker pickup claims into Capacitor-visible state.

Files to update:

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift`

Implementation:

1. Add `WorkBatchTaskClaimIngestResult`.
2. Add `ingestTaskClaims(projects:now:)`.
3. For each binding, load claims from its Batch Worktree.
4. Validate:
   - task exists
   - task belongs to binding batch
   - task is not done or needs-you
   - claim `claimedAt >= task.updatedAt`
   - if claim delivery generation is present, it matches current batch delivery generation
5. For valid claims:
   - mark Task `.working`
   - update Task `updatedAt`
   - set batch `.working`
   - set batch summary to `Working on <task title>.` or claim summary if useful and non-empty
   - update delivery record `lastClaimAt`
6. Ignore malformed, foreign, stale, done-task, and needs-you claims without user-facing errors.
7. In AppState runtime snapshot handling, ingest claims before Done and Checkpoint if they share a cycle. Done and Checkpoint should still win for the same Task because their ingesters run afterward and overwrite pickup state with completion or needs-you state.

Automated tests:

- `WorkBatchAutoRouterTests.testIngestTaskClaimMarksQueuedTaskWorking`
- `WorkBatchAutoRouterTests.testIngestTaskClaimUpdatesBatchSummary`
- `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresForeignTask`
- `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresDoneTask`
- `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresNeedsYouTask`
- `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresStaleClaimBeforeTaskUpdate`
- `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresWrongDeliveryGeneration`
- `WorkBatchAutoRouterTests.testDoneAndCheckpointArtifactsOverrideTaskClaim`
- `AppStateRuntimeSnapshotEffectTests.testRuntimeSnapshotApplyIngestsWorkBatchTaskClaims`

Acceptance:

- A queued Task becomes working only after a valid claim.
- Invalid claims do not crash, toast, or mutate state.
- Done remains the only completion path.
- Checkpoint remains the only needs-you path.
- Claim never overwrites Done or Needs You when artifacts are ingested together.

Manual test:

1. Start Capacitor and route a Task into a Work Batch.
2. In the Batch Worktree, manually write a valid claim JSON for a queued Task.
3. Wait for the runtime refresh or trigger refresh.
4. Confirm the Task dot/status changes to working and summary says the worker picked it up.

Rollback risks:

- If claim ingestion runs after Done and rewrites Done state, user trust breaks. Done must win over claim.
- If stale claims are not filtered, Unresolve can be undone by old files. Stale/generation checks are mandatory.

Completion criteria:

- Claim ingestion tests pass.
- Manual claim test changes visible state without marking Done.

## Phase 4: Delivery Policy Extraction

Purpose: put all queue/resume/wait decisions in one small pure policy instead of scattered conditionals.

Files to add or update:

- Add `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- Add `apps/swift/Tests/CapacitorTests/WorkBatchDeliveryPolicyTests.swift`
- Update `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- Update `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`

Policy inputs:

- Batch record.
- Batch Tasks.
- Pending checkpoints.
- Binding, if any.
- Reconciliation issues.
- Exact live runtime session, if any.
- Mirror write result.
- Delivery record.
- Current time.

Policy actions:

- `queueOnly`
- `startNewSession`
- `resumeExistingSession`
- `waitForCheckpoint`
- `waitForDuplicateCockpit`
- `waitForDeliveryFailure`
- `safeWakeDeferred`

Initial behavior:

1. Mirror write failure -> `waitForDeliveryFailure`.
2. Pending checkpoint -> `waitForCheckpoint`.
3. Duplicate cockpit issue -> `waitForDuplicateCockpit`.
4. No binding -> `startNewSession`.
5. Binding `.stale`, `.waiting`, `.done` with open Tasks -> `resumeExistingSession`.
6. Binding `.launching` or `.running` with exact live session -> `queueOnly`.
7. Binding `.running` without exact live session after grace -> `resumeExistingSession` through stale reconciliation.
8. Existing delivery attempt for same generation -> do not retry automatically.

Automated tests:

- `WorkBatchDeliveryPolicyTests.testHealthyRunningBindingQueuesOnly`
- `WorkBatchDeliveryPolicyTests.testLaunchingBindingQueuesOnly`
- `WorkBatchDeliveryPolicyTests.testStaleBindingResumesExistingSession`
- `WorkBatchDeliveryPolicyTests.testWaitingBindingResumesExistingSessionWhenNoPendingCheckpoint`
- `WorkBatchDeliveryPolicyTests.testDoneBindingWithOpenTaskResumesExistingSession`
- `WorkBatchDeliveryPolicyTests.testPendingCheckpointWaitsForCheckpoint`
- `WorkBatchDeliveryPolicyTests.testDuplicateCockpitWaits`
- `WorkBatchDeliveryPolicyTests.testMirrorFailureWaitsWithoutResume`
- `WorkBatchDeliveryPolicyTests.testExistingDeliveryAttemptSuppressesRepeatedResume`

Acceptance:

- Policy has no side effects.
- Tests cover every action.
- Router behavior remains functionally equivalent for existing stale/running/duplicate paths before integration expands it.

Manual test:

- None required beyond automated tests for this phase.

Rollback risks:

- A too-large policy becomes a runner. Keep it to one decision, not scheduling.
- Repeating existing router conditionals without tests preserves ambiguity. The policy tests are the point of this phase.

Completion criteria:

- Policy tests pass.
- Existing router tests still pass.

## Phase 5: Router Integration And Follow-Through

Purpose: use one delivery policy after every queue-changing event.

Files to update:

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift`

Implementation:

1. Add an internal `applyDeliveryPolicy(...)` helper in `WorkBatchAutoRouter`.
2. After route into existing binding:
   - write mirror
   - update delivery generation
   - run policy
   - start/resume/wait/queue according to action
3. After new batch creation:
   - keep current start behavior
   - record delivery generation for the initial mirror
   - initial Task may remain `.working` because a new session is launched for that Task immediately
4. After Done ingest:
   - if open Tasks remain, rewrite mirror and run delivery policy
   - if no open Tasks remain, leave batch idle/done
5. After Checkpoint response:
   - rewrite mirror and run delivery policy
6. After Unresolve:
   - delete stale Done report
   - rewrite mirror
   - run delivery policy
7. Make AppState use router results rather than its own `shouldResumeWorkBatchBinding` for these paths where possible.
8. Keep checkpoint-first open behavior unchanged.

Automated tests:

- `WorkBatchAutoRouterTests.testRelatedTaskToHealthyRunningBatchQueuesWithoutResumeAndRecordsDeliveryGeneration`
- `WorkBatchAutoRouterTests.testRelatedTaskToStaleBatchRunsDeliveryPolicyAndResumesOnce`
- `WorkBatchAutoRouterTests.testRepeatedRoutingRefreshDoesNotResumeSameGenerationTwice`
- `WorkBatchAutoRouterTests.testDoneIngestWithQueuedTaskRunsDeliveryPolicy`
- `WorkBatchAutoRouterTests.testCheckpointResponseRunsDeliveryPolicy`
- `WorkBatchAutoRouterTests.testUnresolveRunsDeliveryPolicy`
- `WorkBatchAutoRouterTests.testPendingCheckpointPreventsResumeAfterNewRelatedTask`

Acceptance:

- Adding a related Task to a running batch does not create a new worktree, Claude process, Ghostty window, or tmux session.
- Adding a related Task to stale/waiting/done batch resumes the stored Claude session in the Batch Worktree.
- Done for Task A does not make the batch idle if Task B is queued.
- Checkpoint response and Unresolve use the same delivery path.
- Repeated refreshes do not spam resumes for the same generation.

Manual test:

1. In a test project, create a Work Batch and leave its Claude Code cockpit running.
2. Add a related second Task.
3. Confirm the same batch shows one queued Task.
4. Confirm no new Ghostty window appears.
5. Confirm `.capacitor/work-batch-context.md` in the Batch Worktree contains both Tasks and the new delivery generation.
6. Close the Claude cockpit, wait past launch grace or force stale state through test setup, then add another related Task.
7. Confirm Capacitor resumes the stored session in the Batch Worktree rather than creating a new batch.

Rollback risks:

- Running policy from multiple paths can double-write state. Keep state save order explicit.
- If AppState still separately resumes after router policy, duplicate resumes can reappear. Remove or bypass duplicate AppState resume decisions for Work Batch delivery paths.

Completion criteria:

- Router integration tests pass.
- Manual related-running and stale-resume tests pass.

## Phase 6: UI Honesty And Summary Selection

Purpose: make the visible batch/project card describe delivery state honestly.

Files to update:

- `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardContextLineResolver.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchStateTests.swift`
- `apps/swift/Tests/CapacitorTests/ProjectCardContextLineResolverTests.swift`

Implementation:

1. Summaries:
   - queued related Task: `Queued <Task>.`
   - claimed Task: `Working on <Task>.`
   - active work plus queue: `Working on <Task>. 1 queued.`
   - no pickup after retry: `Worker has not picked up the queued Task yet.`
2. Keep status labels as Ready/Working/Waiting/Compacting/Idle.
3. Use queued count exactly as the row already does.
4. Keep pending checkpoints visually above Task rows.
5. Make `workBatchContextSummary(for:)` use projection ordering and prefer waiting > queued working > working > ready > idle.
6. Ensure route summary cannot leave stale unrelated copy after a new Task is queued.

Automated tests:

- `WorkBatchStateTests.testProjectionSummaryPrefersClaimedWorkingTask`
- `WorkBatchStateTests.testProjectionSummaryMentionsQueuedTaskWhenNotClaimed`
- `WorkBatchStateTests.testProjectionPriorityKeepsWaitingAboveQueuedWorkingAboveWorking`
- `ProjectCardContextLineResolverTests.testWorkBatchSummaryStillBeatsLegacySessionSummary`
- `ProjectCardContextLineResolverTests.testRunAndDelegationStillBeatWorkBatchSummary`

Acceptance:

- A related queued Task is visible as queued, not falsely working.
- A valid claim changes visible copy to working.
- Project card does not show stale legacy session text over Work Batch text.
- Pending checkpoint still opens the checkpoint UI first.

Manual test:

1. Add two related Tasks to a project.
2. Confirm one Work Batch row, queued count, and current summary are understandable.
3. Write a claim for the second Task.
4. Confirm the row summary updates from queued to working.
5. Write a checkpoint request.
6. Confirm the batch opens the checkpoint response UI first.

Rollback risks:

- Too-clever copy can become another hidden state machine. Keep copy derived from existing status plus claim/queue facts.

Completion criteria:

- UI/projection tests pass.
- Manual UI test feels honest and avoids extra plumbing.

## Phase 7: End-To-End Manual Verification

Purpose: prove the implementation in the actual macOS app, because the failure class involves terminals and user-visible routing.

Setup:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Manual test A: related Tasks join one batch.

1. Open Capacitor.
2. In `parable-school`, add a typography Task.
3. Wait for the Work Batch to appear and Claude Code to launch.
4. Add a second related typography Task.
5. Expected:
   - same visible Work Batch
   - queued count increments
   - no new unrelated Ghostty window
   - card summary describes the new queued/working typography work
   - context mirror contains both Tasks

Manual test B: unrelated Tasks create separate batches.

1. In one project, add a typography Task.
2. Add a clearly unrelated data/import or deployment Task.
3. Expected:
   - two visible Work Batches
   - separate Batch Worktrees
   - separate Claude Code session ids
   - project card chooses the most attention-worthy batch

Manual test C: claim pickup.

1. Add a related queued Task.
2. In the Batch Worktree, write:

```json
{
  "task_id": "<task-id>",
  "status": "working",
  "summary": "Working on the queued Task.",
  "claimed_at": "<now>",
  "context_updated_at": "<mirror updated_at>",
  "delivery_generation": "<current generation>"
}
```

3. Expected:
   - Task status changes to working
   - summary changes to working
   - Task is not marked done

Manual test D: Done with remaining queued work.

1. In a batch with two Tasks, write a Done report for Task A only.
2. Expected:
   - Task A becomes done
   - Task B stays queued or working
   - batch does not become idle
   - mirror rewrites with current statuses

Manual test E: checkpoint response follow-through.

1. Write a Checkpoint request for a Task.
2. Open the batch.
3. Answer the checkpoint in Capacitor.
4. Expected:
   - response JSON is written
   - Task returns to queued unless already done
   - delivery policy resumes only when safe
   - primary open action no longer focuses the old checkpoint after answer

Manual test F: stale binding resume.

1. Create a batch and note its Claude Code session.
2. Close the visible Claude Code session.
3. Let Capacitor reconcile the binding stale, or use test setup to simulate stale.
4. Add a related Task.
5. Expected:
   - same batch
   - same Batch Worktree
   - `claude --resume <stored session id>`
   - no unrelated project-root session

Manual test G: duplicate cockpit recovery.

1. Create a second Claude Code session manually in the same Batch Worktree with a different session id.
2. Add a related Task or reconcile.
3. Expected:
   - batch becomes Waiting
   - summary says multiple Claude Code sessions match this Work Batch
   - no automatic resume or new session

Completion criteria:

- All manual tests pass or have source-backed defects filed before continuing.
- Screenshots or notes are added under `docs/circuit/proofs/operator-product-loop/` for at least A, C, E, and F.

## Required Final Automated Verification

Run:

```bash
swift test --package-path apps/swift --filter WorkBatchTaskClaimTests
swift test --package-path apps/swift --filter WorkBatchDeliveryPolicyTests
swift test --package-path apps/swift --filter WorkBatchTaskSessionTests
swift test --package-path apps/swift --filter WorkBatchStateTests
swift test --package-path apps/swift --filter WorkBatchBindingReconcilerTests
swift test --package-path apps/swift --filter WorkBatchAutoRouterTests
swift test --package-path apps/swift --filter WorkBatchCheckpointExchangeTests
swift test --package-path apps/swift --filter WorkBatchCompletionReportTests
swift test --package-path apps/swift --filter AppStateRuntimeSnapshotEffectTests
swift test --package-path apps/swift --filter ProjectCardContextLineResolverTests
swift test --package-path apps/swift
```

If Rust or UniFFI files are touched unexpectedly, stop and reassess. This slice should be Swift app code and docs only.

## Rollback Plan

If claim ingestion causes incorrect visible state:

1. Disable `ingestTaskClaims` call from AppState/runtime refresh.
2. Leave the claim store code in place if tests pass; it is inert without ingestion.
3. Keep queue + mirror behavior intact.

If delivery policy causes duplicate resumes:

1. Disable automatic `resumeExistingSession` from the new policy.
2. Keep `queueOnly`, checkpoint wait, duplicate-cockpit wait, and mirror writes.
3. Revert to existing `shouldResumeExistingBinding` behavior only for explicit user open.

If state decoding breaks old Work Batch files:

1. Revert delivery-record persistence.
2. Keep claim store and policy tests behind in-memory fixtures.
3. Add backward-compatibility tests before reintroducing persistence.

If UI copy becomes misleading:

1. Revert summary generation to prior batch `currentActivitySummary`.
2. Keep Task rows and queued count as the source of visible truth.

## Out Of Scope

- Old Circuit runtime.
- Runner or flow engine.
- Task DAG.
- Broad memory platform.
- Generalized multi-host abstraction.
- New terminal/editor.
- SaaS workflow framing.
- Default live terminal injection.
- Asking users to pick execution methods or sessions.

## Definition Of Done

The implementation is done when:

- Adding a Task automatically routes and starts managed execution.
- Related Tasks join the right visible Work Batch and Batch Worktree.
- Healthy running sessions are not duplicated.
- Stale/waiting/done sessions resume through the stored Claude Code session id.
- Claude pickup is proved through Task claims.
- Done, Checkpoint response, and Unresolve all feed the same delivery policy.
- Batch cards show honest queued/working/waiting state.
- Required automated tests pass.
- Manual tests A through G pass after `./scripts/dev/restart-alpha-stable.sh`.
- Two adversarial reviews of the implementation find no medium, high, or critical findings.
