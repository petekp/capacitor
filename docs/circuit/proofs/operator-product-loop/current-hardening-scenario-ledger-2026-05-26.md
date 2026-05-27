# Current Operator Product Loop Hardening Ledger

Date: 2026-05-26

## Scope

This ledger tracks the current proof state for the Work Batch, Task routing, checkpoint, terminal activation, and Ready projection slice.

Non-goals remain unchanged: no old Circuit runtime, no runner or flow engine, no task DAG, no broad memory platform, no generalized multi-host abstraction, no new terminal/editor, and no SaaS framing.

## Source-Backed Scenario Ledger

| Scenario | Intended behavior | Current evidence | Status |
| --- | --- | --- | --- |
| Add a Task | Capture should route automatically; the user should not choose Delegate, Run Method, or Execute. | `AppState+Projects.swift` routes project-card primary actions into Work Batch surfaces before legacy terminal fallback at lines 345-390. Existing Work Batch router tests cover new-batch and existing-batch Task routing. | Mostly proved by automated tests and earlier live checks. |
| Related Task joins an existing ready batch | Queue the Task, rewrite the mirror, and safely nudge the exact bound Claude Code cockpit without launching another session. | `WorkBatchAutoRouter.swift` feeds `safeWakeBoundarySatisfied` into the delivery policy at lines 1120-1133 and wakes through the existing binding at lines 1139-1148. Positive runtime-ready and process-backed signal-absence tests cover this path. Live `parable-school` proof is in `work-batch-runtime-safe-wake-boundary-2026-05-26.md`. | Proved for one real Ghostty/Claude shape plus focused tests. |
| Process exists but input boundary is not proven | Keep the Task queued; do not inject text just because a process scan found Claude. | `safeWakeBoundarySatisfied` requires runtime state at lines 1289-1315. The process-backed exception requires exact session, exact worktree, `signal_absence`, `toolsInFlight == 0`, and awaiting-input state at lines 1364-1373. Tests at `WorkBatchAutoRouterTests.swift:966-1118` prove missing awaiting-input evidence and missing tool-count evidence defer wake. | Proved by focused tests. |
| Active Claude sessions should show Ready, not disappear as Idle | Keep real live cockpits visible even when durable runtime state is idle or old, then clear back to Idle when that process disappears. | `SessionStateManager.swift` upgrades idle project state to Ready when live Claude process evidence exists at lines 640-659 and synthesizes Ready state for manual process evidence at lines 685-710. `RuntimeSnapshotApplicator.swift` now refreshes volatile live-process evidence even when the durable runtime snapshot version is unchanged. Live `parable-school` was visible as Ready in the running app. A controlled rebuilt-app `pete-2025` check proved `Idle -> Ready -> Idle` with process evidence; proof: `active-claude-ready-projection-live-2026-05-26.md`. Review: `active-claude-ready-projection-adversarial-review-01.md`. | Proved by focused tests, restart, strict Debug preflight, logs, live app state, and one clean adversarial review. |
| Completed batch with live cockpit | Completed Tasks may be done, but the batch should remain Ready if Claude is still open and awaiting direction. | `WorkBatchBindingReconciler.swift` sets completed batches to Ready when the live cockpit is ready at lines 265-286. Live `parable-school` showed `Ready` with done Tasks. | Proved by tests and live app state. |
| Project card click with Work Batch present | Prefer the managed Work Batch cockpit/checkpoint before falling back to a project tmux session. | `AppState+Projects.swift` resolves a Work Batch primary action before legacy terminal fallback at lines 345-390. Live logs at 2026-05-26T21:57:36Z, 21:57:40Z, and 21:57:46Z show `project_card -> work_batch_primary -> open_work_batch`. | Live rechecked. |
| Work Batch cockpit re-entry | Focus the exact bound Claude Code cockpit in the batch worktree; do not spawn a new Ghostty/tmux/Claude session when the cockpit is visible. | `WorkBatchAutoRouter.openCockpit` reconciles bindings, bails on blocking duplicates, and passes `preferFocusBeforeResume: true` at lines 632-655. `WorkBatchTaskSession.openExistingSession` focuses before resume at lines 515-548. Live logs at 2026-05-26T21:57:37Z and 21:57:47Z show `focused_existing`. | Live rechecked. |
| Legacy project terminal fallback with existing Ghostty tab | If no Work Batch surface applies, project-card fallback should still focus an existing Ghostty project tab before launching or chasing fallback tmux. A trusted runtime tmux route may still switch. | `TerminalActivationCoordinator.runActivationFlow` now accepts an already-selected direct match before tmux resolution when `switchAlreadySelectedDirectMatchWhenClientExists` is false. `TerminalLauncher.shouldSwitchAlreadySelectedDirectMatch` trusts runtime route/pane/TTY evidence, not generated fallback tmux names. `GhosttyAutomationClient` now normalizes shell-style title path candidates such as `~/Code/pete-2025 - zsh`, while keeping filesystem paths literal. Live proofs: `legacy-project-terminal-direct-focus-2026-05-26.md` and `terminal-activation-title-match-hardening-2026-05-26.md`. | Proved by focused tests, full Swift tests for the direct-focus policy, strict Debug preflight, live direct-focus/trusted-route traces, and a current-state live no-new-launch retest after the title parser hardening. |
| Pending checkpoint | Open the checkpoint answer UI before the cockpit. | `AppState+Projects.swift` handles `.answerCheckpoint` by showing Project Detail and setting a checkpoint focus target at lines 534-563. `WorkBatchOpenActionResolverTests` and `AppStateWorkBatchOpenTests` cover this. Live proof: `work-batch-checkpoint-first-live-2026-05-26.md`. | Proved by tests and controlled live checkpoint evidence; naturally agent-created checkpoint still pending. |
| Project card status for pending Work Batch checkpoint | A project card with a pending Work Batch checkpoint should show `Waiting`, even if the legacy project session snapshot is `Idle`. | `WorkBatchProjectVisualStateResolver` elevates pending checkpoints to `.waiting` and `ProjectCard.currentState` consumes that before legacy session state. Focused tests cover pending checkpoint, active batch status, idle done batches, and status-chip precedence. Live proof: `project-card-work-batch-status-live-2026-05-26.md`. | Proved by focused tests, full Swift tests, and controlled live app evidence. |
| Non-checkpoint Waiting Work Batch | A Waiting Work Batch that is not a checkpoint should surface as recovery attention, not as Running Normally. | `OperatorAttentionProjection.swift` classifies `waitingWorkBatch` as an exception and excludes `.waiting` from running-work candidates. `OperatorFieldOfWorkProjectionTests` and `OperatorAttentionProjectionTests` cover the behavior. Live proof: `work-batch-waiting-attention-recovery-2026-05-26.md`. | Proved by focused tests, full Swift tests, and controlled live card-status evidence. |
| Duplicate or ambiguous cockpit | Explain ambiguity and avoid silently choosing the wrong session. | `openCockpit` throws on blocking duplicate cockpit issues at `WorkBatchAutoRouter.swift:643-645`. Existing tests cover duplicate-cockpit open failure and duplicate assigned process behavior. Completed batches now record duplicate evidence without pulling done work back to Waiting, so click paths can still refuse to guess. Live proof: `duplicate-cockpit-live-guardrail-2026-05-26.md`. | Proved by tests and controlled live process evidence; real two-Claude Ghostty matrix still partial. |
| Wrong Capacitor build during live verification | Dev restart and diagnostics should prevent us from accidentally testing `/Applications/Capacitor.app`, another non-Debug Capacitor process, a stale direct Swift build, or a stale Debug bundle when the repo Debug app is the target. | `restart-app.sh` now kills and verifies away the installed release app, fails if Debug does not stay running/frontmost, and rejects non-Debug Capacitor processes after LaunchServices opens the Debug bundle. `check-terminal-activation-state.sh --activate-debug --require-debug-frontmost` activates and proves the Debug app, rejects non-Debug Capacitor processes, and rejects stale Debug builds when Swift/Rust sources are newer than the bundled artifacts. `restart-alpha-stable.sh` also forces `projectDetails,ideaCapture,llmFeatures` so the canonical Debug build has the Task capture path enabled. Proofs: `debug-build-target-guardrail-2026-05-26.md`, `debug-build-staleness-guardrail-2026-05-26.md`. | Proved by focused Bats tests, full dev-script suite, canonical restart, strict live diagnostic, bundle metadata, Computer Use path check, and stale-build unit coverage. |
| Unrelated Task creates a separate visible batch | Route to a new batch, worktree, and assigned Claude Code session. | The low-confidence relatedness guard now ignores project identity and generic scaffold words before overriding a model new-batch classification. Focused tests cover related typography reuse, unrelated scaffold-word separation, and high-confidence unrelated separation. Live disposable-fixture proof: `unrelated-task-routing-live-2026-05-26.md`. | Proved by focused tests, strict Debug preflight, live Add Task UI, Work Batch state, bindings, process evidence, generated claim/done artifacts, Project Detail UI, and cockpit re-entry trace. |
| Symlinked temp project path | A project added through `/private/tmp/...` should use the same Capacitor-owned project key as `/tmp/...`, so Task/Idea storage and Work Batch storage do not split. | `StorageConfig.project_data_dir` now normalizes storage keys before encoding, preserving lossless `encode_path` for historical paths while aligning live Core per-project state with Swift's normalized project key. Proof: `project-storage-key-alias-hardening-2026-05-26.md`. | Proved by focused Rust storage tests, focused Swift path test, `cargo fmt`, `git diff --check`, and release Core rebuild. |
| No pickup claim after wake | Do not repeat wake forever; surface waiting/recovery honestly. | `WorkBatchDeliveryPolicyTests` and `WorkBatchAutoRouterTests/testNoClaimAfterDeliveryAttemptMarksBatchWaitingWithoutRepeatingWake` cover pickup timeout and repeated wake suppression. | Proved by tests. |

## Live Manual Recheck

Target:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Session: 23bb3c4f-286f-4957-869b-6d33a6c9fd3f
```

Observed app state:

```text
parable-school: Ready for input
Typeface unification from source parable: Ready, 0 queued tasks
```

Runtime snapshot evidence:

```json
{
  "project_path": "/users/petepetrash/code/parable-school",
  "state": "ready",
  "representative_session_id": "23bb3c4f-286f-4957-869b-6d33a6c9fd3f",
  "latest_session_id": "23bb3c4f-286f-4957-869b-6d33a6c9fd3f"
}
```

Process evidence:

```text
93572 /Users/petepetrash/.local/bin/claude --resume 23bb3c4f-286f-4957-869b-6d33a6c9fd3f --append-system-prompt-file .capacitor/work-batch-agent-instructions.md Assessing updated tasks...
cwd: /Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source
```

Activation trace after clicking the `parable-school` project card:

```text
[2026-05-26T21:57:36.761Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="open_work_batch" outcome="cockpit" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" evidence="single_or_priority_batch"
[2026-05-26T21:57:37.218Z] [TerminalActivation] surface="direct_focus" route="focus_existing_terminal" action="focus_existing" outcome="already_selected" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" session="Typeface unification from source parable" evidence="session_hint,working_directory_or_title"
[2026-05-26T21:57:37.219Z] [TerminalActivation] surface="work_batch_session" route="work_batch_cockpit" action="focus_existing" outcome="focused" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,visible_terminal"
[2026-05-26T21:57:37.219Z] [TerminalActivation] surface="project_card" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree"
```

Result: pass. The project card entered the managed Work Batch cockpit and focused the existing bound Claude session. It did not launch a new Ghostty window, create a new tmux session, or fall back to the legacy project terminal route.

## Live Duplicate-Cockpit Recheck

Target:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Bound session: 23bb3c4f-286f-4957-869b-6d33a6c9fd3f
```

Controlled duplicate process evidence:

```text
24161 /private/tmp/capacitor-fake-claude/claude -c import time; time.sleep(300) --resume duplicate-session
cwd: /Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source
```

Observed behavior:

```text
Project card click: opened Project Detail because multiple Work Batches were possible.
Batch terminal/re-entry click: showed "Multiple Claude Code sessions match Typeface unification from source parable".
```

Activation trace:

```text
[2026-05-26T22:29:35.557Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="show_project_detail" outcome="detail" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" evidence="ambiguous_work_batches"
[2026-05-26T22:29:57.630Z] [TerminalActivation] surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="failed" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree" reason="Multiple Claude Code sessions match Typeface unification from source parable"
```

Result: pass. Capacitor explained the ambiguity and did not launch Ghostty, create a tmux session, or focus a wrong cockpit. Cleanup verified no controlled duplicate process remained.

## Live Checkpoint-First Recheck

Target:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Checkpoint: cp-live-checkpoint-routing-2026-05-26
```

Observed behavior:

```text
Project card summary: Checkpoint ready: For live verification, should Capacitor show this checkpoint before opening Claude?
Project card click: opened Project Detail and focused the checkpoint answer field.
Work Batch row: Waiting.
Checkpoint card: showed question, reason, recommended action, answer field, and submit button.
Submit: wrote response, closed the checkpoint, and returned the batch to Idle.
```

Activation trace:

```text
[2026-05-26T22:38:40.865Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="open_work_batch" outcome="checkpoint" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" evidence="pending_checkpoint"
[2026-05-26T22:38:40.865Z] [TerminalActivation] surface="project_card" route="checkpoint_review" action="show_checkpoint" outcome="needs_input" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" evidence="pending_checkpoint,project_detail_form" reason="cp-live-checkpoint-routing-2026-05-26"
```

Cleanup:

```text
Temporary checkpoint count after restore: 0
Temporary response artifact: removed
```

Result: pass. Checkpoint-first routing, answer focus, answer submission, response artifact writing, and cleanup all worked in the running Debug app. No Ghostty, tmux, or Claude process was launched.

## Live Project-Card Work Batch Status Recheck

Target:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Checkpoint: cp-live-project-card-waiting-2026-05-26
```

Observed behavior:

```text
Temporary pending checkpoint added to the Work Batch state.
Runtime snapshot still reported parable-school as idle.
Project card state changed from Idle to Waiting.
Original Work Batch state was restored.
Temporary checkpoint count after restore: 0.
Project card state returned from Waiting to Idle.
```

Live app log:

```text
[2026-05-26T22:51:44.188Z] [DEBUG][ProjectCardView][CardState] parable-school:Waiting path=/Users/petepetrash/Code/parable-school
[2026-05-26T22:51:44.193Z] ReadyChimeGate decision=skip reason=transition source=visible_state project_path=/Users/petepetrash/Code/parable-school old_state=Optional(Capacitor.SessionState.idle) new_state=Optional(Capacitor.SessionState.waiting)
[2026-05-26T22:52:04.169Z] [DEBUG][ProjectCardView][CardState] parable-school:Idle path=/Users/petepetrash/Code/parable-school
[2026-05-26T22:52:04.172Z] ReadyChimeGate decision=skip reason=transition source=visible_state project_path=/Users/petepetrash/Code/parable-school old_state=Optional(Capacitor.SessionState.waiting) new_state=Optional(Capacitor.SessionState.idle)
```

Result: pass. The project card status now follows Work Batch checkpoint state and no longer contradicts the checkpoint-ready summary.

## Verification Commands

Passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests/testProcessBackedSignalAbsenceWithoutAwaitingInputDefersWake|WorkBatchAutoRouterTests/testProcessBackedSignalAbsenceWithoutToolCountDefersWake|WorkBatchAutoRouterTests/testRoutesRelatedTaskToProcessBackedSignalAbsenceAwaitingInputWakesExactAssignedSession'
swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests|WorkBatchBindingReconcilerTests|WorkBatchDeliveryPolicyTests|WorkBatchTaskSessionTests'
swift test --package-path apps/swift --filter 'WorkBatchBindingReconcilerTests/testDoneBatchRecordsDuplicateOldCockpitsWithoutPullingWorkBackToWaiting|WorkBatchAutoRouterTests/testOpenDoneCockpitThrowsWhenForeignDuplicateBatchCockpitExists|WorkBatchAutoRouterTests/testOpenCockpitThrowsWhenDuplicateBatchCockpitExists|WorkBatchAutoRouterTests/testOpenCockpitFocusesAssignedSessionWhenOnlyDuplicateProcessMatches|WorkBatchAutoRouterTests/testOpenCockpitDoesNotResumeWhenDuplicateAssignedProcessCannotBeFocused'
swift test --package-path apps/swift --filter 'AppStateWorkBatchOpenTests|WorkBatchOpenActionResolverTests|WorkBatchCheckpointExchangeTests|WorkBatchAutoRouterTests/testIngestCheckpointRequestsMarksBatchWaitingForUser|WorkBatchAutoRouterTests/testSubmitCheckpointResponseWritesResponseAndQueuesTask|WorkBatchAutoRouterTests/testSubmitCheckpointResponseForDoneTaskClosesStaleCheckpoint'
swift test --package-path apps/swift --filter 'WorkBatchStateTests|StatusChipsRowTests|ProjectCardAnimationPolicyTests'
swift test --package-path apps/swift --filter 'OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|OperatorAttentionPrimaryActionResolverTests'
swift test --package-path apps/swift --filter 'TerminalActivationCoordinatorTests|TerminalLauncherTests|GhosttyTerminalDriverTests|ActivationPolicyTests'
swift test --package-path apps/swift --filter GhosttyAutomationClientTests/testBestGhosttyRouteMatchAcceptsHostPrefixedHomePathTitleWithShellSuffix
swift test --package-path apps/swift --filter GhosttyAutomationClientTests
swift test --package-path apps/swift --filter 'GhosttyAutomationClientTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests'
bats tests/dev-scripts/restart-app.bats
bats tests/dev-scripts/check-terminal-activation-state.bats tests/dev-scripts/restart-app.bats tests/dev-scripts/restart-alpha-stable.bats
bats tests/dev-scripts
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift
CARGO_INCREMENTAL=0 cargo test -p capacitor-core runtime::storage --lib
cargo test -p capacitor-core --lib --bins --tests
cargo build -p capacitor-core --release
swift test --package-path apps/swift --filter CapacitorProjectPathsTests
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
```

Results:

- 3 focused safe-wake tests passed.
- 105 focused Work Batch/router/binding/session tests passed.
- 5 focused duplicate-cockpit tests passed.
- 12 focused checkpoint/open-action tests passed.
- 48 focused Work Batch visual-state/status-chip/card-policy tests passed.
- 35 focused operator attention/field-of-work/action resolver tests passed.
- 64 focused terminal activation/policy/Ghostty driver tests passed.
- Focused Ghostty title-match regression passed.
- 19 focused Ghostty automation parser/matcher tests passed, including the ellipsized-title positive case, unknown-suffix negative case, and filesystem ` - zsh` path cases.
- 76 focused Ghostty/terminal activation tests passed after title parser hardening.
- 18 focused Debug-build/restart diagnostic Bats tests passed.
- Full dev-script Bats suite passed: 82 tests.
- SwiftFormat reported 0 files requiring formatting.
- `git diff --check` reported no whitespace errors.
- Full Swift verification passed after the latest storage-key hardening: 947 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
- Full Swift verification passed after the title parser hardening: 948 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
- Full Swift verification passed after the adversarial title-normalizer fix: 951 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
- Full Swift verification passed after ellipsized-title suffix hardening: 952 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
- Focused Core storage tests passed: 34 tests.
- Broad Core verification passed across library, bins, and integration tests.
- Release Core rebuild passed after the storage-key hardening.
- Focused `CapacitorProjectPathsTests` passed after the storage-key hardening.
- Canonical Debug restart passed after adding the wrong-build guard.
- Canonical Debug restart passed again after the storage-key hardening.
- Strict post-restart diagnostic activated and proved front app path `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`, one Debug process, and no installed release process.
- Latest strict diagnostic after the storage-key hardening showed Debug app pid `51006`, no release/non-Debug Capacitor processes, no Claude processes, and no recent fixture activation trace.
- Debug bundle metadata proved `CFBundleIdentifier=com.capacitor.app.debug`, `CFBundleDisplayName=Capacitor Debug`, and `CapacitorFeaturesEnabled=projectDetails,ideaCapture,llmFeatures`.
- Computer Use attached correctly when targeting `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.
- Live `pete-2025` project-card fallback focused an existing Ghostty project tab without launch when no tmux client was attached.
- Live `pete-2025` trusted-runtime tmux route switched/focused without launch when a temporary tmux client was attached; cleanup detached the temporary client.
- Live `pete-2025` project-card fallback initially exposed a title-only Ghostty match miss and launched a new tmux attach; after title parser hardening and restart, the same click path produced no additional launch entries in current live state.
- A second live Computer Use raw-card click pass at 2026-05-27T00:47Z fired the project-card path, foregrounded Ghostty, and repeated direct-focus/tmux-switch behavior without any new launch entries.
- Adversarial review found and fixed an over-broad shell-suffix stripping bug that could have collapsed a real filesystem path like `/Users/pete/Code/foo - zsh` to `/Users/pete/Code/foo`.
- After rebuilding and relaunching the latest binary, a post-restart raw `pete-2025` card click at 2026-05-27T00:53Z accepted the already-selected Ghostty cockpit directly with `tmux_route_untrusted`; no launch or tmux-switch entry was produced.
- After the ellipsized-title hardening and another rebuild/relaunch, a final post-restart raw `pete-2025` card click at 2026-05-27T00:57Z again accepted the existing Ghostty cockpit directly; no launch or tmux-switch entry was produced.

## Remaining Highest-Risk Gaps

1. Duplicate-cockpit behavior now has controlled live process evidence, but still needs a real two-Claude Ghostty/tmux matrix when it is safe to create one.
2. The checkpoint live proof used a temporary state injection rather than a naturally agent-created checkpoint request.
3. The `/private/tmp` disposable fixture split was hardened in Core storage after the live proof. The remaining risk is migration/backfill behavior for any already-written temp-project state using the old raw `/private/tmp` key.
4. Runtime route evidence for `parable-school` still reported `NO_TRUSTED_EVIDENCE`, while the Work Batch binding path focused correctly. Legacy project fallback now has a narrower direct-focus guard and stronger Ghostty title matching, but project-level routing should still get more real-world matrix coverage.
