# Resume: Orchestrator End-to-End Testing — Frontier Profile

## Mission
The idea-to-method-to-run loop is implemented and compiling. The next session should launch with frontier profile, exercise the full flow interactively, identify issues, and dispatch fixes.

## Resume Point
- Last meaningful action: AX smoke test passed in stable profile; implementation commit `716c3b2` landed
- Next command: `./scripts/dev/restart-alpha-frontier.sh`
- Success criterion: app launches in frontier, idea queue visible, "Run Method" button appears on idea detail overlay, selecting a method creates a run and spawns `method-runner` subprocess

## Instructions for the Next Agent

### Phase 1: Interactive E2E Test

1. Launch with frontier profile: `./scripts/dev/restart-alpha-frontier.sh`
2. Ensure the runtime service is running (check with `./scripts/dev/agent-observe.sh health`)
3. Navigate to a project with ideas in the idea queue
4. Tap an idea → verify "Run Method" button appears alongside "Delegate"
5. Click "Run Method" → verify `MethodSelectorView` appears with 4 methods
6. Select "Execute" → verify:
   - Toast shows "Method run started: Execute"
   - Project card shows "RUNNING" chip and "Running: Execute" context line
   - `method-runner` subprocess spawns (check `ps aux | grep method-runner`)
   - Execution root created at `~/.capacitor/runs/<runID>/`
7. When the method runner hits a gate → verify:
   - Run status transitions to `Paused`
   - Project card shows "CHECKPOINT" chip
   - `RunCheckpointReviewWindow` opens automatically
8. Submit a decision (approve) → verify:
   - Decision relay writes file
   - Bridge polls and unblocks gate
   - Method runner continues to next phase or completes
9. On completion → verify:
   - Run status transitions to `Completed`
   - "RUNNING" chip disappears from project card

### Phase 2: Error Path Testing

1. **Binary not found**: Temporarily rename `target/release/method-runner` and try "Run Method" → should show error toast
2. **Process crash**: Kill the method-runner process mid-run → should mark run as Failed
3. **Runtime service unreachable**: Stop the runtime service and try "Run Method" → should show error toast
4. **Concurrent runs**: Start two different methods on two different projects simultaneously

### Phase 3: Fix Issues

For each issue found, use the appropriate method:
- Bug fixes: `/research-to-implementation` with execution_only pattern
- Design issues: `/research-to-implementation` with shape_and_execute pattern
- For batching: `manage-codex` to dispatch parallel workers

## Current State

### Done
- 2 commits on main: doc sweep (`a0d0a49`) + implementation (`716c3b2`)
- Rust: `list_builtin_methods()` and `find_builtin_method()` on CoreRuntime FFI
- Rust: `--method-id` flag on method-runner binary with 4 embedded YAML defs
- Swift: `MethodSelectorView`, `MethodRunCoordinator`, `AppState.runMethodOnIdea()`
- Swift: `IdeaDetailModal` "Run Method" button, `ProjectDetailView` method selector overlay
- Swift: `ProjectCardView`/`StatusChip` run status indicators
- Swift: `IdeaQueueStatusResolver` with `methodRunning`/`methodCheckpointReady` activities
- Swift: `methodRunner` feature flag (frontier=true, stable=false)
- UniFFI bindings regenerated
- All tests passing: 765 Rust, 23 Swift, AX smoke green

### Not Done
- Full interactive E2E test in frontier profile (AX smoke was stable-only)
- Crash recovery test (method-runner dies mid-phase)
- Concurrent run test
- `method-runner resume` integration (the binary supports it but Swift coordinator doesn't call it yet)

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `716c3b2 feat(orchestrator): wire idea-to-method-to-run loop end-to-end`
- Working tree: clean except 5 untracked handoff files in `handoffs/`
- 9 unpushed commits (checkpoint bridge + doc sweep + implementation)

## Key Artifacts

### New files this session
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` — method picker UI
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` — subprocess lifecycle
- `methods/builtins/*.yaml` — 4 built-in method definitions (embedded in binary via include_str!)

### Critical integration points
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1700-1780` — `runMethodOnIdea()` + `activeRun()`
- `core/capacitor-core/src/bin/method_runner.rs:70-95` — `builtin_method_yaml()` + `materialize_builtin_method()`
- `core/capacitor-core/src/lib.rs:502-510` — FFI surface for method templates
- `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift:103-140` — `RunStatusChip`
- `apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift:60` — `methodRunner` feature flag

### Checkpoint bridge (already working)
- `core/capacitor-core/src/method_runner/checkpoint_bridge.rs` — `BridgeInteractiveIO`
- `core/capacitor-core/src/reduce/run_reducer.rs:233` — EmitCheckpoint → RunStatus::Paused
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1790-1830` — `reconcileRunCheckpointWindowTarget()`
- `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift` — review UI

## Project Rules
- User has ADHD — keep findings focused and actionable
- User prefers long-term structurally sound solutions over quick hacks
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-stable.sh` by default; frontier only when explicitly needed
- Skip hooks (`--no-verify`) for `apps/www/` commits only
- Never call Anthropic API directly — invoke `claude` CLI instead
- Write to `~/.capacitor/`, read from `~/.claude/`

## Established Decisions
- Method runner is a standalone CLI binary, not in-process
- `--method-id` flag materializes embedded YAML to `.method/builtin-definition.yaml` in execution root
- Delegation review and run checkpoint review are separate windows (C-14)
- Checkpoint bridge uses file-based decision relay, not snapshot polling
- Relay side is fail-open (known limitation, documented)
- `checkpoint_id == gate_id` for bridge-managed checkpoints
- Feature flag `methodRunner` gates the UI; frontend profile enables it

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` (765), `swift build`, `swift test` (23), AX smoke (stable)
- Not run: E2E flow in frontier profile, crash recovery, concurrent runs, `method-runner resume` from Swift
- Not run: `./scripts/verify/verify.sh --layers 1,2` (historically times out in CI-like contexts)

## Open Questions / Risks
- **Resume semantics**: If method-runner crashes, does `method-runner resume --root <path>` pick up correctly? The `resume.rs` module exists but MethodRunCoordinator doesn't call it yet.
- **Subprocess environment**: The coordinator sets PATH to include homebrew. Will `compose-prompt.sh` and `codex` be findable in all environments?
- **SendableClosureCaptures warnings**: Two Swift 6 mode warnings in `AppState.swift:1766-1767` — the `self?` capture in a detached Task. Not blocking but should be cleaned up.
- **IdeaQueueStatusResolver**: `methodRunning`/`methodCheckpointReady` cases were added but the resolver doesn't receive run states yet (runs are project-level, not idea-level). The status shows on the card, not the idea queue.
