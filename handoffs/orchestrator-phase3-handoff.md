# Resume: Orchestrator Phase 3 — Polish (Items 6, 7, 8)

## Mission
Complete Phase 3 of the orchestrator implementation plan. Three items remain: persist idea context in runs (Item 6), redesign MethodSelectorView (Item 7), and wire run state into the idea queue resolver (Item 8). Use the `/research-to-implementation` skill to produce a hardened spec for Item 6 (the largest and most cross-cutting), then dispatch all three items to Codex workers via `/manage-codex`.

## Instructions for the Next Agent

Add a comprehensive set of tasks to your task list that will:

1. **Research + harden the spec for Item 6** using `/research-to-implementation`:
   - Item 6 spans 16 files across Rust + Swift, threading `ideaId`/`ideaTitle`/`ideaDescription` through 4 boundaries (Swift UI → coordinator → CLI → Rust executor → prompt builder)
   - The existing spec at `docs/orchestrator-implementation-plan.md` lines 222-272 says *what* to add but not the exact struct shapes, JSON schemas, serde attributes, or description clamp policy
   - Produce a hardened execution spec that defines: exact `TaskContext` struct shape, `task-context.json` schema, field names at each boundary, description size clamp, and how to split into 2-3 Codex-sized slices
   - The spec must also cover Item 8 (lines 302-333), which depends on Item 6's `ideaId` field

2. **Dispatch Items 6, 8, 7 to Codex workers** using `/manage-codex`:
   - Item 6: Persist idea context (split into slices per the hardened spec)
   - Item 8: Wire run state into idea queue resolver (depends on Item 6)
   - Item 7: Redesign MethodSelectorView with glass overlay (independent, can run in parallel after Item 6 starts)
   - Follow the same implement → review → fix → converge loop used in Phase 2

3. **Post-implementation cleanup**:
   - Regenerate UniFFI bindings after Rust changes (`cargo build -p capacitor-core --release` then `cargo run --release --bin uniffi-bindgen -- generate --library /path/to/target/release/libcapacitor_core.dylib --language swift --out-dir apps/swift/Sources/Capacitor/Bridge`)
   - Run `./scripts/dev/restart-alpha-stable.sh` for visual smoke test
   - Commit each item separately with descriptive messages

## Resume Point
- Last meaningful action: Phase 2 convergence completed and committed
- Next action: Read the Item 6 spec, then invoke `/research-to-implementation` to harden it
- Success criterion: All 3 items implemented, reviewed, converged, and committed

## Current State

### Done (Phases 1 + 2)
- Phase 1: sandbox routing, idea context file, configurable timeout
- Phase 2: Start/Heartbeat mutations, RunStatusReporter, run-aware card visuals
- 786 Rust tests pass, all pre-commit hooks green
- UniFFI bindings regenerated with `statusMessage` field

### Not done (Phase 3)
- Item 6: ideaId/ideaTitle/ideaDescription not persisted on RunState — the Idea is discarded after launching the run
- Item 7: MethodSelectorView uses opaque fixed-width panel instead of glass overlay
- Item 8: IdeaQueueStatusResolver doesn't know about run state — can't show methodRunning/checkpointReady per-idea

### Dirty working tree (unrelated to Phase 3)
- 3 modified files in `core/capacitor-core/src/runtime_contracts/` and `runtime_setup.rs` — appear to be pre-existing uncommitted changes, not from this session. Investigate before committing Phase 3 work.

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `a3db8d1 chore: regenerate UniFFI bindings to include statusMessage in RunState`
- Working tree: 3 dirty files (unrelated runtime_contracts changes)
- 14 unpushed commits on main

## Key Artifacts
- `docs/orchestrator-implementation-plan.md` — canonical spec for all 8 items (lines 222-346 for Phase 3)
- `docs/orchestrator-scratchpad.md` — UX issues found during E2E testing
- `.relay/batch.json` — Phase 2 batch state (completed)
- `~/.capacitor/runtime/runtime-service.json` — runtime service connection info

## Project Rules
- User has ADHD — keep findings focused and actionable
- Always use Codex workers for implementation — never code directly in conversation
- `cargo fmt` required before commits
- Use `./scripts/dev/restart-alpha-stable.sh` for app testing
- All UI must use translucent panels, match existing design language
- Skip hooks (`--no-verify`) for `apps/www/` commits ONLY
- Always encode the implementation boundary explicitly in worker prompts
- Never use zsh globs or `||` chains to check worker output; use `test -f`

## Established Decisions
- Phase 3 items execute in order: 6 → 8 → 7 (Item 7 is independent and can overlap)
- Item 6 needs to be split into 2-3 Codex-sized slices (Rust kernel + CLI, Swift coordinator + mutation, UI + tests)
- The `TaskContext` struct/JSON schema needs to be defined before dispatching workers
- Description clamp policy needs a decision (max chars, truncation behavior)
- UniFFI bindings must be regenerated after any Rust domain type changes

## Verification Commands
```bash
cargo fmt --check
cargo clippy -- -D warnings
cargo test                                    # 786 tests expected
./scripts/dev/restart-alpha-stable.sh         # Visual smoke test
```

## Open Questions / Risks
- What should the description size clamp be? (Spec says "clamps size" but doesn't specify)
- Should `task-context.json` absence on resume be a warning or an error?
- The dirty runtime_contracts files need investigation before committing
- Item 7 (glass overlay) is purely visual and manual-test-only — harder to verify via Codex
