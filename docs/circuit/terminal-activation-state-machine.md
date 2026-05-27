# Terminal Activation State Machine

Scope: Capacitor Debug, Claude Code, Ghostty, tmux, Work Batches, and project-card re-entry.

This document defines how Capacitor decides what to do when the user clicks a project or Work Batch surface. The product rule is simple: prefer re-entering the correct visible cockpit; explain ambiguity; launch only when existing evidence is not enough.

## Source-Backed Anchors

| Area | Source | Current responsibility |
|---|---|---|
| UI primary project click | `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift` | Resolves project-card action, tries Work Batch surfaces first, and falls back to legacy project terminal only when no managed surface applies. |
| Work Batch open rules | `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift` | Pending checkpoint wins; one active bound batch opens; ambiguous active batches show Project Detail. |
| Cockpit binding re-entry | `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift` | Reconciles bindings, blocks unsafe duplicate cockpit cases, and delegates focus/resume to the task-session coordinator. |
| Claude resume/focus | `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift` | Focuses visible Work Batch cockpits first, resumes assigned Claude sessions only when allowed, and writes focus/resume trace events. |
| Activation coordinator | `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift` | Orders direct Ghostty focus, tmux client resolution, tmux switch, post-switch focus, and launch fallback. |
| Terminal driver | `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift` | Reads Ghostty window/tab/terminal snapshots and activates the best existing route before launch. |
| Launch facade | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` | Wires activation policy, tmux routing, terminal drivers, final launch, and the narrow automation environment for shell/AppleScript helpers. |
| Restart hygiene | `scripts/dev/restart-app.sh` | Launches the repo-built Capacitor Debug app, removes older duplicate debug app processes, and rejects non-Debug Capacitor processes after LaunchServices opens the new build. |

## State Machine

```text
Click surface
  |
  v
Resolve intent
  |-- Project card / Activity / Dock
  |     |-- pending Work Batch checkpoint -> Project Detail + checkpoint focus
  |     |-- one safe active/bound Work Batch -> Work Batch cockpit
  |     |-- ambiguous active batches -> Project Detail
  |     `-- no Work Batch surface -> legacy project terminal activation
  |
  |-- Work Batch card
  |     |-- pending checkpoint -> checkpoint row/form
  |     `-- no pending checkpoint -> Work Batch cockpit
  |
  |-- Checkpoint row -> Project Detail + focused checkpoint answer
  |
  `-- Terminal icon -> Work Batch cockpit, bypassing checkpoint-first review

Work Batch cockpit
  |
  v
Reconcile binding against latest runtime sessions
  |-- duplicate cockpit for the batch -> bail with plain error
  |-- duplicate assigned Claude process -> focus only; do not resume
  `-- usable binding -> continue

Focus existing cockpit
  |
  v
Ghostty direct focus by batch worktree/project path/title/session hint
  |-- focused -> done
  |-- already selected and tmux route is not trusted -> done
  |-- already selected and trusted runtime tmux route exists -> continue to tmux switch
  |-- not found -> continue
  `-- automation failure -> bail

tmux route
  |
  v
Resolve existing tmux client
  |-- client exists -> ensure/switch target session, then focus switched terminal
  |-- no client and existing terminal already selected -> done
  `-- no client and no existing terminal -> launch attach/create terminal

Post-switch focus
  |
  |-- focused/already selected -> done
  |-- terminal gone -> launch attach/create terminal
  `-- automation failure -> bail

Claude resume
  |
  |-- Work Batch binding is stale/waiting and focus failed, with resume allowed -> launch `claude --resume <assigned-session-id>` in the batch worktree
  `-- resume not allowed -> bail
```

## Evidence Order

1. Work Batch binding and batch worktree.
2. Pending checkpoint state.
3. Visible Ghostty snapshot: window, selected tab, terminal title, terminal working directory.
4. Assigned Claude session ID and duplicate-process scan.
5. Runtime/tmux route: client TTY, session, target pane.
6. Legacy project path and generated tmux session name.
7. Fresh launch fallback.

## Instrumentation Contract

Every activation path writes structured lines to `~/.capacitor/runtime/app-debug.log` with prefix `[TerminalActivation]`.

Required fields:

| Field | Meaning |
|---|---|
| `surface` | User or subsystem surface, such as `project_card`, `work_batch_card`, `checkpoint_row`, `terminal_icon`, `activity_panel`, `activation_flow`, or `work_batch_session`. |
| `route` | Chosen route, such as `work_batch_primary`, `checkpoint_review`, `work_batch_cockpit`, `direct_focus`, `tmux_client`, `tmux_switch`, `claude_resume`, or `launch`. |
| `action` | The concrete action attempted: focus, switch, resume, launch, show detail, show checkpoint, bail. |
| `outcome` | Result: focused, already_selected, detail, needs_input, switched, launched, resume_launched, blocked_no_binding, failed. |
| `project_path` / `project` | Present when project identity is known. |
| `batch_id` / `batch` | Present for Work Batch paths. |
| `session` | Present when a tmux or Claude session name/id is known. |
| `evidence` | Comma-separated evidence that justified the route. |
| `reason` | Optional error, checkpoint id, TTY, or failure detail. |

Example:

```text
[TerminalActivation] surface="project_card" route="work_batch_primary" action="open_work_batch" outcome="cockpit" project_path="/Users/pete/Code/parable-school" batch="Typeface unification" evidence="single_or_priority_batch"
[TerminalActivation] surface="activation_flow" route="tmux_switch" action="ensure_and_switch" outcome="switched" session="Typeface unification" evidence="client_tty:/dev/ttys003,target_pane:%12"
```

## Failure-Mode Matrix

| Scenario | Intended behavior | Evidence used | Coverage |
|---|---|---|---|
| Ghostty frontmost, selected tab already at target project/worktree | Activate/focus the existing terminal and do not launch. | Ghostty snapshot, selected tab, working directory. | `GhosttyTerminalDriverTests`, `TerminalActivationCoordinatorTests`. |
| Ghostty background window has selected tab at target project/worktree | Bring that window forward; do not treat the unrelated front window as the target. | Ghostty window `isFront`, selected tab, working directory. | `GhosttyTerminalDriverTests`. |
| Target is in a different Ghostty tab | Select the tab, focus terminal, activate window. | Ghostty tab id and terminal working directory/title. | `GhosttyTerminalDriverTests`. |
| Project-root manual terminal exists, but Work Batch has a batch worktree binding | Prefer batch worktree/binding for Work Batch cockpit; do not silently adopt root session. | Work Batch binding, worktree path, runtime sessions. | `WorkBatchAutoRouterTests`, delivery-policy docs. |
| Non-tmux project terminal exists | Direct focus succeeds before tmux launch. | Ghostty working directory/title. | `TerminalActivationCoordinatorTests`, `TerminalLauncherTests`. |
| tmux client exists for route | Switch the client to the target session and focus the switched terminal. | tmux client TTY, target pane, session name. | `TerminalActivationCoordinatorTests`, `TerminalLauncherTests`, `TmuxRouterTests`. |
| No visible terminal and no tmux client | Launch attach/create terminal. | Negative Ghostty/tmux evidence. | `TerminalActivationCoordinatorTests`. |
| Direct focus says already selected from fallback project evidence | Accept the visible terminal; do not chase a tmux session just because the generated project slug might exist. | Direct focus result plus untrusted fallback route. | `TerminalActivationCoordinatorTests`, `TerminalLauncherTests`. |
| Direct focus says already selected while a trusted runtime tmux route exists | Continue through tmux switch so stale selected CWD does not mask the intended tmux session. | Direct focus result plus runtime route, host TTY, or pane evidence. | `TerminalActivationCoordinatorTests`, `TerminalLauncherTests`. |
| Stale Work Batch binding with visible cockpit | Focus first; resume only if focus fails and policy allows resume. | Binding status, visible terminal focus result. | `WorkBatchTaskSessionTests`, `WorkBatchAutoRouterTests`. |
| Duplicate Claude processes for the assigned session id | Focus existing process only; do not start another resume. | Assigned Claude session id process scan. | `WorkBatchAutoRouterTests`. |
| Multiple Claude Code sessions match one Work Batch | Bail with a plain ambiguity error. | Runtime session reconciliation issues. | `WorkBatchAutoRouterTests`. |
| Multiple active Work Batches for a project | Show Project Detail rather than guessing. | Work Batch projection. | `WorkBatchProjectPrimaryActionResolverTests`. |
| Pending checkpoint exists | Primary open goes to the checkpoint surface; terminal icon still opens cockpit. | Work Batch checkpoint projection. | `WorkBatchOpenActionResolverTests`, `AppStateWorkBatchOpenTests`. |
| Duplicate Capacitor Debug processes after restart | Keep newest debug app process so manual clicks target the latest build. | Debug app binary path, newest PID. | `RestartAppScriptTests`, live `pgrep` check. |
| Release app and debug app both installed | Restart script launches and activates Capacitor Debug by PID, not bundle name. Any other Capacitor app process is unsafe and gets stopped or reported. | Debug app path, PID-targeted System Events activation, non-Debug process scan. | `restart-alpha-stable` manual check, dev-script Bats. |
| Debug app is running from the right path but sources changed afterward | Manual verification fails before UI testing and tells the operator to restart. | Debug app binary, bundled Rust artifacts, Swift/Rust source mtimes. | `check-terminal-activation-state` Bats. |
| Capacitor Debug was launched from Codex or another agent host | Debug app launch uses a narrow env; terminal automation uses a narrow env; terminal-launched commands explicitly drop no-color flags. Do not forward host secrets, Codex paths, `NO_COLOR`, or `TERM=dumb` into user-facing terminals. | `TerminalAutomationEnvironment`, restart app env builder, command wrapper. | `TerminalLauncherTests`, `GhosttyTerminalDriverTests`, `restart-app` Bats. |
| Ghostty was already running with polluted environment | New Claude/tmux commands still start through `env -i HOME=... TERM=... PATH=... /bin/sh -c ...`. Existing already-running shells or Claude processes keep their old environment until the user closes/relaunches them. | Ghostty process env, launched command wrapper. | `TerminalLauncherTests`, live process-env check. |

## Live Manual Checklist

Use `scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost` before each manual UI check. If it reports a non-Debug Capacitor process or stale Debug bundle, stop and restart before testing. Then use `scripts/dev/check-terminal-activation-state.sh` after each click to capture the activation trace. Capture notes under `docs/circuit/proofs/operator-product-loop/`.

1. Restart with `./scripts/dev/restart-alpha-stable.sh`.
2. Run `scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`.
3. Raw-click a Project card with one active Work Batch.
   - Expected: correct existing Ghostty/Claude cockpit foregrounds.
   - Expected: no new Ghostty window, no duplicate Capacitor Debug process, no duplicate Claude resume.
   - Expected log: `surface="project_card"` followed by lower-level focus/switch/resume/launch trace.
4. Open Project Detail and click a Work Batch card body.
   - Expected: if no pending checkpoint, cockpit opens.
   - Expected log: `surface="work_batch_card" route="work_batch_cockpit"`.
5. Click the Work Batch terminal icon.
   - Expected: cockpit opens even if the batch has a checkpoint.
   - Expected log: `surface="terminal_icon" route="work_batch_cockpit"`.
6. Click a pending checkpoint row.
   - Expected: Project Detail remains focused on the checkpoint answer UI.
   - Expected log: `surface="checkpoint_row" route="checkpoint_review"`.
7. Force a different Ghostty window/tab to the front, then repeat Project card and Work Batch card clicks.
   - Expected: target cockpit is selected and foregrounded.
8. Confirm launch-last behavior.
   - Expected: new Ghostty tab/window appears only when no usable visible terminal/tmux client exists.
