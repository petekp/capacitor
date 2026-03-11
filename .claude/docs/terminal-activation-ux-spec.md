# Terminal Activation UX Spec

This is the active source of truth for terminal activation behavior.

## Source Of Truth Files

When changing activation behavior, read these first:

- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `apps/swift/Sources/Capacitor/Models/GhosttyAXReader.swift`

Production ownership note:

- Swift owns live terminal activation flow and execution.
- Rust owns runtime inputs and persisted truth, not terminal-UI execution.

## Core Model

Capacitor uses a single-client, session-swapping model:

- one remembered managed TTY when available
- one tmux-attached Ghostty tab when possible
- session switching within that client before opening any new terminal surface
- terminal activation execution in Swift, not in Rust

## Decision Tree

Every card click follows this flow:

```text
1. Resolve a tmux client to use.
   - Reuse the remembered managed TTY if it is still alive.
   - Otherwise adopt any existing tmux-attached Ghostty tab.
   - Otherwise, if a detached tmux session already exists, attach to it.
   - Otherwise create a new tmux session in a new tab or newly launched Ghostty.

2. Ensure the target session exists.
   - If the session exists, switch the resolved client to it.
   - If it does not, create it silently and then switch to it.

3. Focus the terminal.
   - Ghostty: AX-route to the managed tab when possible.
   - iTerm / Terminal.app: use TTY-discovery app activation.
```

## Behavioral Invariants

| # | Name | Rule |
|---|------|------|
| B1 | No tab proliferation | A click must not create a new Ghostty tab or window if a tmux-attached tab already exists. |
| B2 | Session swap over client swap | Project switching means `tmux switch-client`, not spawning another tmux client. |
| B3 | Create on demand | Missing tmux sessions are created silently before switch. |
| B4 | Always activate | Every click brings the correct terminal surface to the foreground. |
| B5 | Latest intent wins | Rapid clicks discard stale requests. |
| B6 | Managed-TTY affinity | Reuse the remembered TTY until it dies. |
| B7 | Graceful recovery | If the managed TTY is gone, adopt another client or create a new surface. |
| B8 | Multi-terminal support | Ghostty gets AX tab routing; iTerm and Terminal.app get TTY-based activation. |
| B9 | Auto-attach detached sessions | If no tmux client exists but a detached session does, attach to it instead of opening a new tab. |

## Scenario Matrix

| ID | Starting State | Expected Behavior |
|----|---------------|-------------------|
| S1 | No terminal, no tmux session | Launch terminal, create session, remember TTY |
| S2 | No terminal, detached session exists | Launch terminal and attach to existing session |
| S3 | Managed tab on session A, session B exists | `switch-client` to B and focus terminal |
| S4 | Managed tab on session A, session B missing | Create B, `switch-client` to B, focus terminal |
| S5 | Managed tab already on target session | Idempotent activation and focus |
| S6 | Managed tab closed, another client exists | Adopt replacement client and switch |
| S7 | Managed tab closed, no clients, no session | Open new tab or terminal and create session |
| S8 | Rapid click A then B | Only B executes |
| S9 | Snapshot unavailable | Use fallback session resolution and ensure + switch flow |
| S10 | Ghostty running, no clients, detached session exists | Attach in current tab without opening a new one |

## Ghostty Routing

Ghostty uses AX-driven tab focus after tmux resolution:

1. Match the managed tab by TTY or tmux session title.
2. Prefer `AXPress` on the matched tab.
3. Fall back to `AXRaise` on the owning window.
4. Fall back again to app activation if AX focus is unavailable.

## Managed-TTY Lifecycle

The managed TTY is revalidated on every activation attempt.
If it is stale, clear it and re-enter resolution instead of trying to switch a dead client.

## Verification

When changing activation behavior, run:

```bash
./scripts/dev/agent-observe.sh paths
./scripts/dev/agent-observe.sh snapshot
cd apps/swift && swift test --filter 'TerminalLauncherTests|GhosttyAXReaderTests'
```

Use `./scripts/dev/agent-observe.sh tail app` while reproducing if you need the
live `TerminalLauncher` log surface. Use `routing-snapshot <project_path>` when
you need to compare runtime evidence against activation decisions.

## Coverage Expectations

These test files are the minimum activation coverage surface:

- `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
- `apps/swift/Tests/CapacitorTests/GhosttyAXReaderTests.swift`

Each scenario in the matrix should map to at least one automated test.
