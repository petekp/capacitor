# Terminal Activation Live Diagnostic Hardening

Date: 2026-05-26

## Scenario

Manual terminal checks should not confuse Swift test fixture traces with real operator clicks. The previous diagnostic tailed all `[TerminalActivation]` log lines from the shared app debug log, so recently run unit tests could appear as live evidence.

## Product Policy

- Live click evidence must be recent.
- Live click evidence must come from believable operator project paths, not test fixture roots.
- If no believable recent activation trace exists, the diagnostic should say that plainly instead of showing stale or synthetic data.

## Source Changes

- `scripts/dev/check-terminal-activation-state.sh`
  - Added a source-only test mode.
  - Added fixture filtering for synthetic paths such as `/tmp/...`, `/path/to/...`, `/var/folders/...`, `/Users/pete/Code/...`, and known synthetic `batch-mobile` rows.
  - Added a default 30-minute trace window, configurable through `CAPACITOR_TERMINAL_TRACE_SINCE_SECONDS`.
  - Added `CAPACITOR_TERMINAL_TRACE_NOW_EPOCH` for deterministic tests.
  - Added a GNU `date -d` fallback for source-only test portability outside macOS.
- `tests/dev-scripts/check-terminal-activation-state.bats`
  - Added coverage that fixture activation traces are hidden.
  - Added coverage that stale live traces are hidden while recent live traces remain visible.

## Verification

Passed:

```bash
bats tests/dev-scripts/check-terminal-activation-state.bats
bats tests/dev-scripts
git diff --check
```

Focused result:

- 2 focused diagnostic tests passed.
- The focused diagnostic tests were rerun after adding the GNU date fallback and still passed.

Dev-script result:

- 73 Bats tests passed.

Live diagnostic result:

```text
timestamp: 2026-05-26T20:58:49Z
front_app: Dia
capacitor_debug_processes:
7555 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
capacitor_release_processes:
ghostty_windows:
tmux_clients:
tmux_sessions:
arc-design-studio|0|1
capacitor|0|1
capacitor-circuit|0|1
circuit|0|1
parable-school|0|1
pete-2025|0|1
claude_processes:
875 manual
recent_terminal_activation_trace:
none within 1800s after fixture filtering
```

Follow-up process inspection showed the transient `claude` process was gone before it could be inspected, so it was not treated as stable cockpit evidence.

## Remaining Risk

- The filter intentionally hides `/tmp/...` and `/var/folders/...` project paths. That is correct for the current local proof because real operator projects live under `/Users/petepetrash/Code/...`, but this script should be revisited before using it as a general diagnostic for arbitrary project roots.
- This hardens the evidence path. It does not by itself prove that a fresh Project card or Work Batch card click re-enters the right cockpit. The next live manual check should click a real card and confirm that a fresh non-fixture trace appears.
