# Duplicate Cockpit Live Guardrail

Date: 2026-05-26

## Scenario

Capacitor must not silently choose a Claude Code cockpit when more than one Claude-like session matches a Work Batch worktree.

The live app had a completed `parable-school` Work Batch:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Bound session: 23bb3c4f-286f-4957-869b-6d33a6c9fd3f
Worktree: /Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source
```

To avoid launching real extra Claude workers against a user project, the live reproduction used a controlled local process whose argv looked like a Claude process to Capacitor's process scanner:

```text
24161 /private/tmp/capacitor-fake-claude/claude -c import time; time.sleep(300) --resume duplicate-session
cwd: /Users/petepetrash/Code/parable-school/.capacitor/worktrees/batch-typeface-unification-from-source
```

This exercises the same process-scanner condition used by the production duplicate-cockpit guard without touching project files or consuming a real Claude worker session.

## Intended Behavior

- A project card with several possible Work Batches should open Project Detail instead of guessing.
- A specific Work Batch cockpit click should refuse to proceed when duplicate process evidence exists in the batch worktree.
- Capacitor should explain the ambiguity plainly.
- Capacitor should not launch a new Ghostty window, create a new tmux session, or focus an unrelated cockpit.

## Live Evidence

Post-click UI showed:

```text
Multiple Claude Code sessions match Typeface unification from source parable
```

Terminal activation trace:

```text
[2026-05-26T22:29:35.557Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="show_project_detail" outcome="detail" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" evidence="ambiguous_work_batches"
[2026-05-26T22:29:57.630Z] [TerminalActivation] surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="failed" project_path="/Users/petepetrash/Code/parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" session="23bb3c4f-286f-4957-869b-6d33a6c9fd3f" evidence="batch_binding,batch_worktree" reason="Multiple Claude Code sessions match Typeface unification from source parable"
```

Live diagnostic during the duplicate condition:

```text
timestamp: 2026-05-26T22:30:13Z
capacitor_debug_processes:
9714 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:

ghostty_windows:

tmux_sessions:
arc-design-studio|0|1
capacitor|0|1
capacitor-circuit|0|1
circuit|0|1
parable-school|0|1
pete-2025|0|1

claude_processes:
24161 resume=duplicate-session
```

Cleanup verified no controlled duplicate process remained:

```text
ps -axo pid=,command= | awk '/capacitor-fake-claude\/claude|duplicate-session/ && !/SkyComputerUseClient/ && !/awk/ {print}'
# no output
```

## Result

Pass. The live Debug app refused the ambiguous Work Batch cockpit with a plain operator-facing error and did not launch or focus a terminal.

Limitation: this used a controlled Claude-like process instead of a second real Claude Code process. The behavior is still meaningful because the production guard consumes process command/cwd/session evidence, but a future live matrix should include two real visible Ghostty Claude sessions when it is safe to create them.
