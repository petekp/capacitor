# Work Batch Card Cockpit Re-entry

Date: 2026-05-26

## Scenario

Clicking a Work Batch card should re-enter the exact bound Claude Code cockpit. It should not open an unrelated project tmux session, create a duplicate Ghostty window, or fail with a multiple-session ambiguity when the batch already has a known Claude session.

This live check used the real `parable-school` project and the real `Typeface unification from source parable` Work Batch.

## Starting Evidence

Capacitor Debug was the only Capacitor app process:

```text
77726 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
```

The Work Batch had a durable Claude Code binding:

```json
{
  "batch_id": "batch-typeface-unification-from-source-parable-01ksfw1",
  "batch_name": "Typeface unification from source parable",
  "claude_session_id": "23bb3c4f-286f-4957-869b-6d33a6c9fd3f",
  "host": "claude_code",
  "project_path": "/Users/petepetrash/Code/parable-school",
  "status": "done",
  "worktree_path": "/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source"
}
```

The live Claude process matched that assigned session:

```text
93572 ... /Users/petepetrash/.local/bin/claude --resume 23bb3c4f-286f-4957-869b-6d33a6c9fd3f --append-system-prompt-file .capacitor/work-batch-agent-instructions.md Assessing updated tasks...
```

The app showed:

```text
parable-school: Ready for input
Typeface unification from source parable: Ready, 0 queued tasks
Typography scale adjustment: Idle, 0 queued tasks
```

This is the intended distinction:

- durable task/binding outcome remains `done`
- visible operator state is `Ready` because the exact assigned Claude cockpit is alive

## Manual Check

From the Capacitor Debug app:

1. Clicked the `parable-school` Project card.
2. Capacitor opened Project Detail instead of guessing, because the project has multiple Work Batches.
3. Clicked the `Typeface unification from source parable` Work Batch card body.

The terminal activation trace showed the first card click:

```text
[2026-05-26T21:14:26.422Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="show_project_detail" outcome="detail" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" evidence="ambiguous_work_batches"
```

The first Work Batch card click resumed the assigned stale binding in the batch worktree:

```text
[2026-05-26T21:14:36.561Z] [TerminalActivation] surface="direct_focus" route="focus_existing_terminal" action="focus_existing" outcome="relaunch_needed" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" session="Typeface unification from source parable" evidence="session_hint,working_directory_or_title"
[2026-05-26T21:14:36.719Z] [TerminalActivation] surface="work_batch_session" route="claude_resume" action="resume_claude" outcome="launched" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,context_mirror"
[2026-05-26T21:14:36.720Z] [TerminalActivation] surface="work_batch_card" route="work_batch_cockpit" action="open_cockpit" outcome="resume_launched" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree"
```

After the cockpit was live, a second Work Batch card click focused the existing Ghostty cockpit instead of launching a duplicate:

```text
[2026-05-26T21:16:57.135Z] [TerminalActivation] surface="direct_focus" route="focus_existing_terminal" action="focus_existing" outcome="already_selected" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" session="Typeface unification from source parable" evidence="session_hint,working_directory_or_title"
[2026-05-26T21:16:57.136Z] [TerminalActivation] surface="work_batch_session" route="work_batch_cockpit" action="focus_existing" outcome="focused" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,visible_terminal"
[2026-05-26T21:16:57.136Z] [TerminalActivation] surface="work_batch_card" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree"
```

System diagnostics after the click:

```text
front_app: ghostty

ghostty_windows:
* Typeface unification from source parable

claude_processes:
93572 resume=23bb3c4f-286f-4957-869b-6d33a6c9fd3f
```

## Result

Pass.

- The Project card did not guess between multiple Work Batches.
- The Work Batch card used the durable binding and batch worktree.
- The stale binding path resumed the assigned Claude session once.
- The live cockpit path focused the existing Ghostty window.
- No unrelated project tmux session was foregrounded.
- No duplicate Claude resume was observed.
- The app projected the active completed batch as `Ready`, preserving the operator-facing intent that live Claude cockpits stay visible.

## Terminal Icon Check

After the Work Batch cockpit was live, clicking the Work Batch terminal icon used the same bound cockpit route:

```text
[2026-05-26T21:19:15.520Z] [TerminalActivation] surface="direct_focus" route="focus_existing_terminal" action="focus_existing" outcome="already_selected" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" session="Typeface unification from source parable" evidence="session_hint,working_directory_or_title"
[2026-05-26T21:19:15.520Z] [TerminalActivation] surface="work_batch_session" route="work_batch_cockpit" action="focus_existing" outcome="focused" project_path="/users/petepetrash/code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,visible_terminal"
[2026-05-26T21:19:15.520Z] [TerminalActivation] surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree"
```

Result: pass. The terminal icon focused the existing cockpit and did not launch another session.

## Remaining Risk

- This check did not add a new related Task to the already-ready batch. The focused Swift coverage for that policy passed, but a fresh live task-add check is still useful when we can tolerate creating another real test Task.
- This check used AppleScript/system diagnostics and Capacitor traces for Ghostty evidence because Computer Use cannot inspect Ghostty directly in this environment.

## Source-Backed Safe-Wake Coverage

The no-new-session policy for adding a related Task to an existing ready batch is covered by focused Swift tests.

Passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests/testRoutesRelatedTaskToRuntimeReadyExactSessionWakesByDefault|WorkBatchAutoRouterTests/testRoutesRelatedTaskToRuntimeReadyExactSessionWithToolInFlightDefersWake|WorkBatchTaskSessionTests|WorkBatchDeliveryPolicyTests'
```

Result:

- 41 tests passed.
- `testRoutesRelatedTaskToRuntimeReadyExactSessionWakesByDefault` proves a related Task added to the exact runtime-ready session wakes the existing cockpit with `Assessing updated tasks...` and does not launch a new terminal script.
- `testRoutesRelatedTaskToRuntimeReadyExactSessionWithToolInFlightDefersWake` proves Capacitor queues the Task without waking the session when the exact ready session still has tools in flight.
- `WorkBatchDeliveryPolicyTests` covers checkpoint wait, duplicate-cockpit wait, queue-only, stale binding resume, and repeated-wake suppression.
- `WorkBatchTaskSessionTests` covers assigned Claude session IDs, batch worktree launch/resume, manual focus-before-resume, visible cockpit wake input, and the operator-facing visible prompts.

Script and formatting checks also passed:

```bash
bats tests/dev-scripts/check-terminal-activation-state.bats tests/dev-scripts/restart-app.bats
./scripts/ci/swiftformat-lint.sh
git diff --check
```

Result:

- 6 Bats tests passed.
- SwiftFormat reported 0 files requiring formatting.
- `git diff --check` reported no whitespace errors.
