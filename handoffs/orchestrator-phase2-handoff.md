# Resume: Orchestrator Phase 2 — Status Visibility

## Mission
Make method runs visible to the user. Phase 1 (sandbox routing, idea context, timeout) is implemented and integration-tested. Runs work correctly but are **invisible** — they sit in `created` state forever because the method-runner subprocess never reports progress back to the runtime service. Phase 2 adds Start/Heartbeat mutations, a RunStatusReporter, and run-aware card visuals. Use the `/research-to-implementation` skill to work through each item in sequence.

## Instructions for the Next Agent
Use the `research-to-implementation` method skill. There are three items to implement in sequence. Each builds on the prior:

### Item 3: Start + Heartbeat run mutations (~160-260 lines)
**Goal**: Runs leave `created` state and show liveness.

**Spec** (from `docs/orchestrator-implementation-plan.md` lines 87-131):
- Add `RunMutationKind::Start` — transitions `Created -> Active`, marks phase 0 as active, sets `started_at`, records `status_message`
- Add `RunMutationKind::Heartbeat` — updates `updated_at`, replaces `status_message` if non-empty, rejects terminal runs
- Add `status_message: Option<String>` to: `MutateRunCommand`, `RunState`, `SnapshotRunPayload`, `RuntimeRunMutationRequest`, `RuntimeRunState`
- `Start` must be idempotent (no error if run already started)
- Do NOT reuse `AttachSession` as a start signal

**Files to change**:
- `core/capacitor-core/src/domain/run_types.rs` — add `Start`, `Heartbeat` to `RunMutationKind`; add `status_message` to `MutateRunCommand` and `RunState`
- `core/capacitor-core/src/reduce/run_reducer.rs` — implement `handle_start()` and `handle_heartbeat()`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` — add `status_message` to `RuntimeRunMutationRequest`
- `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift` — extend tests
- `core/capacitor-core/tests/run_kernel_contract.rs` — add reducer contract tests
- `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs` — update scenario
- `core/hud-hook/tests/serve_integration.rs` — add HTTP layer tests

**Test strategy**: Reducer contract for `Create -> Start -> Heartbeat -> AdvancePhase`. Verify `status_message` in snapshot. Extend Swift decode tests.

### Item 4: RunStatusReporter in executor + dispatcher (~220-340 lines)
**Goal**: Real-time progress messages during method execution.

**Spec** (from `docs/orchestrator-implementation-plan.md` lines 132-177):
- New adapter seam: `trait RunStatusReporter` with `NoopRunStatusReporter` and `RuntimeRunStatusReporter`
- Thread through `execute_run()` and `resume_run()`
- Emit `Start` immediately after `RunStarted` event
- Heartbeat at: new phase active, before prompt assembly ("Composing prompt"), before dispatch ("Dispatching Codex"), before gate polling ("Waiting for checkpoint"), after phase completed
- **Key change**: In `worker_dispatch_adapter.rs`, replace the single long `wait_timeout(timeout)` with a loop of shorter waits (e.g., 30s), sending heartbeat each iteration
- Reporter failures must log and continue — never abort the run
- On `resume_run()`, emit immediate heartbeat for the recovered phase

**Files to change**:
- `core/capacitor-core/src/method_runner/mod.rs`
- `core/capacitor-core/src/method_runner/adapters.rs`
- `core/capacitor-core/src/method_runner/run_status_reporter.rs` (NEW)
- `core/capacitor-core/src/method_runner/executor.rs`
- `core/capacitor-core/src/method_runner/resume.rs`
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs`
- `core/capacitor-core/src/bin/method_runner.rs`
- Tests: `adapter_seam.rs`, `checkpoint_bridge.rs`, `run_status_reporter.rs` (NEW)

**Test strategy**: Spy reporter seam tests asserting event order. Runtime-backed integration test capturing `/runtime/run/mutate` payloads. Manual smoke test.

### Item 5: Run-aware card visuals (~180-300 lines)
**Goal**: Project cards show run progress instead of falling back to session state.

**Spec** (from `docs/orchestrator-implementation-plan.md` lines 179-220):
- New `ProjectRunVisualStateResolver` — determines card visual state from run state
- Deterministic run selection: paused+checkpoint wins > active > created; tie-break on newest `updatedAt`
- In `handleRuntimeSnapshotFailureIfFresh(...)`, stop clearing `runStatesByID` on second failure — keep last known state
- Card context line shows `run.statusMessage` (from Item 4 heartbeats)
- Presentation: paused+checkpoint → `.waiting`; active → `.working`; created → fallback

**Files to change**:
- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DockProjectCard.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/StatusChip.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectRunVisualStateResolver.swift` (NEW)
- Tests: `AppStateSessionObservationTests.swift`, `StatusChipsRowTests.swift`, `ProjectRunVisualStateResolverTests.swift` (NEW)

## Resume Point
- Last meaningful action: Completed full integration test of checkpoint bridge round-trip (approve/reject/manifest/persistence/concurrent)
- Next action: Start implementing Item 3 (Start + Heartbeat mutations)
- Success criterion: A method run launched from the app shows "Active" in the snapshot instead of staying "created"

## Current State

### Done and verified
- Phase 1: sandbox routing ($TMPDIR copy-back), idea context (context.json), configurable timeout (--timeout 1800)
- Checkpoint bridge: full round-trip (create → emit → pending → approve/reject → decision file → cleanup)
- Phase 1 adversarial review: 13 findings, 5 addressed (F-02, F-03, F-04, F-08 context tests, F-12 dismissed)
- All Rust tests pass: 769 tests, 0 failures
- Swift builds clean

### Not done
- Runs stay in `created` forever — no Start mutation sent
- No heartbeats during execution — runs are black boxes
- Project cards don't reflect run state — fall back to session/delegation
- `ideaId`/`ideaTitle` not persisted on RunState (deferred to Phase 3)
- Adversarial findings F-01 (prompt injection), F-05 (PID in temp dir), F-09 (--timeout 0) open

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `716c3b2 feat(orchestrator): wire idea-to-method-to-run loop end-to-end`
- Working tree: dirty — 17 files changed (+561/-123), uncommitted
- 9 unpushed commits on main
- **Commit the Phase 1 changes before starting Phase 2**

## Key Artifacts
- `docs/orchestrator-implementation-plan.md` — canonical spec for all 8 items (3 phases)
- `docs/orchestrator-scratchpad.md` — UX issues found during E2E testing
- `docs/orchestrator-adversarial-review.md` — adversarial review of the proposals
- `docs/phase1-adversarial-review.md` — adversarial review of Phase 1 implementation
- `~/.capacitor/runtime/runtime-service.json` — runtime service connection (port 7474 + auth token)

## Runtime Service API
- Endpoint: `http://127.0.0.1:7474`
- Auth: `Bearer <token>` from `~/.capacitor/runtime/runtime-service.json` field `auth_token`
- Mutation: `POST /runtime/run/mutate` with full `MutateRunCommand` JSON body
- Snapshot: `GET /runtime/snapshot` with auth header
- All `MutateRunCommand` fields must be present in JSON (no serde defaults on most fields)

## Project Rules
- User has ADHD — keep findings focused and actionable
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-stable.sh` for app testing (default for agents)
- Skip hooks (`--no-verify`) for `apps/www/` commits ONLY
- Write to `~/.capacitor/`, read from `~/.claude/`
- Prefer long-term structurally sound solutions over quick fixes
- All UI must use translucent panels, match existing design language

## Established Decisions
- Phase 2 items must be done in order: Item 3 → Item 4 → Item 5 (each depends on the prior)
- `Start` is a separate mutation, NOT a reuse of `AttachSession` or first `Heartbeat`
- Heartbeat frequency: ~30s during Codex dispatch; at phase/step transitions otherwise
- Reporter failures are best-effort (log + continue), never abort the run
- `AdvancePhase` semantics unchanged — it completes current phase and activates next

## Verification Commands
```bash
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # All Rust tests (769 currently)
./scripts/dev/restart-alpha-stable.sh  # Rebuild + relaunch app
```

## Integration Test Pattern (for manual verification)
```bash
AUTH_TOKEN=$(python3 -c 'import json; print(json.load(open("$HOME/.capacitor/runtime/runtime-service.json"))["auth_token"])')
# Create run, then verify it transitions from created→active after Start mutation
curl -s -X POST http://127.0.0.1:7474/runtime/run/mutate \
  -H "Authorization: Bearer $AUTH_TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"create","project_path":"/Users/petepetrash/Code/capacitor","run_id":"test-xyz",...}'
# Then send start mutation and check snapshot shows status=active
```

## Open Questions / Risks
- Should `Start` be emitted by the Swift coordinator (immediately after Process.run()) or by the Rust executor (after RunStarted event)? The plan says executor, but coordinator has the process handle — consider both
- Heartbeat during Codex dispatch requires replacing the single `wait_timeout(timeout)` with a polling loop — this changes the timeout semantics subtly (total timeout must still be enforced across all loop iterations)
- Stale active runs: if method-runner crashes after Start, runs stay `active` forever. Consider a TTL/reaper (not in Phase 2 scope, but document the risk)
- Multiple concurrent runs per project are allowed by the reducer — Item 5's visual state resolver needs deterministic selection logic
