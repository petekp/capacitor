# Legacy Project Terminal Direct Focus

Date: 2026-05-26

## Scenario

When a project has no active Work Batch surface, a project-card click falls through to legacy project terminal activation.

This legacy fallback should still prefer an existing visible Ghostty cockpit before creating or chasing tmux. A generated tmux session name is only a guess. It should not pull the user away from a selected non-tmux project terminal unless Capacitor has trusted runtime route evidence for the tmux session or pane.

## Intended Behavior

- If direct Ghostty focus finds an existing terminal by project CWD/title, use it.
- If that direct match is already selected and the tmux route is only fallback/generated, stop there.
- If runtime provides trusted tmux route evidence, continue to tmux switch/focus so stale selected CWD does not mask the intended session.
- Fresh launch remains last resort.

## Source Changes

- `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift` now accepts `switchAlreadySelectedDirectMatchWhenClientExists`.
- `TerminalActivationCoordinator.runActivationFlow` accepts an already-selected direct Ghostty match before tmux resolution when the caller says tmux evidence is untrusted.
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` computes that trust decision from `ActivationPolicyIntent`.
- Runtime route evidence remains trusted when the intent carries a routed terminal app, host TTY, or pane ID for the resolved session.
- `docs/circuit/terminal-activation-state-machine.md` now distinguishes fallback project evidence from trusted runtime tmux routes.

## Automated Verification

Focused activation verification passed:

```bash
swift test --package-path apps/swift --filter 'TerminalActivationCoordinatorTests|TerminalLauncherTests|GhosttyTerminalDriverTests|ActivationPolicyTests'
```

Result: 64 tests passed.

Focused coverage includes:

- fallback direct match accepts the visible terminal before resolving tmux clients;
- runtime tmux route can still switch away from an already-selected CWD match;
- runtime pane/TTY evidence remains trusted even if the terminal app itself falls back;
- stale cache and Ghostty tab/window focus behavior remain covered.

Full Swift verification passed:

```bash
swift test --package-path apps/swift
```

Result: 946 XCTest cases passed with 1 skipped, plus 19 Swift Testing tests passed.

Formatting and whitespace checks passed:

```bash
./scripts/ci/swiftformat-lint.sh
git diff --check
```

## Live Verification

Strict Debug-app preflight passed:

```text
timestamp: 2026-05-26T23:29:05Z
front_app: Capacitor
front_app_pid: 40816
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app

capacitor_debug_processes:
40816 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:
```

Test setup:

- Created a temporary Ghostty tab at `/Users/petepetrash/Code/pete-2025`.
- Clicked the `pete-2025` project card in the running Capacitor Debug app.

Observed no-client direct-focus behavior:

```text
[2026-05-26T23:30:07.329Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="fall_through" outcome="legacy_terminal" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="no_work_batches"
[2026-05-26T23:30:07.330Z] [TerminalActivation] surface="project_card" route="legacy_project_terminal" action="activate_terminal" outcome="started" project_path="/Users/petepetrash/Code/pete-2025" project="pete-2025" evidence="project_path,manual_override"
[2026-05-26T23:30:07.777Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-26T23:30:07.791Z] [TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="none" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_absent"
[2026-05-26T23:30:07.792Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="accept_existing" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="already_selected,no_tmux_client"
```

Then created a temporary tmux client in another Ghostty tab and reselected the non-tmux project tab. The runtime service naturally treated that tmux client as trusted route evidence, so Capacitor correctly followed the trusted route rather than the fallback route:

```text
tmux_clients:
/dev/ttys007|pete-2025|1779838252

[2026-05-26T23:31:18.816Z] [TerminalActivation] surface="activation_flow" route="direct_focus" action="focus_existing" outcome="already_selected" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="ghostty_snapshot,working_directory_or_title"
[2026-05-26T23:31:18.828Z] [TerminalActivation] surface="activation_flow" route="tmux_client" action="resolve_client" outcome="resolved" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="tmux_client_present" reason="/dev/ttys007"
[2026-05-26T23:31:18.836Z] [TerminalActivation] surface="activation_flow" route="tmux_switch" action="ensure_and_switch" outcome="switched" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys007,target_pane:none"
[2026-05-26T23:31:19.065Z] [TerminalActivation] surface="activation_flow" route="post_switch_focus" action="focus_switched_terminal" outcome="focused" project_path="/Users/petepetrash/Code/pete-2025" session="pete-2025" evidence="client_tty:/dev/ttys007,session_hint"
```

Cleanup detached the temporary tmux client:

```text
tmux_clients:
```

## Result

Pass for the source/test-backed fallback policy and live direct-focus behavior.

The exact "tmux client exists but route remains untrusted" branch is hard to produce in the running app because creating a real tmux client gives the runtime service trusted route evidence. That branch is covered by focused tests, and the live run proved the adjacent trusted-runtime route still behaves correctly.
