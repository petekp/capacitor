# Terminal Activation UX Spec v2

> Canonical path: `.claude/docs/terminal-activation-ux-spec.md`
> Supersedes: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`, `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
> Date: 2026-03-01

## Core Model

**Single-client, session-swapping architecture.** Capacitor manages one tmux client in one Ghostty tab. Card clicks swap the tmux session within that tab. New tabs and windows are only created when no tmux-attached tab exists.

### Decision Tree

Every card click executes this algorithm:

```
1. Resolve a tmux client to use:
   a. Is there a remembered Capacitor-managed TTY that is still alive?
      → YES: use it.
      → NO: continue.
   b. Is there ANY tmux client attached in any Ghostty tab?
      → YES: adopt it (remember its TTY as managed).
      → NO: continue.
   c. Is Ghostty running with at least one window?
      → YES: open new tab, run `tmux new -A -s <session> -c <project-path>`,
        remember TTY. Done (skip step 2).
      → NO: launch Ghostty with `tmux new -A -s <session> -c <project-path>`,
        remember TTY. Done (skip step 2).

2. Switch session on the resolved client:
   a. Does a tmux session for this project already exist?
      → YES: `tmux switch-client -c <tty> -t <session>`.
      → NO: `tmux new -d -s <session> -c <project-path>`,
        then `tmux switch-client -c <tty> -t <session>`.

3. Focus the terminal:
   a. AX-route to the managed tab (Ghostty) or TTY-discover the owning app
      (iTerm / Terminal.app).
   b. Activate the terminal app to the foreground.
```

## Behavioral Invariants

| # | Name | Rule |
|---|------|------|
| B1 | No tab/window proliferation | A card click must never create a new Ghostty tab or window if a tmux-attached tab already exists. |
| B2 | Session-swap not client-swap | Switching projects means `tmux switch-client`, not opening a new tmux client. |
| B3 | Create-on-demand | If no tmux session exists for a project, create one silently before switching. |
| B4 | Always activate | Every card click brings the terminal to the foreground and focuses the managed tab. |
| B5 | Latest-intent-wins | Rapid clicks: only the most recent click's session switch executes; stale requests are discarded. |
| B6 | Managed-TTY affinity | Remember which TTY Capacitor is using. Reuse it until it dies. |
| B7 | Graceful recovery | If the managed TTY disappears, adopt any other tmux client. If none exist, create a new tab. |
| B8 | Multi-terminal support | Ghostty gets full AX tab routing. iTerm/Terminal.app get TTY-discovery activation. |

## Scenario Matrix

| ID | Starting State | User Action | Expected Behavior |
|----|---------------|-------------|-------------------|
| S1 | No Ghostty, no tmux sessions | Click project A | Launch Ghostty → create session A → attach → remember TTY |
| S2 | No Ghostty, session A exists | Click project A | Launch Ghostty → attach to session A → remember TTY |
| S3 | Managed tab on session A | Click project B (session exists) | `switch-client -t B` → AX focus tab → activate Ghostty |
| S4 | Managed tab on session A | Click project B (no session) | Create session B → `switch-client -t B` → AX focus → activate |
| S5 | Managed tab on session A | Click project A (same) | No-op or idempotent switch → AX focus → activate |
| S6 | Managed tab closed by user | Click any project | Detect TTY gone → find any other tmux client → adopt → switch |
| S7 | Managed tab closed, no clients | Click any project | Open new tab → `tmux new -A -s <session>` → remember new TTY |
| S8 | Rapid click A then B (<200ms) | — | Only B executes; A discarded via staleness guard |
| S9 | Core snapshot unavailable | Click any project | Tmux session-name fallback → ensure + switch. Last resort: launch |

## AX Routing Strategy

### Ghostty (full AX routing)

After session switch:

1. Find the managed tab by matching TTY or tmux session title in Ghostty's AX tree.
2. `AXPress` the matched tab to focus it.
3. If tab press fails, `AXRaise` the window.
4. If both fail, `activateAppByName("Ghostty")`.

### iTerm / Terminal.app (TTY discovery)

1. Use TTY-discovery to identify which app owns the managed TTY.
2. Activate that app via `NSWorkspace`.
3. No tab-level routing (app-level activation only).

### Future: iTerm / Terminal.app AX Routing

Investigate AX tree structure for tab-level focus parity with Ghostty. Track as a separate enhancement.

## Managed-TTY Lifecycle

```
                    ┌─────────────────────┐
                    │  No managed TTY     │
                    │  (app launch / cold) │
                    └─────────┬───────────┘
                              │ card click
                              ▼
                    ┌─────────────────────┐
          ┌────────│  Resolve TTY        │────────┐
          │        └─────────────────────┘        │
          │ found any client                      │ no clients
          ▼                                       ▼
┌──────────────────┐                    ┌──────────────────┐
│ Adopt client TTY │                    │ Launch / open tab │
│ Remember as      │                    │ tmux new -A -s    │
│ managed TTY      │                    │ Remember new TTY  │
└────────┬─────────┘                    └────────┬─────────┘
         │                                       │
         └──────────────┬────────────────────────┘
                        │
                        ▼
              ┌──────────────────┐
              │  Managed TTY     │◄──── card clicks use this
              │  (active)        │      for switch-client
              └────────┬─────────┘
                       │ TTY dies (tab closed)
                       ▼
              ┌──────────────────┐
              │  Managed TTY     │──► back to Resolve TTY
              │  (stale)         │    on next card click
              └──────────────────┘
```

Staleness detection: before each `tmux switch-client -c <tty>`, verify the TTY is still alive. If not, clear it and re-enter resolution.

## Deprecated

This spec supersedes:

- `docs/TERMINAL_ACTIVATION_UX_SPEC.md` — high-level, references old daemon architecture
- `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md` — references daemon IPC, outdated scenarios

Deprecated concepts:

- Rust resolver choosing between distinct action kinds (`SwitchTmuxSession` vs `LaunchNewTerminal` vs `EnsureTmuxSession`) as independent strategies. The new model uses one unified flow on the Swift side.
- Tab-per-project model (each project gets its own Ghostty tab).
- Daemon-based routing IPC.

Retained from old spec:

- Latest-intent-wins / staleness guard (now B5).
- Reuse-first principle (now B1, B2).
- Single-fallback rule (now B7).

## Test Coverage

Automated tests must cover:

1. `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` — unified activation flow
2. `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift` — executor routing
3. `core/capacitor-core/src/` — Rust resolver unit tests

Each scenario in the matrix (S1–S9) should have at least one corresponding automated test.
