## Handoff — 2026-03-02 (session 2)

### Changed
- Completed S-007 (orphan detection + bookmark system removal)
- Completed S-008 (simplify managed TTY to minimal client tracking)
- Completed S-009 (fix cancellation-unsafe Task.sleep patterns)
- Removed `lastMatchedGhosttyTabIndex`, `tryBookmarkedGhosttyTab`, `bookmarkWasCleared`, all orphan detection (D-005/D-007/D-008/D-009)
- Removed `isGhosttyHoldingTty` TTY liveness helper
- Removed `managedClientTty` stored property, `isTtyAlive` method, `resolveTmuxClient` method
- Simplified `performUnifiedActivation` — 3 fewer params (managedTty, isTtyAlive, onManagedTtyUpdate)
- Replaced all 8 `try? await Task.sleep(...)` with `do { try await ... } catch { return }`
- Deleted 7 bookmark tests, 7 TTY/resolver tests; updated 6 unified-activation tests
- TerminalLauncher.swift: ~1900 → ~1744 lines

### Now True (cumulative)
- P2 (open -na): 0 — permanent guard
- P3 (cancellation-unsafe sleep): 0 — all 8 instances fixed
- P4 (pre-activation poll): 0 — permanent guard
- P6 (dead ActivationConfig): 0 — file deleted
- P7 (Rust resolver): 6 remaining (method definition + init param, no callers)
- P8 (managed TTY): 0 — removed entirely
- P9 (orphan detection): 0 — all 19 matches eliminated, denylist enforced
- All tests pass (13 TerminalLauncher tests, full suite minus pre-existing Sparkle SIGABRT)
- Guard script passes in enforcing mode

### Remains
- S-002 (old Rust activate/ module): deferred — entangled with UniFFI export
- S-005 (multi-terminal fallback): 6 matches — deferred to S-010
- S-010 (final collapse): absorbs S-005, rewrites performUnifiedActivation to ~30-line three-branch flow
- P1 (keystroke sim): 2 remaining — Enter key presses for tmux commands
- P5 (multi-terminal fallback): 6 remaining — to be removed in S-010
- P7 (Rust resolver): 6 remaining — vestigial method/init references
- P10 (old Rust activate/): 178 lines — deferred with S-002

### Next Steps
1. Run `scripts/ci/terminal-simplification-guard.sh --status` to confirm baseline
2. Start S-010 (final collapse): rewrites the activation flow to the target 3-branch architecture
   - Absorb S-005: remove iTerm/Terminal.app multi-terminal fallback (6 matches)
   - Collapse performUnifiedActivation + activateProjectSession + launchTerminalAsync into ~30 lines
   - Remove dead helper methods no longer needed
   - Target: TerminalLauncher.swift ≤ 200 lines
3. After S-010: optionally tackle S-002 (Rust activate/ module) if UniFFI regen is acceptable
