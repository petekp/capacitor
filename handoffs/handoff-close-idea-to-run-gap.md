# Resume: Close Idea-to-Run Gap via Autonomous Ratchet

## Mission

Use `/method:autonomous-ratchet` to close the remaining idea-to-run orchestrator gaps autonomously. The orchestrator system is ~90% complete — the core pipeline (idea capture → method selection → run creation → checkpoint → review → decision → next phase) is fully wired end-to-end. The remaining ~10% is UI gaps and production hardening that can be ratcheted without human steering.

## Immediate Action

Invoke the autonomous ratchet method skill:
```
/method:autonomous-ratchet Close the remaining idea-to-run gap items documented in docs/orchestrator/idea-to-run-gap.md under "Remaining Gaps". The orchestrator's end-to-end pipeline is wired but missing: (1) phase progression UI, (2) checkpoint history/timeline, (3) method run completion UI, and (4) production hardening. Feature flag: isMethodRunnerEnabled (frontier profile).
```

## Current State

### Already done and working
- Idea capture → method selection → run creation: `IdeaCapturePopover` → `MethodSelectorView` → `AppState+MethodRunner.runMethodOnIdea()` → `MethodRunCoordinator`
- Method execution → checkpoint → review → decision → next phase: fully automatic via `executor.rs` + `BridgeInteractiveIO` + `RunCheckpointReviewWindow`
- Delegation lifecycle cleanup: `cleanupCompletedDelegation()` kills tmux, removes worktree, deletes branch
- Routing deprioritization: managed worktree shells/panes deprioritized (3 regression tests)
- 4 built-in method templates: `execution_only`, `shape_and_execute`, `deep_debug`, `greenfield_build`
- `idea-to-run-gap.md` updated to reflect all closed gaps

### What needs building (the ratchet scope)
1. **Phase progression UI**: Show which phase of a method run is active (e.g., "Phase 2 of 5: Design"). `PhaseInstance` data is available from `RunState` but not surfaced in `ProjectCardView` or `ProjectDetailView`. The `RunVisualState` enum currently only has `.working(statusMessage)`, `.waiting(statusMessage)`, `.none`.
2. **Checkpoint history/timeline**: Show past checkpoints for a run, not just the active one. `RunState.phases` has the data; needs a timeline view.
3. **Method run completion UI**: Surface results when `RunStatus::Completed`. Currently no view exists for this terminal state.
4. **Production hardening**: Edge cases around subprocess lifecycle (crashes, timeouts, reconnection) in `MethodRunCoordinator`.

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- Working tree: dirty — 3 files from this session (Rust routing fix + gap doc update) + 5 pre-existing Swift changes (delegation cleanup code)
- Uncommitted session changes:
  - `core/capacitor-core/src/reduce/mod.rs` — routing worktree deprioritization
  - `core/capacitor-core/src/reduce/tests.rs` — 3 regression tests
  - `docs/orchestrator/idea-to-run-gap.md` — updated closed/remaining gaps

## Key Artifacts
- `/Users/petepetrash/Code/capacitor/docs/orchestrator/idea-to-run-gap.md` — canonical gap analysis, updated 2026-03-27
- `/Users/petepetrash/Code/capacitor/.claude/docs/architecture-primer.md` — agent entrypoint for architecture
- `/Users/petepetrash/Code/capacitor/docs/ARCHITECTURE.md` — canonical system spec
- `/Users/petepetrash/Code/capacitor/docs/orchestrator/` — 5 current orchestrator docs
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Views/Projects/ProjectRunVisualStateResolver.swift` — current run visual state (extend this)
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift` — checkpoint review surface
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` — subprocess coordinator
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift` — feature flags

## Project Rules
- Always prefix branches with `pkp/`
- Run `cargo fmt` before Rust commits
- Use `./scripts/dev/restart-alpha-stable.sh` to verify Swift changes compile and render
- Feature-flagged code: `isMethodRunnerEnabled` (true in `.frontier`, false in `.stable`)
- Never call Anthropic API directly — invoke `claude` CLI instead
- Write to `~/.capacitor/` (our namespace), read from `~/.claude/` (Claude's namespace)
- UI must match app design language — translucent panels, horizontal bounce, existing patterns
- Dispatch implementation to Codex workers; don't code directly in conversation

## Build / Test / Verify Commands
```bash
# Rust
cargo fmt && cargo clippy -- -D warnings && cargo test -p capacitor-core

# Swift (rebuild + relaunch)
./scripts/dev/restart-alpha-stable.sh

# Full local test pass
./scripts/dev/run-tests.sh

# Formal verification
./scripts/verify/verify.sh --layers 1
```

## Established Decisions
- Routing deprioritization uses path-based detection (`is_path_in_managed_worktree`) not a session role field — avoids FFI changes
- Delegation cleanup is aggressive (immediate on completion, no grace period)
- `delegationLoop` flag intentionally disabled in `.frontier` — only `.dev` + `.frontier`
- Gap doc updated to distinguish closed vs remaining gaps

## Verification State
- Passed: `cargo test -p capacitor-core --lib` (271 tests), `cargo clippy`, `cargo fmt`, `./scripts/dev/restart-alpha-stable.sh`
- Not run: `./scripts/dev/run-tests.sh` (full suite including Swift tests)
- Not run: `./scripts/verify/verify.sh` (formal verification)

## Open Questions / Risks
- The uncommitted changes (routing fix + gap doc) should be committed before the ratchet starts its work
- The pre-existing Swift dirty state (delegation cleanup) may need to be committed or stashed first
- Phase progression UI design: should it be inline in the card or in the detail view? No design decision made yet — let the ratchet propose
- Checkpoint history: list view vs timeline? No decision — let the ratchet propose

## Notes for the Next Agent
- Start by committing the current dirty state (routing fix is verified, gap doc is updated)
- The ratchet should use `./scripts/dev/restart-alpha-stable.sh` as its primary verify command for Swift changes
- `RunVisualState` in `ProjectRunVisualStateResolver.swift` is the natural extension point for phase progression
- The `RunState` from the Rust core already carries `phases: Vec<PhaseInstance>` with `current_phase_index` — the data is there, just needs UI
- All orchestrator docs are current — no need to re-derive architecture context
