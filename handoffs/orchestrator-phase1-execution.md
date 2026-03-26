# Resume: Orchestrator Phase 1 — Unblock E2E Method Runs

## Mission
Execute Phase 1 of the orchestrator implementation plan: fix the 3 issues that prevent a method run from completing end-to-end. The exploration, adversarial review, and planning are done — this session is pure execution.

## Resume Point
- Last meaningful action: 3-stage planning pipeline completed (proposals → adversarial review → implementation plan)
- Next action: read `docs/orchestrator-implementation-plan.md` and begin executing Phase 1 items
- Success criterion: a method run (Execute or Shape & Execute) completes end-to-end — codex finishes, output is captured, gate fires, checkpoint review window opens

## Instructions for the Next Agent

1. Read `docs/orchestrator-implementation-plan.md` — it has exact file paths, function names, struct fields, and line numbers for all 3 Phase 1 items
2. Read `docs/orchestrator-adversarial-review.md` for the corrections that must be respected
3. Execute the 3 Phase 1 items (parallelizable):
   - **1.1 Sandbox output routing**: Use `$TMPDIR` for the codex `-o` path, copy result back to relay root after completion. Key file: `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
   - **1.2 Idea context in prompts**: Write `context.json` to execution root before dispatch. Prompt builder reads it. Key files: `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs`, `AppState.swift` (pass idea text to coordinator)
   - **1.3 Configurable timeout**: Add `timeout_secs` to method YAML schema + `--timeout` CLI flag. Key files: `core/capacitor-core/src/bin/method_runner.rs`, `methods/builtins/*.yaml`
4. After implementing, rebuild and test: `./scripts/dev/restart-alpha-frontier.sh`
5. Test the full flow: click idea → Run Method → Execute → verify codex completes and output is captured

Use codex workers for parallelizable implementation tasks. Use `manage-codex` or dispatch workers directly.

## Current State

### Done (this session)
- E2E tested the full idea-to-method-to-run loop in frontier profile
- Fixed: `resolve_worker_cwd()` — codex now runs from project dir, not execution root
- Fixed: `StatusChipsRow` — run chips take priority over delegation chips
- Fixed: `IdeaDetailOverlay` — rewrote layout from ZStack to VStack
- Fixed: `FooterView` — hides when detail view is active
- Fixed: frontier profile — workstreams disabled, methodRunner enabled
- Fixed: idea parser — requires ULID-format IDs (26 uppercase alphanumeric)
- Bumped codex timeout 300s → 900s (still not enough for full test suites)
- Cleared stale delegation (Milestone 05 review_needed)
- Added debug logging to `listBuiltinMethods()` and `runMethodOnIdea()`
- Completed 3-stage planning pipeline (proposals + adversarial review + implementation plan)

### Verified Working
- Method-runner binary spawns correctly from Swift coordinator
- Codex dispatches from project directory (CWD fix confirmed)
- compose-prompt.sh found via relative path and CARGO_MANIFEST_DIR fallback
- Runtime service accepts run mutations (create, cancel, complete)
- StatusChip correctly shows STARTING/RUNNING/CHECKPOINT labels
- Checkpoint reconciliation logic verified correct (auto-opens review window)
- 4 builtin methods returned via FFI (execution_only, shape_and_execute, deep_debug, greenfield_build)

### Not Working (Phase 1 targets)
- Codex output not captured: sandbox blocks writes to `~/.capacitor/runs/`, method-runner can't find `last-message.txt`
- Generic dispatch prompt: "Implement the task" with no idea context
- Timeout too short/not configurable: codex needs 15-30+ min for real tasks, can't configure per-method

### Known Issues (Phase 2+, don't fix now)
- Run state stays `status=created` (no AdvancePhase mutation) — needs Heartbeat mutation kind
- Card shows "Starting" forever instead of "working" with striped animation
- Context line shows method name not idea title
- MethodSelectorView needs visual redesign (opaque, breaks bounce)
- IdeaQueueStatusResolver has dead methodRunning/methodCheckpointReady cases
- Run state may not persist across service restarts

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `716c3b2 feat(orchestrator): wire idea-to-method-to-run loop end-to-end`
- Working tree: dirty — 8 modified files + new docs/tests (see below)
- 9 unpushed commits on main

### Modified files (uncommitted)
- `apps/swift/Sources/Capacitor/Models/AppState.swift` — debug logging in listBuiltinMethods/runMethodOnIdea
- `apps/swift/Sources/Capacitor/Support/Config/AppConfig.swift` — workstreams=false in frontier
- `apps/swift/Sources/Capacitor/Views/Footer/FooterView.swift` — hide footer in detail view
- `apps/swift/Sources/Capacitor/Views/Ideas/IdeaDetailModal.swift` — VStack layout rewrite
- `apps/swift/Sources/Capacitor/Views/Ideas/MethodSelectorView.swift` — ScrollView + maxHeight
- `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift` — run chip priority + Presentation enum
- `apps/swift/Tests/CapacitorTests/AppConfigTests.swift` — updated for workstreams=false
- `core/capacitor-core/src/bin/method_runner.rs` — resolve_worker_cwd(), 900s timeout, usage update

### New files (untracked)
- `apps/swift/Tests/CapacitorTests/StatusChipsRowTests.swift` — tests for chip presentation logic
- `docs/orchestrator-scratchpad.md` — running improvement list
- `docs/orchestrator-issue-proposals.md` — 9 structured proposals
- `docs/orchestrator-adversarial-review.md` — critical review with corrections
- `docs/orchestrator-implementation-plan.md` — 10 work items across 3 phases

## Key Artifacts
- `docs/orchestrator-implementation-plan.md` — THE document to execute from. Has exact file paths, functions, struct fields, code snippets
- `docs/orchestrator-adversarial-review.md` — corrections that must be respected (especially: Heartbeat not AdvancePhase, $TMPDIR not project-relative, prompt builder reads context not executor)
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` — where codex `-o` path is set (line ~85)
- `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs` — where prompts are composed
- `methods/builtins/*.yaml` — method YAML definitions (add timeout_secs field)
- `apps/swift/Sources/Capacitor/Models/MethodRunCoordinator.swift` — subprocess lifecycle (needs idea text passed through)
- `~/.capacitor/runs/3c28881d-*/` — last execution root with full event log and attempt artifacts

## Project Rules
- User has ADHD — keep findings focused and actionable
- User prefers long-term structurally sound solutions over quick hacks
- All new UI must match app design language (translucent panels, respect bounce) — see memory
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-frontier.sh` for testing
- Skip hooks (`--no-verify`) for `apps/www/` commits only
- Never call Anthropic API directly — invoke `claude` CLI
- Write to `~/.capacitor/`, read from `~/.claude/`
- Delegate code tasks to codex workers when possible

## Established Decisions
- Method runner is a standalone CLI binary, not in-process
- `--method-id` materializes embedded YAML to `.method/builtin-definition.yaml`
- Checkpoint bridge uses file-based decision relay (fail-open, known limitation)
- `resolve_worker_cwd()` prefers bridge project path → CWD → execution root
- StatusChipsRow: runs take priority over delegation chips
- Footer hides in detail views
- Workstreams disabled in frontier until integrated into idea-to-run flow
- AdvancePhase CANNOT be reused for heartbeats (mutates phase index) — need new Heartbeat mutation
- Sandbox fix uses $TMPDIR, not project-relative path
- Idea context: prompt builder reads context, not executor
- Idea→run mapping lives in Swift AppState, not Rust RunState

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` (765+), `swift build`, AX smoke
- Passed: method-runner dry-run (fake adapters), method-runner --real with CWD fix
- Failed: full E2E run — codex works but output not captured (sandbox), times out at 900s
- Not run: `swift test` (may fail on IdeaCapturePopover flaky test), `./scripts/verify/verify.sh --layers 1,2`

## Open Questions / Risks
- Will `$TMPDIR` codex output survive long-running processes? macOS may clean `/tmp` files
- Is 30 minutes enough timeout for a real implementation task with full test suites?
- The `RawMethodInput` system in the executor — how mature is it? The review says it "already exists"
- Concurrent runs on the same project: no guard exists yet
