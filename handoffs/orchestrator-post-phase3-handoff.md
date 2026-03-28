# Resume: Ghostty Terminal Routing Fix

## Mission
Fix Ghostty terminal tab focusing — the correct tab is often not focused when activating a project. Investigation complete, implementation needed.

## Context
Commit `20b8126` shipped 5 post-phase3 orchestrator fixes (snapshot resilience, sandbox routing, card animation, run GC, stale-run guard). The Ghostty routing issue was investigated but not yet fixed. Full investigation findings at `.relay/investigate/handoffs/handoff-terminal-routing.md`.

## Root Cause (from investigation)
Ghostty loses deterministic identity after tmux resolves the correct client. iTerm and Terminal.app focus by exact TTY via AppleScript, but Ghostty falls back to CWD/title heuristics because its AppleScript API doesn't expose TTY. With multiple terminals in the same repo, this picks the wrong one.

## Failure Modes (priority order)
1. **Ambiguous CWD matches** — multiple tabs in same repo, no deterministic tiebreaker
2. **Post-switch snapshot race** — metadata stale when Capacitor reads Ghostty state after tmux switch
3. **Window-only fallback** — reports "success" without selecting correct tab
4. **In-memory cache miss** — after app restart, heuristics fail silently

## Proposed Fixes (from investigation)
1. Detect ambiguous matches in `bestGhosttyRouteMatch()` — don't pick arbitrarily on tie
2. Add post-switch retry window — poll Ghostty snapshot until metadata updates
3. Narrow window-only fallback — require single-tab window or retry
4. Add focus-path diagnostics — log route source, candidate count, cache hit/miss
5. Add missing tests — duplicate CWD, stale metadata, cache miss, window-only fallback
6. Long-term: use deterministic bridge if Ghostty exposes better identity

## Key Files
- `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift` — snapshot, matching, AppleScript
- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift` — GhosttyTerminalDriver.focus()
- `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift` — activation flow
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` — launch/focus orchestration
- `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift` — tmux session/client resolution

## Repo State
- Branch: `main`
- HEAD: `20b8126 fix(orchestrator): post-phase3 — snapshot resilience, sandbox routing, card animation, run GC`
- Remote: fully pushed
- Working tree: clean (only untracked handoff/relay files)

## Verification Commands
```bash
swift test --package-path apps/swift --filter 'TerminalLauncherTests|Ghostty.*Tests'
swift test --package-path apps/swift
cargo test
./scripts/dev/restart-alpha-stable.sh
```
