# Terminal Integration Activation QA - 2026-03-13

Date: 2026-03-13

## Scope

Rigorous manual QA of terminal integration and activation across:

- Ghostty
- iTerm
- Terminal.app

Focus areas:

- no-client attach-or-create launch
- existing-client activation and focus
- terminal selection correctness
- live tmux client attachment behavior
- activation log and runtime evidence

## Automated Baseline

Completed before and after the live manual pass:

- `bash docs/plans/terminal-host-adapters/guard.sh`
- `bash docs/plans/terminal-routing-foundation/guard.sh`
- `cd apps/swift && swift test`
- `cargo test -p capacitor-core`

## Verification Matrix

| ID | Terminal | Scenario | Expected Result | Result |
|---|---|---|---|---|
| G1 | Ghostty | No-client attach-or-create on `pete-2025` | Ghostty becomes frontmost and a tmux client attaches to `dev` | Pass |
| G2 | Ghostty | Existing-client session switch from `pete-2025` to `sanctuary` | Same Ghostty client moves from `dev` to session `1` | Pass |
| G3 | Ghostty | Stale-pane fallback on `sanctuary` | Ghostty client stays on session `1` and lands on replacement pane after stale route fails | Pass |
| I1 | iTerm | No-client attach-or-create on `pete-2025` | iTerm becomes frontmost and tmux client attaches to `dev` | Pass |
| I2 | iTerm | Existing-client focus on `pete-2025` | Same iTerm client stays frontmost and host-driver focus log is emitted | Pass |
| T1 | Terminal.app | No-client attach-or-create on `capacitor` | Terminal becomes frontmost and tmux client attaches to `capacitor` | Pass |
| T2 | Terminal.app | Existing-client focus on `capacitor` | Same Terminal client stays frontmost and host-driver focus log is emitted | Pass |

## Findings

### Fixed During QA: Host Launch Command Delivery Was Still Brittle

The first rigorous live pass surfaced a real regression in the retained host launch mechanism:

- iTerm and Terminal.app selected the correct app and came frontmost
- but the old `System Events` keystroke path was still brittle for no-client attach-or-create
- in Terminal.app, the live buffer showed a corrupted tmux command:
  - expected: `tmux new-session -A -s 'capacitor' -c '/Users/petepetrash/Code/capacitor'`
  - actual: `tmux newsession A s 'capacitor' c '/Users/petepetrash/Code/capacitor'`

Fix applied in the same session:

- iTerm host launch now uses `write text`
- Terminal.app host launch now uses `do script ... in front window`

Post-fix automated checks passed, and the rerun manual scenarios below all passed.

### Transient QA Hiccup: Capacitor Window Needed Explicit Reopen

During the Ghostty rerun attempt, the AX runner briefly lost sight of the Capacitor window after a restart cycle:

- runner error: `No AX windows were found for com.capacitor.app.debug.`

The issue was transient. Reopening the app window through the Dock `Open` action restored card-click automation, and the Ghostty scenarios below then passed. This was treated as a QA harness recovery step, not as a terminal-integration failure.

## Live Evidence

### Ghostty

#### G1 - No-client attach-or-create

- Setup:
  - detached all tmux clients
  - seeded a fresh Ghostty window on `/Users/petepetrash/Code/pete-2025`
- Action:
  - clicked `ax.project-card.pete-2025`
- Evidence:
  - frontmost app became `ghostty`
  - app log captured:
    - `[TerminalLauncher] launchTerminalWithTmuxSession app=Ghostty session=dev path=/Users/petepetrash/Code/pete-2025`
  - tmux client attached:
    - `/dev/ttys043 dev`

#### G2 - Existing-client session switch

- Setup:
  - retained Ghostty client `/dev/ttys043` on session `dev`
- Action:
  - clicked `ax.project-card.sanctuary`
- Evidence:
  - frontmost app remained `ghostty`
  - the same tmux client moved to:
    - `/dev/ttys043 1`

#### G3 - Stale-pane fallback

- Setup:
  - created replacement pane `%22` in session `1`
  - killed routed pane `%5`
- Action:
  - clicked `ax.project-card.sanctuary`
- Evidence:
  - tmux client `/dev/ttys043` stayed on session `1` and landed on:
    - `1 %22 /Users/petepetrash/Code/sanctuary`
  - app log captured:
    - `[TmuxRouter] stale pane during select-window pane=%5`

### iTerm

#### I1 - No-client attach-or-create

- Setup:
  - detached all tmux clients
  - seeded a fresh iTerm shell on `/Users/petepetrash/Code/pete-2025`
- Action:
  - clicked `ax.project-card.pete-2025`
- Evidence:
  - frontmost app became `iTerm2`
  - app log captured:
    - `[TerminalLauncher] launchTerminalWithTmuxSession app=iTerm2 session=dev path=/Users/petepetrash/Code/pete-2025`
  - tmux client attached:
    - `/dev/ttys041 dev`

#### I2 - Existing-client focus

- Setup:
  - retained the attached iTerm client `/dev/ttys041`
- Action:
  - clicked `ax.project-card.pete-2025` again
- Evidence:
  - frontmost app remained `iTerm2`
  - tmux client remained:
    - `/dev/ttys041 dev`
  - app log captured:
    - `[ITermTerminalDriver] tty=/dev/ttys041 matched=true`

### Terminal.app

#### T1 - No-client attach-or-create

- Setup:
  - detached all tmux clients
  - seeded a fresh Terminal shell on `/Users/petepetrash/Code/capacitor`
- Action:
  - clicked `ax.project-card.capacitor`
- Evidence:
  - frontmost app became `Terminal`
  - app log captured:
    - `[TerminalLauncher] launchTerminalWithTmuxSession app=Terminal session=capacitor path=/Users/petepetrash/Code/capacitor`
  - tmux client attached:
    - `/dev/ttys042 capacitor`

#### T2 - Existing-client focus

- Setup:
  - retained the attached Terminal client `/dev/ttys042`
- Action:
  - clicked `ax.project-card.capacitor` again
- Evidence:
  - frontmost app remained `Terminal`
  - tmux client remained:
    - `/dev/ttys042 capacitor`
  - app log captured:
    - `[TerminalAppTerminalDriver] tty=/dev/ttys042 matched=true`

## Overall Assessment

- Ghostty activation is healthy for no-client attach, live session switching, and stale-pane fallback in this pass.
- iTerm activation is healthy after the direct app-automation fix.
- Terminal.app activation is healthy after the direct app-automation fix.
- The host-adapter migration is validated live for both host terminals.
- The route-first activation flow is validated live across Ghostty, iTerm, and Terminal.app.
- No current terminal-integration or activation regressions were found after the host launch fix.
