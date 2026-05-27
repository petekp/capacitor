# Terminal Activation: Ghostty Title Match Hardening

Date: 2026-05-26

## Scenario

A live Project-card check exposed a second legacy terminal fallback bug after the Debug app restart.

The visible Ghostty cockpit for `pete-2025` existed, but runtime route evidence was unavailable and the Ghostty snapshot did not provide a structured working directory. The only usable evidence was a shell-style title:

```text
petepetrash@Petes-MacBook-Pro-2025:~/Code/pete-2025 - zsh
```

Capacitor failed to recognize that title as the project cockpit and launched a new Ghostty/tmux attachment.

## Failure Evidence

Strict Debug preflight passed before the click:

```text
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_release_processes:
claude_processes:
fixture_activation_trace: none
```

The runtime service had no trusted shell route for pinned projects:

```text
shells: []
route: NO_TRUSTED_EVIDENCE
```

Clicking the `pete-2025` Project card produced a launch path:

```text
[2026-05-27T00:35:47.599Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-27T00:35:47.889Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="relaunch_needed" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-27T00:35:47.907Z] [TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="none" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_absent"
[2026-05-27T00:35:48.113Z] [TerminalActivation] surface="activation_flow" route="launch" action="launch_terminal" outcome="launched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="terminal_driver:Ghostty,tmux_attach_command"
[2026-05-27T00:35:48.114Z] [TerminalActivation] surface="activation_flow" route="launch" action="launch_tmux_attach" outcome="launched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="no_existing_terminal,no_tmux_client"
```

## Product Policy

When no managed Work Batch surface applies, legacy project-card fallback should still prefer an existing Ghostty cockpit over launch.

Title evidence is valid only when it can be conservatively normalized into a project path. For shell titles, Capacitor should strip known shell suffixes such as ` - zsh` after extracting the path candidate. It should not strip arbitrary suffixes that could be part of a real title or path.

## Source Changes

- `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
  - Trims Ghostty window, tab, and terminal IDs while parsing snapshots.
  - Drops snapshot rows with blank or whitespace-only window IDs.
  - Strips known shell title suffixes only from extracted title path candidates.
  - Keeps filesystem project paths and terminal working directories literal.
  - Keeps unknown suffixes intact so weak title evidence cannot overmatch.
- `apps/swift/Tests/CapacitorTests/GhosttyAutomationClientTests.swift`
  - Added coverage for skipping whitespace-only window IDs.
  - Added coverage for matching a host-prefixed home-path title with a shell suffix and no working-directory field.
  - Added coverage for matching an ellipsized title path with a shell suffix.
  - Added coverage proving unknown title suffixes are not stripped into path evidence.
  - Added coverage proving real filesystem paths ending in ` - zsh` are not collapsed to a sibling path.

## Adversarial Review Finding

The first implementation stripped known shell suffixes through the shared path normalizer. That was too broad: the same normalizer also handles actual `projectPath` and terminal `workingDirectory` values.

Failure mode:

```text
/Users/pete/Code/foo - zsh
```

could become:

```text
/Users/pete/Code/foo
```

That could make Capacitor fail to find the real project cockpit, or worse, match a sibling project. The fix scopes shell-suffix stripping to title-derived evidence only.

## Verification

Passed:

```bash
swift test --package-path apps/swift --filter GhosttyAutomationClientTests/testBestGhosttyRouteMatchAcceptsHostPrefixedHomePathTitleWithShellSuffix
swift test --package-path apps/swift --filter GhosttyAutomationClientTests
swift test --package-path apps/swift --filter 'GhosttyAutomationClientTests|GhosttyTerminalDriverTests|TerminalActivationCoordinatorTests|TerminalLauncherTests'
./scripts/ci/swiftformat-lint.sh
swift test --package-path apps/swift
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
```

Results:

```text
Focused title-match regression: passed.
Focused Ghostty automation parser/matcher suite: 19 tests passed.
Focused terminal stack: 76 tests passed.
SwiftFormat lint: 0 files require formatting.
Full Swift verification: 952 XCTest cases, 1 skipped, 0 failed; 19 Swift Testing tests, 0 failed.
git diff --check: passed.
Canonical Debug restart: passed.
Strict Debug preflight: Debug app pid 63829 frontmost, no release/non-Debug Capacitor processes, no Claude processes.
```

## Live Retest

After rebuilding and relaunching, clicking the `pete-2025` Project card produced no launch entries:

```text
[2026-05-27T00:41:11.917Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-27T00:41:11.918Z] [TerminalActivation] surface="project_card" route="legacy_project_terminal" action="activate_terminal" outcome="started" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="project_path,manual_override"
[2026-05-27T00:41:12.362Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-27T00:41:12.376Z] [TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="resolved" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_present" reason="/dev/ttys001"
[2026-05-27T00:41:12.383Z] [TerminalActivation] surface="activation_flow" route="tmux_switch" action="ensure_and_switch" outcome="switched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys001,target_pane:none"
[2026-05-27T00:41:12.659Z] [TerminalActivation] surface="activation_flow" route="post_switch_focus" action="focus_switched_terminal" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys001,session_hint"
```

A second live Project-card click pass from Computer Use also fired the raw card path and foregrounded Ghostty:

```text
timestamp: 2026-05-27T00:48:01Z
front_app: ghostty
front_app_path: /Applications/Ghostty.app
ghostty_windows:
pete-2025:1:zsh - ""
tmux_clients:
/dev/ttys001|pete-2025|1779842832
```

Recent activation trace from that pass:

```text
[2026-05-27T00:47:12.122Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-27T00:47:12.544Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-27T00:47:12.557Z] [TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="resolved" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_present" reason="/dev/ttys001"
[2026-05-27T00:47:12.565Z] [TerminalActivation] surface="activation_flow" route="tmux_switch" action="ensure_and_switch" outcome="switched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys001,target_pane:none"
[2026-05-27T00:47:13.321Z] [TerminalActivation] surface="activation_flow" route="post_switch_focus" action="focus_switched_terminal" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys001,session_hint"
```

The repeated raw clicks produced repeated focus/switch traces, but no `launch_terminal` or `launch_tmux_attach` entries.

After the adversarial title-normalizer fix, Capacitor was rebuilt, relaunched, and checked again:

```text
timestamp: 2026-05-27T00:53:24Z
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_debug_processes:
79845 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
capacitor_release_processes:
claude_processes:
```

The post-restart raw Project-card click on `pete-2025` produced:

```text
[2026-05-27T00:53:42.598Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-27T00:53:42.598Z] [TerminalActivation] surface="project_card" route="legacy_project_terminal" action="activate_terminal" outcome="started" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="project_path,manual_override"
[2026-05-27T00:53:43.153Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-27T00:53:43.153Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="accept_existing" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="already_selected,tmux_route_untrusted"
```

Result: the latest binary accepted the existing Ghostty cockpit directly and produced no launch or tmux-switch entry.

After the ellipsized-title hardening, Capacitor was rebuilt and relaunched again:

```text
timestamp: 2026-05-27T00:57:41Z
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_debug_processes:
86521 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
capacitor_release_processes:
claude_processes:
```

The final post-restart raw Project-card click on `pete-2025` produced:

```text
[2026-05-27T00:57:54.119Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-27T00:57:54.119Z] [TerminalActivation] surface="project_card" route="legacy_project_terminal" action="activate_terminal" outcome="started" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="project_path,manual_override"
[2026-05-27T00:57:54.565Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-27T00:57:54.565Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="accept_existing" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="already_selected,tmux_route_untrusted"
```

Result: the final latest-binary live check accepted the existing Ghostty cockpit directly and produced no launch or tmux-switch entry.

## Result

Pass for the source-backed title parser fix and current-state live retest.

Important nuance: the first failing click had already created a `pete-2025` tmux client. The post-fix live retest proves Capacitor did not launch another session in that current state. The original title-only match shape is covered by the new regression test, not by a perfectly reset live recreation.

## Remaining Risk

Runtime route evidence can still be absent for a visible Ghostty cockpit. Capacitor now has better direct Ghostty fallback, but the project-card path still needs more real-world matrix coverage across Ghostty front/background, selected/different tab, tmux/non-tmux, and stale binding cases.
