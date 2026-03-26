# Resume: Contract Audit + Dead Code Sweep for Real Adapter Layer

## Mission
Exhaustively verify the just-shipped real adapter layer (commit `2f78f07`) against its execution packet contract, then sweep the entire `method_runner` module tree for dead code, orphaned artifacts, stale references, and cruft. The implementation must be immaculate — zero spec gaps, zero unused code.

## Resume Point
- Last meaningful action: Committed 7-slice real adapter implementation (IF1 ShellPromptBuilder + IF2 CodexWorkerDispatcher)
- Next action: Create task list below, then execute both audits systematically
- Success criterion: Every finding documented, every fixable issue fixed, full 710-test suite still green

## Instructions

**Before doing anything else, create the following tasks in your task list using TaskCreate:**

### Task Group A: Contract Audit (verify implementation vs execution packet)

1. **Audit INV-1: Explicit seam data** — Read `executor.rs` dispatch_attempt_workers() and verify that template, merged skills, and prompt_path are all passed explicitly through DTOs, never inferred from relay_root layout or .method/ files. Cross-reference with T27 test in `adapter_seam.rs`.

2. **Audit INV-2: Executor stays shell-agnostic** — Run `rg -n "Command::new|wait_timeout|killpg|compose-prompt|codex exec" core/capacitor-core/src/method_runner/executor.rs` and confirm zero matches. Also visually scan for any subprocess-adjacent logic.

3. **Audit INV-3: Preflight-or-fail** — Read `adapter_config.rs` AdapterConfig::new() and verify script_path and codex_path validation. Read `prompt_builder_adapter.rs` and verify skill/template preflight happens BEFORE subprocess spawn. Cross-reference with T2, T3, T21, T22, T23.

4. **Audit INV-4: Process-group containment** — Read `worker_dispatch_adapter.rs` timeout escalation code. Verify: (a) process_group(0) on spawn, (b) SIGTERM to group on timeout, (c) grace period wait, (d) SIGKILL to group if still alive. Cross-reference with T12, T13, T14.

5. **Audit INV-5: Worker outcome is not adapter failure** — Verify that non-zero codex exit returns Ok(WorkerDispatchResult) not Err(AdapterError). Cross-reference T10.

6. **Audit INV-6: Absolute paths** — Grep all file path arguments passed to subprocess Command calls in both adapters. Verify all use absolute paths (no relative paths). Cross-reference T28, T30.

7. **Audit INV-7: Allowlisted environment** — Read `adapter_config.rs` ENV_ALLOWLIST and `build_allowed_env()`. Verify env_clear() is called before envs() in both adapters. Verify env_overrides are layered on top. Cross-reference T17, T29.

8. **Audit INV-8: Metadata persistence** — Verify both adapters write metadata JSON to `{relay_root}/adapter/`. Check metadata includes all fields specified in the execution packet (argv, cwd, exit_code, elapsed, paths). Cross-reference T7, T18, T24.

9. **Audit constraints C-1 through C-6** — Read the execution packet constraints section and verify each: C-1 (executor changes limited), C-2 (sync only — no async), C-3 (regression = green behavior), C-4 (unix/macOS semantics), C-5 (dependency budget: wait-timeout, libc, no others added), C-6 if present.

10. **Audit test obligation coverage** — For each T1–T30, verify: (a) a test exists with the right name/scenario, (b) the test actually asserts what the obligation requires, (c) the test is registered in mod.rs and runs. List any gaps.

### Task Group B: Dead Code + Cruft Sweep

11. **Sweep unused imports** — Run `cargo check -p capacitor-core 2>&1 | grep "unused"` and fix any warnings in the new adapter files.

12. **Sweep unused error variants** — Check if all AdapterError variants (SkillNotFound, TemplateNotFound, AssemblyFailed, ContractViolation, ProcessCrash, Timeout, SpawnFailed, IoError) are actually used in production code (not just tests). Remove or mark any dead variants.

13. **Sweep unused functions/structs** — Look for any public functions or structs in the new modules that are not used by any consumer. Check: adapter_config.rs exports, prompt_builder_adapter.rs exports, worker_dispatch_adapter.rs exports.

14. **Sweep stale doc references** — Check if any doc comments, module-level comments, or README references mention the old narrow DTO contract (PromptBuildRequest without template/skills, WorkerDispatchRequest without prompt_path, WorkerDispatchResult without signal/elapsed).

15. **Sweep test helpers** — Look for unused test helper functions in adapter_seam.rs, real_prompt_builder.rs, real_worker_dispatcher.rs. Also check for any `#[allow(dead_code)]` that can be removed.

16. **Sweep fake-codex.sh** — Verify all FAKE_CODEX_* env vars documented in the harness contract (execution-packet.md section "Harness Contract") are actually implemented in the script and vice versa.

17. **Sweep Cargo.toml** — Verify `wait-timeout = "0.2"` is the only new dependency added. Check that no dev-dependencies were added that aren't needed (assert_fs was in the plan but may not have been used).

### Task Group C: Final Verification

18. **Run full regression** — `cargo fmt --check && cargo clippy -- -D warnings && cargo test -p capacitor-core` — all must pass after any fixes.

19. **Write findings summary** — Document all findings (gaps, fixes applied, confirmed-clean items) as a structured report at `handoffs/overnight-audit-report.md`.

**After creating all tasks, work through them sequentially. Mark each complete as you go. If you find an issue, fix it immediately (create a new commit), then continue the audit.**

## Current State
- **Done:** 7-slice implementation shipped in commit `2f78f07` (15 files, +2496 lines)
- **Done:** 710 tests pass (678 baseline + 32 new), cargo fmt clean, clippy clean
- **Not done:** No formal contract audit against execution packet
- **Not done:** No dead code sweep post-implementation

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- HEAD: `2f78f07 Implement real subprocess adapter layer for method runner (IF1 + IF2)`
- Working tree: clean (only untracked `handoffs/` dir)

## Key Artifacts

### Source of Truth — Execution Packet
- `.relay/method-runs/real-adapters/artifacts/execution-packet.md` — **Read this first.** Contains all 8 invariants, 30 test obligations, 6 constraints, harness contract, and module split.
- `.relay/method-runs/real-adapters/artifacts/amended-spec.md` — Design decisions and rationale
- `.relay/method-runs/real-adapters/artifacts/implementation-plan.md` — 7 slices, dependency graph, review points

### Implementation Files to Audit
| File | Purpose |
|------|---------|
| `core/capacitor-core/src/method_runner/adapter_config.rs` | AdapterConfig, env allowlist, preflight JSON |
| `core/capacitor-core/src/method_runner/adapters.rs` | DTOs, traits, error variants, fake adapters |
| `core/capacitor-core/src/method_runner/executor.rs` | dispatch_attempt_workers() seam edits only |
| `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs` | ShellPromptBuilder (IF1) |
| `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` | CodexWorkerDispatcher (IF2) |
| `core/capacitor-core/src/method_runner/mod.rs` | Module registration |
| `scripts/test/fake-codex.sh` | Controllable codex exec test harness |

### Test Files to Audit
| File | Tests |
|------|-------|
| `core/capacitor-core/tests/method_runner/adapter_seam.rs` | T21-T27 |
| `core/capacitor-core/tests/method_runner/real_prompt_builder.rs` | T1-T8, T24, T28, T29 |
| `core/capacitor-core/tests/method_runner/real_worker_dispatcher.rs` | T9-T14, T15-T20, T30 |
| `core/capacitor-core/tests/method_runner/interfaces.rs` | Updated call sites |
| `core/capacitor-core/tests/method_runner/step8_batch_a.rs` | Updated call sites |

## Project Rules
- `cargo fmt` required before commits
- Do NOT modify `run_types.rs`, `AppSnapshot`, runtime service, or Swift
- User has ADHD — keep findings focused and actionable
- User prefers long-term structurally sound solutions over quick fixes
- Treat the execution-packet.md as the canonical contract — if the code disagrees with the packet, the code is wrong

## Established Decisions
- Sync adapters only — `std::process::Command`, no tokio
- Process group: `process_group(0)` + `killpg` for timeout
- `compose-prompt.sh` stays as shell — wrap, don't port
- env_overrides on AdapterConfig for test harness control (INV-7 compliant)
- `exec sleep` in fake-codex.sh default TERM mode for clean signal capture
- Source-literal compat intentionally dropped — 8 test call sites updated

## Verification State
- Passed: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test -p capacitor-core` (710 tests)
- Passed: INV-2 grep (zero matches)
- Passed: Pre-commit hooks (all crates, 742 tests)
- Not run: Formal line-by-line audit against execution packet invariants
- Not run: Dead code sweep with `cargo check` warnings analysis
- Not run: Cross-reference of all 30 test obligations against actual test assertions
