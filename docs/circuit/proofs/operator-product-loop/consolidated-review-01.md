# Consolidated Review 01: Operator Product Loop Foundation

Date: 2026-05-24

## Scope

Reviewed the recent operator product-loop slice as one change set:

- Storyboard-indexed implementation plan.
- Return brief and operator field-of-work projection.
- Ordinary captured idea to Claude receipt goal packet path.
- Method-run context carrying intent and success criteria.
- Receipt-loop run state and single visible Claude receipt-session guard.
- Attention-card action routing for checkpoints, delegation reviews, and receipt proof rendering.
- Receipt proof and run checkpoint evidence packets.
- Checkpoint decision follow-through after approve or request changes.
- Checkpoint revision continuity after a request-changes decision.
- Project Detail checkpoint timeline revision relationships.
- Project Detail case-file brief for current state, since-last-looked context,
  recent decisions, and open risks.
- Project Detail completion brief for completed runs, including final-review
  readiness, evidence, confidence, and residual risk.
- Return brief "since you last looked" summary derived from existing attention
  item timestamps and the narrow operator-view-state snapshot.
- Current-snapshot end-of-day closure check for open loops and safe-to-stop
  status.
- Runtime-history `Today:` counters for completed runs, approved checkpoints,
  and requested revisions.
- Ordinary captured-idea GoalPackets now ask Claude Code to do the smallest
  useful bounded slice and return a receipt, while the legacy fixture path stays
  a transport proof.

Unrelated dirty work, especially `.claude/dead-code-report.md`, was left untouched.

## Storyboard Position

Implemented foundation:

- Return: `ReturnBriefView` summarizes decisions, completions, healthy sessions, exceptions, no-attention state, and what changed since the operator last opened Capacitor.
- Orient: `OperatorAttentionProjection` and `OperatorFieldOfWorkProjection` group work into Needs You, Running Normally, Recently Changed, and Dormant / Hidden.
- Delegate: ordinary captured ideas can start a bounded Claude Code run that
  works on the captured intent and returns a receipt.
- Trust quiet: running receipt loops and healthy active runs stay in Running Normally with commitment copy.
- Interrupt: paused checkpoints and delegation reviews enter Needs You.
- Review evidence: receipt proof rendering and run checkpoint review now lead with operator briefs.
- Decide: checkpoint review still submits the existing approve/request-changes contract.
- Watch follow-through: after a decision, the checkpoint window now shows accepted, resumed, revising, suspiciously stuck, or failed states from the next runtime snapshot.
- Iterate: when a later same-phase checkpoint follows a request-changes note, checkpoint review now leads with what the operator asked, how the worker appears to have responded, evidence, and remaining risk.
- Remember: Project Detail now leads checkpoint history with a compact case-file
  brief and timeline rows show when a checkpoint responds to an earlier
  same-phase request-changes note.
- Complete: completed runs now surface a completion brief that says what
  finished, what it is ready for, what evidence exists, and what risk remains.
- End-of-day closure: the main project list now shows a compact closure check
  with open-loop count, attention blockers, healthy running work, completed work
  ready for review, `Today:` counters, and `Safe to stop: yes/no`.

Still intentionally incomplete:

- Revision continuity is still checkpoint-local; it is not a broad project memory system.
- Durable daily counters remain a future slice; current-snapshot closure now has
  a first working surface.
- The legacy fixture receipt path is still a transport proof; ordinary captured
  ideas now use a useful-work prompt.
- Rich checkpoint relay, retry infrastructure, task DAGs, broad memory, and generalized host management remain out of scope.

## Findings Fixed In This Pass

1. Medium: pre-launch method-runner failures could leave created runs behind.
   - Evidence: the runtime run is created before `MethodRunCoordinator.startRun`; before this pass, context setup, binary resolution, or launch failures could throw before sending a fail mutation.
   - Fix: `MethodRunCoordinator.startRun` now marks the run failed for setup, binary, launch, and nonzero subprocess failures before rethrowing.
   - Regression: `MethodRunCoordinatorTests.testStartRunFailsWhenIntentContextCannotBeWritten` now asserts the fail mutation is sent.

2. Medium: rejected ordinary receipt-loop starts could leave a stale "open proof after capture" wait in Project Detail.
   - Evidence: `ProjectDetailView` sets `openReceiptWindowAfterCapture` before calling `runMethodOnIdea`; when the global one-receipt-session guard rejected the start, no capture or failure notification cleared that flag.
   - Fix: the rejected start path now posts `.circuitFirstSliceDidFail`.
   - Regression: `AppStateReceiptLoopRunStateTests.testRejectedReceiptGoalPacketRunPostsFailureNotification` covers the rejected-start path.

3. Low: active revision continuity handled only the current `request_changes` action even though the timeline and reducer also support legacy `rejected`.
   - Evidence: `RunCheckpointTimelineProjection` maps `rejected` to changes requested, and the Rust reducer normalizes `rejected` to `request_changes`, but `RunCheckpointRevisionContinuityProjection` previously checked only the literal `request_changes` value.
   - Fix: revision continuity now treats `request_changes` and `rejected` as request-changes decisions.
   - Regression: `RunCheckpointRevisionContinuityProjectionTests.testBuildsContinuityFromLegacyRejectedDecisionInSamePhase` covers the compatibility path.

## Scene 9 Follow-Through Slice

Added a narrow Scene 9 implementation without changing the runtime decision contract:

- `RunCheckpointFollowThroughProjection` maps a submitted decision plus the latest run snapshot into plain operator states.
- `RunCheckpointReviewWindow` keeps the submitted view open after the active checkpoint clears, instead of dropping the user into a silent dismissal.
- The submitted view shows whether the decision is merely accepted, the run resumed, the worker is revising, the same checkpoint is suspiciously still present, or the run failed.
- Suspicious and failed states offer "Inspect Terminal" as the safe action.

Regression coverage:

- `RunCheckpointFollowThroughProjectionTests` covers accepted, resumed, revision expected, suspicious same-checkpoint, and failed-run states.
- The broader focused product-loop suite now includes the follow-through projection with checkpoint, attention, field-of-work, return brief, receipt-loop, and proof-rendering coverage.

## Scene 10 Revision Continuity Slice

Added a narrow Scene 10 implementation using existing runtime facts only:

- `RunCheckpointRevisionContinuityProjection` finds the latest prior same-phase checkpoint for the run.
- Continuity appears only when that latest prior same-phase decision was `request_changes` or the legacy-compatible `rejected` action and has a non-empty operator note.
- The active checkpoint review window now shows a revision continuity block before the ordinary operator brief.
- The block leads with `You Asked`, `Agent Response`, `Evidence`, and `Remaining Risk`.
- Agent response is derived from the active checkpoint summary first, then the existing operator brief claim.

Regression coverage:

- `RunCheckpointRevisionContinuityProjectionTests` covers the happy path, legacy `rejected` compatibility, blank notes, different phases, later approvals, history ordinal ordering, mixed missing ordinals, and impossible future ordinals.
- Existing follow-through, checkpoint timeline, operator brief, attention, field-of-work, return brief, receipt-loop, and full Swift tests remain green.

## Project Detail Timeline Relationship Slice

Added a narrow Project Detail case-file increment using the existing checkpoint timeline:

- `RunCheckpointTimelineProjection.Entry` now carries an optional revision relationship.
- A later checkpoint links back only to the latest same-phase `request_changes` decision with a non-empty note.
- A later approval responds to the request once, then clears that outstanding relationship for future checkpoints.
- Different phases and blank request notes do not create links.
- `RunCheckpointTimelineSection` renders the relationship as "Responds to round N" with the prior operator note.

Regression coverage:

- `RunCheckpointTimelineProjectionTests` covers same-phase linking, approval clearing, phase boundaries, and blank notes.
- `RunCheckpointTimelineSectionTests` covers the accessibility label for revision relationships.

## Project Detail Case-File Slice

Added a narrow Scene 13 implementation using existing run, checkpoint, timeline,
and operator-view-state facts:

- `ProjectCaseFileProjection` summarizes current run state, since-last-looked
  checkpoint updates, recent decisions, and open risks.
- `ProjectCaseFileSection` renders the brief above the checkpoint timeline in
  Project Detail.
- Project Detail records the project, run, and checkpoint IDs as seen through
  `OperatorViewStateStore`, but keeps the loaded in-memory snapshot stable so
  the "since last looked" brief does not erase itself while the operator is
  reading.
- Open risks come only from runtime facts: paused checkpoints, failed/cancelled
  runs, capture failure/progress, active revision relationships, and outstanding
  request-changes notes.
- The slice does not add broad memory, a persistence model beyond the existing
  narrow operator-view-state store, or any new runtime behavior.

Regression coverage:

- `ProjectCaseFileProjectionTests` covers paused checkpoints, revision
  continuity as risk, approval clearing, since-last-looked counting, and the
  accessibility summary.
- `AppStateOperatorViewStateTests` covers project/run/checkpoint seen-state
  persistence without mutating the loaded return snapshot.

## Scene 11 Completion Brief Slice

Added a narrow Scene 11 implementation using existing runtime and checkpoint
facts:

- `ProjectCompletionBriefProjection` turns completed runs into an operator
  brief with headline, outcome, ready-for copy, confidence, evidence, and
  residual risks.
- `ProjectCompletionBriefSection` renders the brief above the Project Detail
  case file when a completed run is available.
- Project Detail now also handles a recent completed run with no checkpoint
  history by showing a low-confidence brief with explicit missing-evidence risk.
- Recent completed-run cards now say `Ready for final review: ...` and carry
  `Review / archive / follow up` as the recommended action.
- The slice does not add merge automation, archive automation, broad memory,
  retries, queues, task DAGs, flow-engine behavior, or old Circuit runtime
  calls.

Regression coverage:

- `ProjectCompletionBriefProjectionTests` covers completed runs with checkpoint
  evidence, unresolved request-changes risk, completed runs without checkpoint
  history, non-completed exclusion, attention-copy fallback, and accessibility.
- `OperatorAttentionProjectionTests` covers the new recent-completion copy and
  recommended action.
- `ProjectCardContextLineResolverTests` covers final-review card copy for
  completed runs.

## Scene 1 Since-Last-Looked Return Brief Slice

Added a narrow Scene 1 implementation using existing attention categories and
the existing `OperatorViewStateStore` last-open snapshot:

- `OperatorAttentionItem` now carries an optional `lastChangedAt` timestamp.
- `OperatorAttentionProjection` fills that timestamp from existing runtime facts:
  active checkpoint creation time, delegation review request time, run update
  time, receipt-loop update time, or session update time.
- `ReturnBriefContent` now prepends a "Since you last looked" line when a
  prior app-open timestamp exists.
- The line counts new decisions, completions, exceptions, and healthy updates
  whose attention timestamp is newer than the previous open.
- If no attention items changed after the previous open, the brief says
  `Nothing changed since you last looked` while still showing older unresolved
  decisions below it.
- Missing or unparsable timestamps are ignored for the since-last-looked count,
  so unknown facts do not produce false novelty.
- The slice does not add a broad memory system, new persistence model, old
  Circuit runtime dependency, checkpoint relay, queues, retries, task DAGs, or
  flow-engine behavior.

Regression coverage:

- `ReturnBriefContentTests` covers mixed new/old since-last-looked counts, the
  no-change line, and projection-fed checkpoint timestamps.
- `OperatorAttentionProjectionTests` remains in the focused return/attention
  suite to guard existing category behavior while the item shape changes.

## Scene 14 Current-Snapshot Closure Slice

Added a narrow Scene 14 implementation without claiming durable daily history:

- `EndOfDayClosureContent` computes open loops from the existing attention
  summary.
- Open loops include decisions, exceptions, healthy running work, and completed
  work ready for review.
- `safeToStop` is `yes` only when no current decision or exception needs the
  operator.
- `EndOfDayClosureSection` renders the closure check below the return brief in
  the main project list.
- The section uses an accessibility identifier, `ax.end-of-day-closure`, so the
  surface can be targeted by future manual and automated checks.
- The slice does not add daily event history, broad memory, new storage, runner
  behavior, queue/retry behavior, task DAGs, flow-engine behavior, or old
  Circuit runtime calls.

Regression coverage:

- `EndOfDayClosureProjectionTests` covers safe-to-stop with healthy/completed
  loops, unsafe blockers from decisions/exceptions, and the empty safe state.
- `AccessibilityIdentifiersTests` covers the new closure accessibility
  identifier.

## Scene 14 Today Counters Slice

Extended the closure check with runtime-history counters without adding a new
event store:

- `EndOfDayClosureContent` now accepts current run snapshots.
- Completed runs are counted for today when their run `updatedAt` timestamp is
  on the operator's current day.
- Checkpoint approvals and requested revisions are counted from
  `pastCheckpoints` with `decidedAt` timestamps on the operator's current day.
- Legacy `rejected` decisions count as requested revisions for compatibility.
- Receipt-loop states feed the closure projection as synthetic run states, so a
  completed receipt loop can contribute to the daily completed-run count.
- When no current runtime history records same-day completions or decisions, the
  closure line says `Today: no completed runs or decisions recorded`.
- The slice does not add broad memory, durable daily event storage, recovered
  stale-session counters, checkpoint relay, queues, retries, task DAGs, or a
  flow engine.

Regression coverage:

- `EndOfDayClosureProjectionTests.testBuildsTodayCountersFromCurrentRuntimeHistory`
  covers same-day completed-run, approval, and request-changes counts while
  ignoring yesterday's runtime history.

## Ordinary Useful Receipt Run Slice

Graduated the ordinary captured-idea path from a pure transport prompt to a
bounded useful-work prompt:

- The legacy Codex fixture idea still emits the old transport-proof GoalPacket,
  preserving the original protocol check and proof artifact contract.
- Ordinary `claude_code` GoalPackets now tell Claude to do the smallest useful
  slice that satisfies the captured intent and success criteria.
- The prompt allows focused file inspection, edits, and verification, but keeps
  the work bounded to the captured idea.
- If owner direction is needed, the prompt tells Claude to return a blocked
  receipt instead of guessing.
- The method selector copy now says it starts a bounded Claude Code run from the
  idea and captures a receipt.
- The slice does not add a runner, flow engine, task DAG, queue/retry platform,
  broad memory store, SaaS workflow, new terminal/editor, generalized host
  abstraction, or old Circuit runtime dependency.

Regression coverage:

- `GoalPacketPlanningTests` covers ordinary useful-work prompt content and
  verifies the fixture Codex GoalPacket remains a transport proof.
- `CircuitReceiptGoalPacketMethodTests` covers the updated method copy.
- Existing fake product-loop tests still verify planning, launch, normalization,
  and rendering boundaries.

## Receipt Capture Hardening Slice

The first manual ordinary run exposed two correctness issues before it could be
trusted as product evidence:

- The capture readiness check could accept stale result files if they existed at
  the fixed latest-proof path.
- The shell-side fallback could scan the full transcript, which includes the
  inserted GoalPacket body and therefore can contain the prompt's receipt
  template.
- The app used a hard two-minute capture timeout, which was too short for the
  first useful Claude run; that run completed a few seconds after Capacitor had
  already marked it failed.

Fixes:

- `ReceiptFirstProofAdapter.captureIsReady` now accepts a capture only when the
  adapter result matches the current GoalPacket id, current inserted-body SHA,
  current inserted-body path, and current raw-receipt path.
- The capture script now scans `last-message` output first and then only the
  transcript text after the `AGENT_CLI_OUTPUT` marker, so the inserted prompt can
  never satisfy the receipt contract by itself.
- The default capture window is now 600 seconds, which fits bounded useful work
  while still preventing a run from hanging forever.
- The validator now accepts ordinary captured ideas, validates the current
  body hash against the inserted body, and rejects prompt-template receipts.

Regression coverage:

- `ReceiptFirstProofAdapterTests.testLaunchAndWaitForCaptureIgnoresStaleCaptureForDifferentBodyHash`
  covers stale body-hash rejection.
- `ReceiptFirstProofAdapterTests.testCaptureShellScriptDoesNotTreatInsertedPromptReceiptAsAgentOutput`
  covers prompt-only receipt rejection.
- `ReceiptFirstProofAdapterTests.testDefaultCaptureTimeoutLeavesRoomForOrdinaryUsefulWork`
  covers the 600-second default capture window.
- `CircuitReceiptProductLoopTests.testProductLoopRunsPlanningLaunchNormalizeAndProjectionWithFakes`
  was updated so fake captures must use the real inserted-body hash.

## Manual Ordinary Receipt Run 01

Manual run through the ordinary product path passed after the hardening slice:

- Captured an ordinary idea in Capacitor Project Detail:
  `Verify receipt capture guard stale-artifact fix`.
- Started `Claude Receipt Goal Packet` from the method selector.
- Capacitor showed the quiet-middle state in the return brief:
  `Since you last looked: 1 healthy update`, `1 session is healthy`, and
  `Safe to stop: yes`.
- Claude returned a useful receipt for
  `goal-packet-01ksdz0q8rckjzw6fkg94bvyz8`.
- Capacitor normalized the raw receipt into
  `event-receipt-01ksdz0q8rckjzw6fkg94bvyz8`.
- Capacitor opened the receipt rendering window with the current operator brief:
  goal, claim, evidence, no open risks, and ask.
- The app log recorded:
  `[CircuitClaudeProductLoop] completed from ordinary idea goalPacket=goal-packet-01ksdz0q8rckjzw6fkg94bvyz8`.

Copied manual proof artifacts are preserved under:

- `docs/circuit/proofs/operator-product-loop/manual-ordinary-receipt-run-01/`

## Current Issue Inventory

Confirmed-current after fixes:

- No medium, high, or critical findings remain in the reviewed slice.

Low residual risks:

- Return brief counts now include a narrow "since last looked" line, but this is
  still attention-item novelty rather than a complete historical diff.
- Healthy-update novelty can be noisy for active sessions and runs that update
  frequently.
- End-of-day closure has runtime-history `Today:` counters, but recovered stale
  sessions still need a narrow event source.
- Checkpoint risk copy falls back to plain text because current manifests do not yet carry explicit structured risk fields.
- Receipt proof rendering is still a latest-proof surface, not a historical per-run proof browser.
- Follow-through is snapshot-based.
- The ordinary receipt path now has a manual useful-work proof, but it still
  uses a fixed latest-proof artifact path; the copied manual proof directory is
  the durable evidence for this run.
- Project Detail now has a first case-file brief, but it is intentionally
  checkpoint/run-local rather than a full project memory system.
- Completion confidence is conservative and runtime-derived; it does not yet
  inspect diffs or perform semantic quality evaluation.
- Legacy Codex naming remains in compatibility fields and the Codex adapter reference; new operator surfaces use Claude receipt/session wording where the live path is Claude Code.

Deferred by design:

- Broad project memory beyond the first Project Detail case-file brief.
- Recovered stale-session daily counters.
- Richer useful-work lifecycle beyond one bounded Claude receipt run.
- Checkpoint relay, queues, retries, task DAGs, flow engine behavior, broad memory, SaaS framing, and generalized host abstraction.

## Verification

Passed during this review:

- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization` - 15 tests passed.
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- Focused completion/case-file/attention/card suite - 47 XCTest cases passed.
- Focused return/attention suite - 34 XCTest cases passed.
- Focused closure/return/attention/accessibility suite - 42 XCTest cases passed.
- Focused receipt/method suite - 32 XCTest cases passed.
- Focused Swift product-loop suite - 157 XCTest cases passed.
- Focused receipt hardening suite - 22 XCTest cases passed.
- Manual ordinary captured-idea run - passed, rendered
  `event-receipt-01ksdz0q8rckjzw6fkg94bvyz8` in Capacitor.
- `python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result-verified.json`
  - passed against the ordinary captured-idea proof.
- `swift test --package-path apps/swift` - 749 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live after restart: `CapacitorDebug` PID 16432 and `hud-hook serve --port
  7474` PID 16501.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
