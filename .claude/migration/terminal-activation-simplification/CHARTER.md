# Terminal Activation Simplification Charter

Prior migration: `.claude/migration/terminal-activation-v2/` (complete)

## Mission

Reduce TerminalLauncher.swift from ~1900 lines to ~200 by replacing keystroke simulation, pre-activation polling, multi-terminal fallback, orphan detection, and managed-TTY bookmarking with a simple three-branch flow using `open -a Ghostty.app`.

## Target Architecture

```
clickCard(project):
  session = derive tmux session name
  client  = tmux list-clients | first tty

  if client exists:
    tmux switch-client -t session
    focus Ghostty tab (AX routing)

  else if Ghostty is running:
    open -a Ghostty.app /path     ← new tab, no dock icon
    delay → type "tmux new-session -A -s <session>"

  else:
    open -a Ghostty.app --args -e sh -c "tmux new-session -A -s <session> -c <path>"
```

## Invariants

1. All existing tests pass after each slice (260+ tests).
2. No additional Ghostty dock icons are spawned (the `open -na` bug that motivated v1 complexity).
3. Card clicks produce the correct tmux session in the correct Ghostty tab.
4. Each slice deletes replaced logic in the same commit.
5. AX tab routing (GhosttyAXReader) is preserved — it's the one justified complexity.

## Non-Goals

1. Rewriting GhosttyAXReader or AX routing logic.
2. Adding iTerm/Terminal.app support (Ghostty-only).
3. Modifying Rust snapshot/ingest logic.
4. Changing tmux session naming conventions.

## Guardrails

1. Every touched file must be mapped in MAP.csv.
2. Denylist patterns for completed slices are enforced by the guard script.
3. Slices marked `done` cannot retain any declared deletion targets.
4. No temporary adapters without an owning slice and explicit removal target.

## Anti-Pattern Budgets (baseline from audit)

| ID  | Pattern | Count | Target |
|-----|---------|-------|--------|
| P1  | Keystroke simulation (Cmd+T, keystroke, key code) | 3 | 0 |
| P2  | `open -na` (dock icon spawning) | 4 | 0 |
| P3  | `try? await.*Task.sleep` (cancellation-unsafe) | 8 | 0 |
| P4  | Pre-activation poll (`recentLaunchPending`) | 1 | 0 |
| P5  | Multi-terminal fallback (`iTermRunning\|terminalApp.*fallback`) | 6 | 0 |
| P6  | Dead ActivationConfig model (`ActivationConfig\|ScenarioBehavior\|ActivationStrategy`) | 41 | 0 |
| P7  | Rust resolver in hot path (`resolveActivationDecision`) | 7 | 0 |
| P8  | Managed TTY state (`managedClientTty`) | 5 | 0 |
| P9  | Orphan detection (`orphan\|bookmarkWasCleared\|lastMatchedGhosttyTabIndex`) | 19 | 0 |
| P10 | Old Rust activate/ module | 178 lines | 0 lines |

## Session Protocol

Session start:
1. Read this charter.
2. Read DECISIONS.md.
3. Read all `in_progress` slices in SLICES.yaml.
4. Run `scripts/ci/terminal-simplification-guard.sh --status`.

Session end:
1. Update slice status, touched paths, and risks.
2. Write HANDOFF.md with exact next steps.
3. Do not mark a slice `done` unless deletion targets are gone.
