# Storyboard-Indexed Product Loop Implementation Plan

Status: implementation plan
Audience: Capacitor maintainers building the operator-centered product loop
Source base: current Capacitor repo, receipt-first loop proof, orchestrator checkpoint docs, Swift/Rust runtime surfaces, and prior product storyboard decisions

## Product Thesis

Capacitor is not an app the user stares at. It is an app the user returns to.

The full product loop should make one promise:

> A user can leave real agent sessions running, return later, understand what changed, make crisp evidence-backed decisions, and trust that those decisions were followed through.

The storyboard spine is:

```text
Return -> Orient -> Delegate -> Trust quiet -> Interrupt -> Review evidence -> Decide -> Watch follow-through -> Iterate -> Complete -> Remember
```

The implementation should stay owner-first:

- Capacitor owns local session lifecycle, attention, observation, artifact storage, rendering, and operator decisions.
- The authenticated runtime service remains the live runtime boundary.
- Rust owns runtime truth, reducer/query behavior, persistence, and durable run/checkpoint state.
- Swift owns macOS orchestration, projection, stabilization, and presentation.
- Claude Code remains the primary execution host through one visible CLI session when the receipt-first loop is involved.
- Circuit remains a small headless protocol layer under `circuit_protocol/`, not an external runtime dependency.

## Current Baseline

This plan starts from the state proven by the receipt-first loop:

- A captured receipt-first idea can be selected from Capacitor.
- `CircuitReceiptProductLoop` maps that idea into a local protocol request.
- `scripts/circuit/plan-goal-packet.py` creates a `PursuitProposal` and Claude `GoalPacket`.
- Capacitor launches a visible Claude Code CLI session through the native adapter.
- Claude returns a `CIRCUIT_RECEIPT`.
- `scripts/circuit/normalize-agent-event.py` normalizes the receipt.
- Capacitor renders the completed proof in a native window.
- Proof artifacts live under `docs/circuit/proofs/receipt-first-product-loop/`.

That is a transport proof, not the finished product loop.

The repo already also has a separate method-runner/checkpoint substrate:

- Idea capture and method selection exist behind feature flags.
- Runtime runs expose phases, active checkpoints, past checkpoints, status, session ids, media artifacts, Mermaid sources, and decision state.
- The checkpoint bridge can pause a run, surface a checkpoint in Swift, receive an operator decision, and let the bridge unblock.
- `RunCheckpointReviewWindow` already renders active checkpoint state and supports approve/request changes.
- `ProjectDetailView` already has an idea queue, method selector, and checkpoint timeline.
- `ProjectsView` currently groups projects as `In Progress` and `Idle`, with `ActivityPanel` above the list.

The product work is to connect these into an attention-first operator loop.

## Non-Goals

Do not build these as part of this plan:

- A runner platform.
- A flow engine rewrite.
- A task DAG system.
- Broad memory or generalized long-term memory.
- Queue/retry infrastructure beyond narrow follow-through checks.
- Cursor support.
- A new terminal or editor.
- SaaS-style multi-user flow.
- A generalized multi-host abstraction.
- Any runtime dependency on `/Users/petepetrash/Code/capacitor-circuit`.

## High-Level Roadmap

### Milestone 1: Attention Foundation

Build the return brief and attention projection that all later scenes use.

Storyboard coverage:

- Scene 1: The Return
- Scene 2: The Field Of Work
- Scene 12: The Exception, first narrow pass

Outcome:

The main project surface answers "what needs me?" before it shows raw project inventory.

### Milestone 2: Delegation From Ordinary Intent

Make a captured idea become a normal run/delegation context without depending on the debug receipt menu.

Storyboard coverage:

- Scene 3: The New Intent
- Scene 4: The Handoff
- Scene 5: The Quiet Middle

Outcome:

The user can set direction, start work, and see a quiet commitment state with an expected next signal.

### Milestone 3: Checkpoint As The Trust Spine

Upgrade checkpoint review from "runtime checkpoint UI" to an operator evidence packet.

Storyboard coverage:

- Scene 6: The Interruption
- Scene 7: The Evidence Packet
- Scene 8: The Decision

Outcome:

A checkpoint leads with goal, claim, evidence, risk, and ask. The user can decide without reading a diff first.

### Milestone 4: Follow-Through And Revision Continuity

Show whether an operator decision was accepted, whether the run resumed, and how later checkpoints responded to prior steering.

Storyboard coverage:

- Scene 9: The Follow-Through
- Scene 10: The Revision Loop

Outcome:

Decisions do not disappear into a void. Later checkpoints lead with continuity.

### Milestone 5: Completion, Memory, And Closure

Make finished and historical work organized rather than noisy.

Storyboard coverage:

- Scene 11: The Completion
- Scene 13: The Project Memory
- Scene 14: The End Of Day

Outcome:

Project detail becomes a case file. End-of-day state can be summarized without reopening every terminal.

### Milestone 6: Receipt Loop Graduation

Move the receipt-first proof from debug proof shape toward the same product surfaces, without expanding execution scope.

Storyboard coverage:

- Cross-cuts Scenes 3 through 11.

Outcome:

The live Claude receipt loop uses ordinary intent, attention, evidence, decision, and follow-through surfaces where possible.

## Shared Implementation Primitives

These primitives should be introduced narrowly and reused across scenes.

### 1. Operator Attention Projection

Purpose:

Compute what deserves the user's attention from existing runtime, run, checkpoint, delegation, and session signals.

Suggested Swift shape:

```swift
struct OperatorAttentionSummary: Equatable {
    var needsYou: [OperatorAttentionItem]
    var runningNormally: [OperatorAttentionItem]
    var recentlyChanged: [OperatorAttentionItem]
    var dormant: [OperatorAttentionItem]
    var exceptions: [OperatorAttentionItem]
}

struct OperatorAttentionItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case checkpoint
        case decisionFollowThrough
        case completedRun
        case staleSession
        case runningRun
        case dormantProject
    }

    var id: String
    var kind: Kind
    var projectPath: String
    var title: String
    var reason: String
    var ageLabel: String?
    var recommendedAction: String?
    var target: OperatorAttentionTarget
}

enum OperatorAttentionTarget: Equatable {
    case project(path: String)
    case run(id: String, projectPath: String)
    case checkpoint(runID: String, checkpointID: String, projectPath: String)
    case session(id: String, projectPath: String)
}
```

Initial source files:

- Add `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`.
- Add `apps/swift/Tests/CapacitorTests/OperatorAttentionProjectionTests.swift`.

Initial inputs:

- `RunStateStore.runStatesByID`
- `RunStateStore.delegationStates`
- `RuntimeRunState.status`
- `RuntimeRunState.activeCheckpoint`
- `RuntimeRunState.pastCheckpoints`
- `RuntimeRunState.statusMessage`
- `ProjectRunVisualStateResolver`
- `ProjectCardContextLineResolver`
- Session staleness from existing session projection where available

Acceptance:

- Paused run with active checkpoint appears in `needsYou`.
- Recently completed run appears in `recentlyChanged`, not `needsYou`, unless final review is required.
- Healthy active run appears in `runningNormally`.
- Stale or suspicious session appears in `exceptions` with a plain reason.
- Projection tests cover ordering, deduplication, and conflict priority.

### 2. Operator Brief Model

Purpose:

Represent checkpoint evidence in the language of a decision, not in the language of raw artifacts.

Suggested additive model:

```swift
struct OperatorEvidenceBrief: Equatable {
    var goal: String
    var claim: String
    var changed: [String]
    var evidence: [OperatorEvidenceItem]
    var risks: [String]
    var ask: String
}
```

Initial approach:

- Build this as a Swift projection from existing `RuntimeCheckpointState` and `DelegationReviewManifest`.
- Only add Rust/runtime fields after the projection proves insufficient.
- Keep raw artifacts, Mermaid, terminal, and diff behind progressive disclosure.

Acceptance:

- Every checkpoint review window can show a concept-first brief, even when source data is partial.
- Missing fields degrade to clear placeholders, not empty UI.
- Unit tests verify projection from existing checkpoint fields.

### 3. Follow-Through Monitor

Purpose:

After a decision, show the expected lifecycle and detect narrow failure states.

Initial states:

- `decisionSubmitting`
- `decisionAccepted`
- `runResumed`
- `revisionExpected`
- `resumeSuspicious`
- `resumeFailed`

Initial source files:

- Add projection near run checkpoint review state, or a separate `RunDecisionFollowThroughProjection.swift`.
- Reuse runtime snapshots and existing decision relay fields.

Acceptance:

- After approve, UI can say "Decision accepted. Run resumed." once status changes.
- After request changes, UI can say feedback was delivered and a revision checkpoint is expected.
- If the decision is submitted but the run stays paused beyond the narrow window, the UI explains the suspicion.

### 4. Last-Seen And Since-You-Last-Looked

Purpose:

Support return briefs and project case files.

Initial implementation:

- Store local app-opened, per-project, and per-run last-seen timestamps in Capacitor's namespace.
- Keep it UI-local at first, but make the storage explicit and testable.
- Do not create broad memory.

Suggested source files:

- `apps/swift/Sources/Capacitor/Models/OperatorViewStateStore.swift`
- `apps/swift/Tests/CapacitorTests/OperatorViewStateStoreTests.swift`

Storage rule:

- Write only operator-view state: last opened, last seen project, last seen run, last seen checkpoint, and narrow daily summary counters once they are needed.
- Do not store agent reasoning, broad memory, or generalized project history here.

Acceptance:

- Return brief can say what changed since the user last opened Capacitor or last opened a project.
- Project detail can show "since you last looked" without needing agent-side memory.
- The first return brief milestone records app-open time before richer project memory work starts.

### 5. Launch Mode And Feature Flag Graduation

Purpose:

Prevent the loop from remaining a debug proof forever.

Initial implementation:

- Keep new surfaces behind frontier flags until the proof criteria pass.
- Add explicit graduation steps from debug menu to ordinary idea action to stable default.
- Preserve the debug command while the ordinary path is being proven.

Acceptance:

- The loop can be manually proven from the debug command and from the ordinary idea path.
- A single config change can enable the ordinary loop in stable once tests and manual proof artifacts pass.
- No product milestone is considered fully working while it is only reachable from `Circuit > Run Claude Receipt Loop`.

## Storyboard-Indexed Plan

### Scene 1: The Return

User moment:

The user opens Capacitor after being away and sees a return brief before a dashboard.

Target UI:

```text
While you were away:
2 decisions need you
1 worker completed
3 sessions are healthy
1 session looks stale
Nothing else needs attention
```

Do not claim "completed with evidence" in this brief until the projection has a
real evidence-ready signal. The first return slice should say "completed" and
let the review/evidence packet surface carry evidence claims.

Current substrate:

- `ProjectsView` renders `ActivityPanel`, then active/idle project groups.
- `ActivityPanel` can already show recent terminal completions.
- `RunStateStore` can expose active checkpoints and recent terminal runs.
- App config already gates frontier product surfaces.

Implementation slices:

1. Build the attention projection.
   - Work: create `OperatorAttentionProjection` and tests.
   - Data signals: active checkpoint, run status, recent terminal completion, delegation review state, session staleness.
   - UI surface: none yet; this is projection first.
   - Files: `OperatorAttentionProjection.swift`, `OperatorAttentionProjectionTests.swift`.
   - Proof: unit tests with synthetic run/checkpoint/session inputs.
   - Acceptance: the same project cannot appear as both urgent and merely active.

2. Add a return brief surface.
   - Work: add `ReturnBriefView` and render it above project groups when frontier surfaces are enabled.
   - Data signals: `OperatorAttentionSummary`, app last-opened timestamp from `OperatorViewStateStore`.
   - UI surface: `ProjectsView` above or replacing current `ActivityPanel`.
   - Files: `ProjectsView.swift`, new `ReturnBriefView.swift`, new `OperatorViewStateStore.swift`.
   - Tests: Swift view-model/projection tests, view-state store tests, snapshot-style assertions if the repo already has a fitting pattern.
   - Manual proof: launch app and verify the first visible content answers what needs attention.
   - Acceptance: user can tell whether action is needed without reading project cards, and the current app opening is recorded for the next return without replacing the previous-opened value used by the visible brief.

3. Add no-attention state.
   - Work: explicitly render "Nothing else needs attention" when summary is clean.
   - Data signals: empty `needsYou`, empty `exceptions`, no recent completion requiring review.
   - UI surface: return brief.
   - Tests: projection and view state.
   - Acceptance: healthy silence is represented as meaningful, not as an empty dashboard.

### Scene 2: The Field Of Work

User moment:

Below the return brief, the user sees the active landscape as a quiet map.

Target groups:

- Needs You
- Running Normally
- Recently Changed
- Dormant / Hidden

Current substrate:

- `ProjectsView` currently groups as `In Progress` and `Idle`.
- `ProjectRunVisualStateResolver` already classifies active, waiting, completed, failed, and none.
- `ProjectCardContextLineResolver` already determines the best one-line project context.
- Paused projects already have a collapsed section.

Implementation slices:

1. Replace active/idle grouping with attention groups.
   - Work: derive project groups from `OperatorAttentionSummary`.
   - Data signals: projection items grouped by target project.
   - UI surface: project list sections.
   - Files: `ProjectsView.swift`, `OperatorAttentionProjection.swift`.
   - Tests: grouping order and duplicate suppression.
   - Acceptance: a project with an active checkpoint appears under `Needs You` even if it also has running work.

2. Preserve project card simplicity.
   - Work: keep existing project cards, but feed them the attention-derived context line where appropriate.
   - Data signals: `ProjectCardContextLineResolver`, attention reason.
   - UI surface: `ProjectCard`.
   - Files: `ProjectCardContextLineResolver.swift`, project card call sites.
   - Tests: context priority.
   - Acceptance: cards stay glanceable; details remain one click away.

3. Add exception badges without noise.
   - Work: render stale/suspicious state as a plain reason, not animation-heavy activity.
   - Data signals: stale process, no transcript movement, failed resume, conflicting checkpoint state.
   - UI surface: section row/card status.
   - Files: `OperatorAttentionProjection.swift`, project card rendering files discovered during implementation.
   - Tests: projection priority for exceptions.
   - Acceptance: exceptions are obvious but not frantic.

### Scene 3: The New Intent

User moment:

The user captures an idea or chooses a method. They steer by intent and success criteria, not detailed chores.

Target copy:

```text
Intent: Improve checkpoint evidence packets for high-level review.
Success means: I can approve/reject without reading the diff first.
```

Current substrate:

- Idea capture already exists.
- `MethodSelectorView` lets the user choose how Capacitor should orchestrate an idea.
- `AppState+MethodRunner` starts method runs when the feature flag is enabled.
- The receipt-first loop still depends on a debug menu and a special receipt-first idea phrase.

Implementation slices:

1. Add intent/success criteria fields to the ordinary idea-to-run path.
   - Work: project existing idea title/body into explicit intent and success text.
   - Data signals: idea title, idea description, selected method.
   - Data contract: preserve intent and success criteria in the run-start payload or a narrow local run-start artifact; add runtime fields only if the existing run metadata cannot carry them.
   - UI surface: method selection and run start confirmation.
   - Files: `MethodSelectorView.swift`, `AppState+MethodRunner.swift`, idea view files discovered during implementation.
   - Tests: parsing/projection tests from captured idea to run intent.
   - Acceptance: starting a run does not require writing implementation instructions, and the resulting run/checkpoint surfaces can still recover the original intent.

2. Let receipt-first planning consume ordinary captured intent.
   - Work: remove the hardcoded receipt-first phrase as the only valid planning input.
   - Data signals: mapped idea JSON, selected host `claude_code`, success criteria.
   - UI surface: ordinary idea action, not only `Circuit > Run Claude Receipt Loop`.
   - Files: `CircuitReceiptProductLoop.swift`, `circuit_protocol/goal_packet_planning.py`, `scripts/circuit/plan-goal-packet.py`, tests under `tests/circuit_protocol/`.
   - Tests: protocol tests for ordinary idea payloads plus existing receipt-first check.
   - Acceptance: the proof idea still works, and a non-proof idea can create a bounded goal packet.

3. Keep execution scope narrow.
   - Work: still launch one visible Claude Code CLI session; do not introduce a queue or host router.
   - Data signals: target agent remains `claude_code`.
   - UI surface: ordinary action may still call the same native adapter.
   - Proof: live proof artifact update after manual run.
   - Acceptance: no old Circuit runtime dependency returns.

### Scene 4: The Handoff

User moment:

After starting work, the user sees the commitment, not raw code activity.

Target copy:

```text
Working on: Evidence packet redesign
Expected next signal: checkpoint brief
Healthy silence window: ~20m
```

Current substrate:

- `RuntimeRunState` has method name, status, phase data, active checkpoint, and status message.
- `ProjectRunVisualStateResolver` can mark a run as working/waiting/completed/failed.
- `ProjectCardContextLineResolver` can display a run context line.

Implementation slices:

1. Add commitment projection.
   - Work: project a run into `workingOn`, `expectedNextSignal`, and `healthySilenceWindow`.
   - Data signals: method id/name, phase state, active checkpoint absence/presence, status message.
   - UI surface: project card context and project detail current state.
   - Files: new `RunCommitmentProjection.swift`.
   - Tests: `RunCommitmentProjectionTests.swift`.
   - Acceptance: active work has a plain next expected signal.

2. Render quiet handoff state.
   - Work: show commitment in the card or detail header without activity spam.
   - Data signals: commitment projection.
   - UI surface: project card and project detail.
   - Files: `ProjectCardContextLineResolver.swift`, `ProjectDetailView.swift`.
   - Tests: context priority still favors checkpoints over ordinary work.
   - Acceptance: user understands they can leave the run alone.

3. Include receipt loop handoff.
   - Work: when the Claude receipt loop starts, show "expected next signal: receipt" or "checkpoint brief" depending on mode.
   - Data signals: loop projection metadata.
   - UI surface: render window/result surface and project attention state.
   - Files: `CircuitReceiptProductLoop.swift`, `ReceiptProofRendering.swift`, attention projection.
   - Tests: `CircuitReceiptProductLoopTests`, `ReceiptProofRenderingTests`, attention projection receipt-state cases.
   - Proof: updated receipt-loop proof artifact after a manual Claude run.
   - Acceptance: proof runs no longer feel detached from the product loop.

### Scene 5: The Quiet Middle

User moment:

Most work should compress. Healthy activity should not demand attention.

Current substrate:

- Session state projection and hysteresis already exist.
- Runtime runs expose status and status messages.
- Terminal completions are already summarized in `ActivityPanel`.

Implementation slices:

1. Define healthy silence.
   - Work: create simple projection rules for active runs that have expected next signal and no suspicious stale state.
   - Data signals: run status, last updated time if available, session liveness, transcript movement if exposed.
   - UI surface: `Running Normally` group.
   - Files: `OperatorAttentionProjection.swift`.
   - Tests: healthy-running cases in `OperatorAttentionProjectionTests.swift`.
   - Acceptance: healthy running work stays out of `Needs You`.

2. Detect suspicious silence narrowly.
   - Work: flag only states that can be explained from current signals.
   - Data signals: run marked working, no process alive, no transcript update, checkpoint timeout, resume did not happen.
   - UI surface: `Exceptions`.
   - Files: `OperatorAttentionProjection.swift`; later Rust/runtime files only if a missing signal must be exposed.
   - Tests: stale and healthy silence contrast cases.
   - Acceptance: UI explains why the silence is suspicious.

3. Keep animation/activity subdued.
   - Work: avoid motion as a reward for raw activity.
   - Data signals: none beyond the attention and commitment projections.
   - UI surface: project cards and groups.
   - Files: `ProjectsView.swift`, project card rendering files discovered during implementation.
   - Tests: view-model state tests where possible.
   - Manual proof: app screenshot of active healthy work.
   - Acceptance: no screen region looks more important merely because a worker is streaming tokens.

### Scene 6: The Interruption

User moment:

A checkpoint appears and becomes a `Needs You` item with a reason.

Target copy:

```text
Checkpoint ready: Evidence packet structure
Why now: Agent needs direction before continuing
Age: 3m
Recommended action: Review brief
```

Current substrate:

- Runtime exposes `activeCheckpoint`.
- `RunStateStore.reconcileRunCheckpointWindowTarget` already selects the oldest paused checkpoint.
- `RunCheckpointReviewWindow` opens for a run checkpoint target.

Implementation slices:

1. Add checkpoint attention cards.
   - Work: project paused active checkpoints into `Needs You`.
   - Data signals: `RuntimeRunState.status == "paused"`, `activeCheckpoint`, checkpoint `createdAt`, checkpoint `kind`, checkpoint `summary`.
   - UI surface: `Needs You` group and return brief counts.
   - Files: `OperatorAttentionProjection.swift`, `ProjectsView.swift`.
   - Tests: oldest-first ordering and age labels.
   - Acceptance: every active paused checkpoint has exactly one obvious review entry.

2. Explain why now.
   - Work: derive plain reason from checkpoint kind/status.
   - Data signals: checkpoint kind, phase id, summary, capture status.
   - UI surface: attention item subtitle.
   - Files: `OperatorAttentionProjection.swift`.
   - Tests: reason fallback cases.
   - Acceptance: user understands why the interruption exists.

3. Connect directly to review.
   - Work: clicking the item opens the existing run checkpoint review target.
   - Data signals: run id/project path.
   - UI surface: Needs You item action.
   - Files: `ProjectsView.swift`, existing window target code.
   - Tests: target selection where possible.
   - Acceptance: no manual navigation is needed to act.

### Scene 7: The Evidence Packet

User moment:

The checkpoint opens as an operator decision packet.

Target top section:

```text
Goal: Make checkpoints digestible for high-level steering.
Claim: Introduced a 4-level evidence packet model.
Changed: Review flow now leads with intent, outcome, evidence, risk.
Risk: No implementation yet; this is design direction.
Ask: Approve direction or request a different packet structure.
```

Current substrate:

- `RunCheckpointReviewWindow` already shows title, summary, phase, status, capture metadata, artifacts, media, Mermaid sources, and approve/request changes.
- `DelegationReviewManifest` already backs review-style content.
- `docs/orchestrator/review-surfaces.md` says checkpoint review lacks multi-round continuity compared with delegation review.

Implementation slices:

1. Add operator brief projection.
   - Work: project checkpoint fields and manifest fields into `OperatorEvidenceBrief`.
   - Data signals: checkpoint title, summary, brief path, manifest path, artifacts, capture claim.
   - UI surface: review window top content.
   - Files: new `OperatorEvidenceBriefProjection.swift`.
   - Tests: `OperatorEvidenceBriefProjectionTests.swift`.
   - Acceptance: every checkpoint has goal, claim, changed/evidence/risk/ask rows, even if some are derived.

2. Reorder review window around the brief.
   - Work: put concept-first packet above artifacts.
   - UI surface: `RunCheckpointReviewWindow`.
   - Files: `RunCheckpointReviewWindow.swift`.
   - Tests: projection tests; view smoke tests if available.
   - Manual proof: screenshot with concept-first top section.
   - Acceptance: user can make the first decision pass without opening raw artifacts.

3. Add progressive disclosure sections.
   - Work: group content into Summary, What changed, Evidence, Risks, Raw artifacts, Diff/terminal if available.
   - Data signals: existing artifacts and capture metadata.
   - UI surface: review window body.
   - Files: `RunCheckpointReviewWindow.swift`, maybe shared review components.
   - Tests: projection tests for section availability; view smoke tests if available.
   - Acceptance: raw details remain available but are not first.

4. Extend manifest schema only when needed.
   - Work: if existing fields cannot express goal/claim/risk/ask reliably, add optional fields to the runtime manifest.
   - Data signals: additive JSON fields.
   - Files: Rust manifest/domain files discovered during implementation, Swift bridge types, UniFFI refresh if Rust API changes.
   - Tests: Rust serialization tests, Swift parsing tests.
   - Acceptance: old manifests still render.

### Scene 8: The Decision

User moment:

The user steers the work at the right level.

Target actions:

- Approve direction
- Request conceptual changes
- Ask for stronger evidence
- Narrow scope
- Continue but watch risk
- Inspect implementation

Current substrate:

- Runtime checkpoint decision currently supports approve/request changes.
- `RunCheckpointReviewWindow` has a note box and decision rail.
- `docs/orchestrator/checkpoint-bridge.md` describes the decision relay.

Implementation slices:

1. Keep the runtime decision contract narrow first.
   - Work: map richer operator actions onto approve/request changes plus structured note intent.
   - Data signals: selected operator action, note body.
   - UI surface: decision rail.
   - Files: `RunCheckpointReviewWindow.swift`, decision mapping helper if extracted.
   - Tests: projection/helper tests for action mapping.
   - Acceptance: no runtime schema explosion is required for first product pass.

2. Add operator action presets.
   - Work: provide buttons/segmented choices for the common steering intents.
   - Data signals: selected action maps to decision kind and note prefix/metadata.
   - UI surface: decision rail.
   - Files: `RunCheckpointReviewWindow.swift`.
   - Tests: action-to-runtime-decision mapping.
   - Acceptance: common decisions do not require composing a blank note.

3. Preserve inspect path.
   - Work: make raw artifacts/diff/terminal available as secondary action.
   - Data signals: manifest/artifact paths.
   - UI surface: progressive disclosure section or secondary button.
   - Files: `RunCheckpointReviewWindow.swift`.
   - Tests: review action/projection tests for artifact availability.
   - Acceptance: high-level review does not hide the escape hatch.

### Scene 9: The Follow-Through

User moment:

After deciding, Capacitor shows whether the decision was accepted and what is expected next.

Target copy:

```text
Decision accepted. Run resumed.
Next expected signal: implementation checkpoint.
```

Current substrate:

- Runtime writes checkpoint decisions through authenticated mutation calls.
- The checkpoint bridge polls decision files and unblocks method execution.
- `RunStateStore` refreshes runtime snapshots.

Implementation slices:

1. Add post-decision local state.
   - Work: track decision submission, accepted snapshot, resumed snapshot, and suspicious pause.
   - Data signals: mutation result, checkpoint decision state, run status, active checkpoint id.
   - UI surface: review window confirmation and attention item state.
   - Files: `RunCheckpointReviewWindow.swift`, new follow-through projection.
   - Tests: state transition tests.
   - Acceptance: user sees a clear result after pressing a decision button.

2. Add narrow resume watchdog.
   - Work: if decision is submitted but run remains paused with same checkpoint after a short window, show retry/inspect state.
   - Data signals: same checkpoint id, same paused status, elapsed time.
   - UI surface: `Needs You` or `Exceptions`.
   - Files: follow-through projection, `OperatorAttentionProjection.swift`.
   - Tests: suspicious vs normal delay.
   - Acceptance: failure is explained as "decision submitted, but worker did not resume" rather than generic error.

3. Keep retry manual.
   - Work: expose retry/inspect actions without building a retry platform.
   - Data signals: last mutation failure, stale relay state.
   - UI surface: exception card.
   - Files: follow-through projection, `ProjectsView.swift`, terminal activation call sites if needed.
   - Tests: manual-retry state tests and no-auto-retry regression case.
   - Acceptance: operator remains in control.

### Scene 10: The Revision Loop

User moment:

A later checkpoint leads with what the user previously asked and how the agent responded.

Target copy:

```text
You asked: Make the packet less code-centric.
Agent response: Reworked the brief around intent, outcome, risk, and ask.
Evidence: New packet structure, updated examples.
Remaining risk: Needs UI validation.
```

Current substrate:

- `RuntimeCheckpointTimelineProjection` already combines past and active checkpoints.
- Runtime exposes past checkpoints and decision state.
- Delegation review has prior-round display that run checkpoint review lacks.

Implementation slices:

1. Add checkpoint continuity projection.
   - Work: find the last decision note for the same run/phase and project it into the active checkpoint brief.
   - Data signals: `pastCheckpoints`, decision note, phase id, history ordinal.
   - UI surface: review window continuity header.
   - Files: `RunCheckpointTimelineProjection.swift`, new continuity projection.
   - Tests: continuity projection tests.
   - Acceptance: revision checkpoints show the prior ask when one exists.

2. Add "agent response" field.
   - Work: derive from checkpoint summary first; add optional manifest field later if needed.
   - Data signals: active checkpoint summary/claim/manifest.
   - UI surface: evidence packet.
   - Files: `OperatorEvidenceBriefProjection.swift`, optional manifest parsing files only if needed.
   - Tests: fallback behavior.
   - Acceptance: follow-up checkpoints are not treated as isolated events.

3. Reflect continuity in project timeline.
   - Work: timeline entries show approve/request/revision relationships.
   - Data signals: history ordinal, decision state.
   - UI surface: `RunCheckpointTimelineSection` in project detail.
   - Files: `RunCheckpointTimelineProjection.swift`, `ProjectDetailView.swift`.
   - Tests: timeline ordering and revision-link tests.
   - Acceptance: user can reconstruct the loop without opening every packet.

### Scene 11: The Completion

User moment:

A run completes. Completion is organized, not automatically urgent.

Target copy:

```text
Completed: Evidence packet storyboard
Ready for: final review / merge / archive / follow-up
Confidence: medium
```

Current substrate:

- `ActivityPanel` already shows recent terminal run completions.
- `ProjectRunVisualStateResolver` keeps terminal states visible for a limited window.
- Runtime run status includes terminal states.

Implementation slices:

1. Define completion attention rules.
   - Work: classify completion as `recentlyChanged` unless there is a required final decision.
   - Data signals: run status, final checkpoint state, artifacts.
   - UI surface: return brief and recently changed group.
   - Files: `OperatorAttentionProjection.swift`.
   - Tests: completion attention projection tests.
   - Acceptance: completion does not interrupt unless action is needed.

2. Add final evidence summary.
   - Work: show concise completed-run packet with outcome, evidence, risks, follow-up.
   - Data signals: final checkpoint, artifacts, run status message.
   - UI surface: project detail and completion card.
   - Files: `ProjectDetailView.swift`, completion summary component if extracted.
   - Tests: projection tests.
   - Acceptance: user can defer or inspect final evidence.

3. Add archive/follow-up hooks later.
   - Work: define UI slots, but avoid broad lifecycle platform in first pass.
   - Data signals: completed run state, final review requirement if present.
   - UI surface: completion card and project detail final state.
   - Files: `OperatorAttentionProjection.swift`, `ProjectDetailView.swift`, completion summary component if extracted.
   - Tests: no-urgent-completion and final-review-required cases.
   - Acceptance: completion surface is useful without needing new orchestration infrastructure.

### Scene 12: The Exception

User moment:

Something gets weird, and Capacitor explains why it is suspicious.

Target copy:

```text
Possible stale worker
Why: marked working for 42m, no process alive, no transcript update
Safe action: inspect terminal
```

Current substrate:

- Session projection/hysteresis exists.
- Runtime run status and checkpoint state exist.
- Resume failure can be inferred from decision/follow-through state.

Implementation slices:

1. Start with explainable exceptions only.
   - Work: implement stale worker, failed resume, checkpoint timeout, and conflicting active checkpoint if the data exists.
   - Data signals: run status, process/session liveness, transcript update time, decision relay state.
   - UI surface: exceptions group and return brief count.
   - Files: `OperatorAttentionProjection.swift`, follow-through projection.
   - Tests: each exception has a plain reason and safe action.
   - Acceptance: no vague "something is wrong" cards.

2. Add inspect terminal action.
   - Work: route safe action to existing terminal/session activation path.
   - Data signals: session id, project path.
   - UI surface: exception item action.
   - Files: `TerminalActivationCoordinator.swift`, exception action call site discovered during implementation.
   - Tests: action target projection test where possible.
   - Acceptance: user can verify the suspicious state.

3. Log proof cases.
   - Work: create small proof artifacts for simulated exception states.
   - Data signals: synthetic projection fixtures for stale worker, failed resume, and checkpoint timeout.
   - UI surface: screenshots or rendered state captures.
   - Files: `docs/circuit/proofs/operator-product-loop/`.
   - Tests: projection fixtures used by `OperatorAttentionProjectionTests.swift`.
   - Proof path: `docs/circuit/proofs/operator-product-loop/`.
   - Acceptance: exception behavior is testable without waiting for real failures.

### Scene 13: The Project Memory

User moment:

The user opens Project Detail and sees a case file.

Target sections:

- Current state
- Recent decisions
- Checkpoint timeline
- Open risks
- Since-you-last-looked
- Dormant context

Current substrate:

- `ProjectDetailView` already has idea queue, method selector, and checkpoint timeline.
- `RunCheckpointTimelineProjection` can build chronological checkpoint entries.
- Project detail is feature-flagged.

Implementation slices:

1. Reframe project detail around current state.
   - Work: add a top case-file summary before raw controls.
   - Data signals: attention projection, commitment projection, active checkpoint, recent completion.
   - UI surface: `ProjectDetailView`.
   - Files: `ProjectDetailView.swift`, case-file summary component if extracted.
   - Tests: projection-level tests.
   - Acceptance: first screen says where the project stands.

2. Add recent decisions.
   - Work: summarize latest checkpoint decisions and notes.
   - Data signals: `pastCheckpoints`, decision status/note, timestamps.
   - UI surface: project detail.
   - Files: `RunCheckpointTimelineProjection.swift`.
   - Tests: sorting and note fallback.
   - Acceptance: user can see steering history quickly.

3. Add open risks.
   - Work: derive from active/final evidence packets; add optional manifest fields later.
   - Data signals: operator brief risks, checkpoint summaries.
   - UI surface: case-file summary.
   - Files: `OperatorEvidenceBriefProjection.swift`, `ProjectDetailView.swift`.
   - Tests: risk fallback and empty-risk cases.
   - Acceptance: risk is visible before raw artifacts.

4. Add since-you-last-looked.
   - Work: persist last-opened timestamp for project detail locally.
   - Data signals: last seen, checkpoint created/decided, run status changes.
   - UI surface: case-file summary.
   - Files: `OperatorViewStateStore.swift`, `ProjectDetailView.swift`.
   - Tests: timestamp comparison.
   - Acceptance: returning to a project rehydrates the story.

### Scene 14: The End Of Day

User moment:

Capacitor gives closure.

Target copy:

```text
Today:
4 agent runs completed
3 checkpoints approved
2 revisions requested
1 stale session recovered
Open loops: 2
Safe to stop: yes
```

Current substrate:

- Runtime snapshots can expose current runs and checkpoints.
- Local UI can compute recent changes.
- Durable "today" aggregation may need a narrow local store.

Implementation slices:

1. Start with current-snapshot closure.
   - Work: compute open loops, pending decisions, running healthy count, exception count.
   - Data signals: attention projection.
   - UI surface: return brief footer or command.
   - Files: `ReturnBriefView.swift`, daily summary projection if extracted.
   - Tests: summary counts.
   - Acceptance: user knows whether it is safe to stop.

2. Add daily counters from local event history.
   - Work: persist narrow local events for decisions, completions, recovered stale sessions.
   - Data signals: decision submitted, run completed, exception resolved.
   - Storage: Capacitor namespace only.
   - Files: `OperatorViewStateStore.swift`, daily summary projection.
   - Tests: event recording and date filtering.
   - Acceptance: daily summary does not require broad memory.

3. Add end-of-day surface.
   - Work: expose as a lightweight panel or menu action after return brief proves useful.
   - Data signals: daily summary projection and open-loop counts.
   - UI surface: main window or command menu.
   - Files: `ReturnBriefView.swift`, `ProjectsView.swift`, or command menu file if command-based.
   - Tests: summary projection tests.
   - Acceptance: closure is available without turning Capacitor into a reporting app.

## Receipt Loop Graduation Plan

The receipt-first proof should be tightened into the product loop in small steps.

### Step 1: Rename Stale Artifact Names

Status: completed for the file artifact; current proof artifacts use
`05-native-agent-last-message.txt`. The renderer should continue accepting the
legacy `codex_exit_code` field while preferring the neutral `agent_exit_code`
field for new adapter output.

Work:

- Rename `05-native-codex-last-message.txt` to a neutral agent name.
- Update metadata/tests/docs that reference the stale name.

Files:

- Existing proof artifacts under `docs/circuit/proofs/receipt-first-product-loop/`.
- Receipt rendering and validation tests that reference the artifact name.

Tests/proof:

- `python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json`
- Relevant receipt rendering/protocol tests.

Acceptance:

- Validation still passes.
- Metadata still records `host: "claude_code"`.

### Step 2: Move Launch From Debug Menu Toward Ordinary Idea Action

Work:

- Keep `Circuit > Run Claude Receipt Loop` while adding an ordinary idea action.
- Reuse `CircuitReceiptProductLoop.run(project:idea:)`.
- Stop requiring the special receipt-first phrase for all goal packet planning.
- Keep both paths under explicit feature flags until the ordinary path has proof artifacts.

Files:

- `CircuitFirstSliceCommands.swift`
- `CircuitReceiptProductLoop.swift`
- `MethodSelectorView.swift`
- `AppState+MethodRunner.swift`
- `circuit_protocol/goal_packet_planning.py`

Tests/proof:

- Protocol tests for ordinary idea payloads.
- Existing receipt-first loop tests.
- Manual proof artifact for the ordinary idea path.

Acceptance:

- Manual proof run still works from the menu.
- Ordinary captured idea path can start a bounded Claude receipt/goal packet run.
- Stable config can enable the ordinary path without enabling unrelated debug commands.

### Step 3: Render Receipt Runs In Attention Surfaces

Work:

- Represent receipt run state in `OperatorAttentionProjection`.
- Show running, completed, and failed receipt proof states alongside method runs.

Files:

- `OperatorAttentionProjection.swift`
- `CircuitReceiptProductLoop.swift`
- `ReceiptProofRendering.swift`

Tests/proof:

- Attention projection tests for running/completed/failed receipt state.
- Receipt proof rendering tests.

Acceptance:

- Receipt proof completion appears as `Recently Changed`.
- Failed receipt proof appears as an exception with a reason.

### Step 4: Convert Receipt Output To An Operator Brief

Work:

- Project normalized receipt into goal, claim, evidence, risk, and ask where possible.
- Keep the existing proof render window as a raw artifact/detail view.

Files:

- `OperatorEvidenceBriefProjection.swift`
- `ReceiptProofRendering.swift`
- `scripts/circuit/normalize-agent-event.py` only if normalized fields need to be additive.

Tests/proof:

- Receipt proof rendering tests.
- Agent event normalization tests if fields are added.

Acceptance:

- Receipt run can be reviewed in the same conceptual language as checkpoint packets.

### Step 5: Add Follow-Through For Receipt Decisions Only If Needed

Work:

- If receipt runs remain single-shot, do not invent a decision loop.
- If a receipt run produces a real checkpoint, route through the runtime checkpoint bridge.

Files:

- `CircuitReceiptProductLoop.swift`
- Follow-through projection files only if the receipt path produces a checkpoint.

Tests/proof:

- Regression test proving single-shot receipt runs do not fake checkpoint state.
- Checkpoint bridge tests only if a receipt checkpoint is introduced.

Acceptance:

- No fake checkpoint system is created just to make the receipt proof look complete.

## Source File Worklist

Likely Swift additions:

- `apps/swift/Sources/Capacitor/Models/OperatorViewStateStore.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ReturnBriefView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/RunCommitmentProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorEvidenceBriefProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/RunDecisionFollowThroughProjection.swift`

Likely Swift edits:

- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardContextLineResolver.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectRunVisualStateResolver.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointTimelineProjection.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift`
- `apps/swift/Sources/Capacitor/Features/CircuitFirstSliceCommands.swift`
- `apps/swift/Sources/Capacitor/Debug/CircuitReceiptProductLoop.swift`
- `apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift`

Likely Python/protocol edits:

- `circuit_protocol/goal_packet_planning.py`
- `scripts/circuit/plan-goal-packet.py`
- `scripts/circuit/normalize-agent-event.py` only if normalized receipt needs additive fields

Likely Rust/runtime edits, only after Swift projection proves the need:

- Runtime checkpoint manifest/domain fields for optional operator brief fields.
- Runtime query fields for last update/transcript movement if suspicious silence cannot be computed today.
- UniFFI bindings if exposed Rust API changes.

Likely tests:

- `apps/swift/Tests/CapacitorTests/OperatorViewStateStoreTests.swift`
- `apps/swift/Tests/CapacitorTests/OperatorAttentionProjectionTests.swift`
- `apps/swift/Tests/CapacitorTests/RunCommitmentProjectionTests.swift`
- `apps/swift/Tests/CapacitorTests/OperatorEvidenceBriefProjectionTests.swift`
- `apps/swift/Tests/CapacitorTests/RunDecisionFollowThroughProjectionTests.swift`
- Existing checkpoint/review tests expanded:
  - `RunCheckpointTimelineProjection` tests
  - `ReceiptProofRenderingTests`
  - `CircuitReceiptProductLoopTests`
  - `ReceiptFirstProofAdapterTests`
- Existing protocol tests expanded:
  - `tests/circuit_protocol/test_goal_packet_planning.py`
  - `tests/circuit_protocol/test_agent_event_normalization.py`

## Verification Ladder

Run the smallest relevant checks after each slice.

For projection-only Swift changes:

```bash
swift test --package-path apps/swift --filter OperatorViewStateStoreTests
swift test --package-path apps/swift --filter OperatorAttentionProjectionTests
swift test --package-path apps/swift --filter RunCommitmentProjectionTests
swift test --package-path apps/swift --filter OperatorEvidenceBriefProjectionTests
swift test --package-path apps/swift --filter RunDecisionFollowThroughProjectionTests
```

For checkpoint review UI changes:

```bash
swift test --package-path apps/swift --filter RunCheckpointTimelineProjection
swift test --package-path apps/swift --filter ReceiptProofRenderingTests
```

For receipt protocol changes:

```bash
python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization
python3 scripts/circuit/plan-goal-packet.py --check
python3 scripts/circuit/normalize-agent-event.py --check
python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json
```

For Rust runtime/schema changes:

```bash
cargo fmt
cargo test -p capacitor-core
cargo build -p capacitor-core --release
./scripts/dev/refresh-uniffi-bindings.sh
./scripts/ci/check-uniffi-bindings.sh
swift test --package-path apps/swift
```

For Swift UI changes:

```bash
swift test --package-path apps/swift
./scripts/dev/restart-alpha-stable.sh
```

Manual proof targets:

- Return brief visible on app open.
- Needs You checkpoint opens the correct review window.
- Evidence packet shows goal/claim/evidence/risk/ask before artifacts.
- Decision follow-through state changes after approve/request changes.
- Project detail reads as a case file.
- Receipt proof still validates and renders.

Recommended proof artifact path:

```text
docs/circuit/proofs/operator-product-loop/
```

Suggested artifacts:

- `return-brief-screenshot-01.png`
- `needs-you-checkpoint-screenshot-01.png`
- `operator-evidence-packet-screenshot-01.png`
- `decision-follow-through-screenshot-01.png`
- `project-case-file-screenshot-01.png`
- `receipt-loop-ordinary-idea-validation.json`
- `adversarial-review-01.md`
- `adversarial-review-02.md`

## Build Order

1. Implement `OperatorViewStateStore` with app last-opened support and tests.
2. Implement `OperatorAttentionProjection` with tests.
3. Add `ReturnBriefView` and attention groups to `ProjectsView`.
4. Add checkpoint `Needs You` action routing.
5. Add `RunCommitmentProjection` and quiet handoff copy.
6. Add intent/success criteria preservation for ordinary idea runs.
7. Add `OperatorEvidenceBriefProjection`.
8. Reorder `RunCheckpointReviewWindow` around the evidence packet.
9. Add operator action presets mapped to existing approve/request changes.
10. Add decision follow-through projection.
11. Add revision continuity projection using past checkpoints.
12. Reframe `ProjectDetailView` as a case file.
13. Expand last-seen storage to project/run since-you-last-looked.
14. Add completion and end-of-day summaries.
15. Graduate receipt loop into ordinary idea/action surfaces.
16. Move the ordinary loop from frontier/debug proof to stable only after proof artifacts pass.
17. Only then add runtime/schema fields where projections expose real gaps.

This order keeps the work grounded in existing runtime truth and avoids inventing infrastructure before the operator loop needs it.

## Acceptance Definition For "Fully Working"

The loop is fully working when all of these are true:

- Return: opening Capacitor shows what needs attention before raw inventory.
- Orient: projects are grouped by attention state, not just active/idle.
- Delegate: an ordinary captured idea can start a bounded run/delegation context.
- Handoff: active work shows expected next signal and healthy silence window.
- Quiet: healthy work compresses and does not demand attention.
- Interrupt: checkpoints become clear `Needs You` items.
- Review: checkpoint packets lead with goal, claim, evidence, risk, and ask.
- Decide: operator actions support approval, change requests, evidence requests, narrowing, risk watching, and inspection.
- Follow-through: Capacitor shows whether the decision resumed the run or got stuck.
- Iterate: later checkpoints show what the user asked and how the worker responded.
- Complete: completed work is organized and deferrable unless a decision is required.
- Exception: suspicious states explain why they are suspicious and offer a safe next action.
- Remember: project detail reconstructs current state, recent decisions, timeline, open risks, and since-you-last-looked.
- Closure: the user can tell whether it is safe to stop for the day.
- Receipt proof: the consolidated Claude receipt loop still works without old Circuit runtime dependency.
- Launch mode: the ordinary product path is available outside the debug menu once proof criteria pass.
