# Terminal Activation Foundation Hardening

Date: 2026-05-25 local.

Scope: Project card, Work Batch card, checkpoint row, terminal icon, Ghostty direct focus, tmux switch, Claude resume, fresh launch, duplicate debug app process cleanup, and activation traceability.

## Product Rule

Capacitor should reopen the right cockpit before launching anything new. When it cannot safely choose, it should explain the ambiguity instead of guessing.

## Changes

1. Added a source-backed activation state machine and failure-mode matrix:
   - `docs/circuit/terminal-activation-state-machine.md`
2. Added structured activation trace logging:
   - `apps/swift/Sources/Capacitor/Models/TerminalActivationTrace.swift`
   - wired through `AppState+Projects.swift`
   - wired through `TerminalActivationCoordinator.swift`
   - wired through `TerminalLauncher.swift`
   - wired through `WorkBatchTaskSession.swift`
3. Added focused regression coverage:
   - activation-flow trace for direct focus, tmux client resolution, and launch-last fallback
   - checkpoint-row trace
   - Work Batch card blocked-no-binding trace
   - Work Batch session focus trace
   - duplicate debug app process cleanup guard
4. Added a live manual helper:
   - `scripts/dev/check-terminal-activation-state.sh`

## Automated Verification

Passed focused trace slice:

```bash
swift test --package-path apps/swift --filter 'TerminalActivationCoordinatorTests|AppStateWorkBatchOpenTests|WorkBatchTaskSessionTests|RestartAppScriptTests'
```

Result: 37 tests, 0 failures.

Passed broader activation/session slice:

```bash
swift test --package-path apps/swift --filter 'GhosttyTerminalDriverTests|GhosttyAutomationClientTests|TerminalActivationCoordinatorTests|TerminalLauncherTests|TmuxRouterTests|SessionResolutionPolicyTests|WorkBatchAutoRouterTests|WorkBatchBindingReconcilerTests|WorkBatchTaskSessionTests|WorkBatchProjectPrimaryActionResolverTests|WorkBatchOpenActionResolverTests|AppStateWorkBatchOpenTests|RestartAppScriptTests'
```

Result: 186 tests, 0 failures.

Re-ran the same broader activation/session slice after the final Work Batch row tap fix.

Result: 186 tests, 0 failures.

Restarted the live debug app after Swift UI changes:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Result: build and relaunch completed successfully.

## Manual Verification

Manual helper:

```bash
scripts/dev/check-terminal-activation-state.sh
```

Observed after the terminal-icon click:

- One Capacitor Debug process from this repo build.
- No release Capacitor process.
- Ghostty windows remained the same three visible cockpits: `Mobile Prototype Polish`, `Implement Plumb-style code structure`, and `Typography scale adjustment`.
- The Work Batch terminal-icon click focused the existing `Mobile Prototype Polish` cockpit instead of launching a new Ghostty window.

Live checks performed:

1. Raw-clicked `pete-2025` project card.
   - Result: focused the existing Ghostty cockpit.
   - Trace included `surface="project_card" route="legacy_project_terminal"` followed by `route="direct_focus" outcome="focused"`.
2. Raw-clicked `arc-design-studio` project card.
   - Result: opened Project Detail instead of guessing between multiple idle bound Work Batches.
   - Trace: `surface="project_card" route="work_batch_primary" action="show_project_detail" outcome="detail"`.
3. Clicked `Mobile Prototype Polish` Work Batch card body.
   - Result: focused the existing Work Batch cockpit.
   - Trace: `surface="work_batch_card" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing"`.
4. Clicked the `Mobile Prototype Polish` Work Batch terminal icon after making the glyph a real button in all states.
   - Result: focused the existing Work Batch cockpit.
   - Trace: `surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing"`.

Post-review retest after removing the parent row tap gesture:

- Restarted Capacitor Debug with `./scripts/dev/restart-alpha-stable.sh`.
- Clicked the `Mobile Prototype Polish` terminal icon from the live `arc-design-studio` Project Detail view.
- Result: Ghostty became frontmost, the visible Ghostty windows stayed `Mobile Prototype Polish`, `Implement Plumb-style code structure`, and `Typography scale adjustment`, and no new Claude process appeared.
- Trace:

```text
[2026-05-26T05:44:47.697Z] [TerminalActivation] surface="direct_focus" route="focus_existing_terminal" action="focus_existing" outcome="already_selected" project_path="/users/petepetrash/code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray" session="Mobile Prototype Polish" evidence="session_hint,working_directory_or_title"
[2026-05-26T05:44:47.697Z] [TerminalActivation] surface="work_batch_session" route="work_batch_cockpit" action="focus_existing" outcome="focused" project_path="/users/petepetrash/code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray" batch_id="batch-mobile-prototype-polish-01kserayxhgn3ats8c4jre50" batch="Mobile Prototype Polish" session="0bf0e773-06b2-42b9-bd60-7993be3f139d" evidence="batch_binding,visible_terminal"
[2026-05-26T05:44:47.697Z] [TerminalActivation] surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing" project_path="/Users/petepetrash/Code/ever/arc-design-studio" batch_id="batch-mobile-prototype-polish-01kserayxhgn3ats8c4jre50" batch="Mobile Prototype Polish" session="0bf0e773-06b2-42b9-bd60-7993be3f139d" evidence="batch_binding,batch_worktree"
```

5. Temporarily restored the already-answered `parable-school` checkpoint to pending state, with an exact backup, to verify the live row path.
   - Result: project-card click opened Project Detail to the checkpoint.
   - Trace: `surface="project_card" route="checkpoint_review" action="show_checkpoint" outcome="needs_input"`.
6. Clicked the live pending Work Batch row in Project Detail.
   - Result: checkpoint review stayed focused instead of opening the cockpit.
   - Trace: `surface="checkpoint_row" route="checkpoint_review" action="show_checkpoint" outcome="needs_input"`.
7. Restored the exact `parable-school` Work Batch state file from backup and restarted Capacitor Debug.
   - Verified checkpoint state returned to `answered` with original `responded_at` and response.

## Screenshots

- `terminal-activation-open-arc-detail-for-icon-6-2026-05-25.png`
- `terminal-activation-terminal-icon-live-final-2026-05-25.png`
- `terminal-activation-checkpoint-project-card-live-2026-05-25.png`
- `terminal-activation-checkpoint-row-live-2026-05-25.png`

## Diff Hygiene

`git diff --check` on the activation/session/doc/script files touched by this slice passed with no output.

Full `git diff --check` still reports trailing whitespace in `.claude/dead-code-report.md`, which was an unrelated dirty file before this slice and was not edited here.

## Adversarial Review

- `terminal-activation-foundation-hardening-adversarial-review-01.md`
- `terminal-activation-foundation-hardening-adversarial-review-02.md`
