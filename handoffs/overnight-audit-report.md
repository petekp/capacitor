# Overnight Audit Report: Real Adapter Layer (IF1 + IF2)

**Date:** 2026-03-23
**Commit audited:** `2f78f07` — _Implement real subprocess adapter layer for method runner (IF1 + IF2)_
**Auditor:** Claude Code (automated contract audit + dead code sweep)

## Summary

**Verdict: CLEAN — zero spec gaps, zero dead code, zero fixes needed.**

The 7-slice implementation is fully compliant with the execution packet contract.
All 8 invariants verified, all 6 constraints confirmed, all 30 test obligations
present and correctly asserting, and no dead code or cruft found.

## Contract Audit Results (Group A)

### Invariants

| ID | Invariant | Verdict | Evidence |
|----|-----------|---------|----------|
| INV-1 | Explicit seam data | PASS | `executor.rs:968-976` passes template, merged skills, prompt_path through DTOs — nothing inferred from relay_root layout |
| INV-2 | Executor stays shell-agnostic | PASS | `rg "Command::new\|wait_timeout\|killpg\|compose-prompt\|codex exec" executor.rs` → 0 matches |
| INV-3 | Preflight-or-fail | PASS | `AdapterConfig::new()` validates binaries; `prompt_builder_adapter.rs:65-86` preflights skills+template before spawn |
| INV-4 | Process-group containment | PASS | `.process_group(0)` on spawn, `killpg(SIGTERM)` → grace → `killpg(SIGKILL)` escalation in `worker_dispatch_adapter.rs:94-145` |
| INV-5 | Worker outcome ≠ adapter failure | PASS | Non-zero exit → `Ok(WorkerDispatchResult)` at line 212; only infrastructure failures return `Err()` |
| INV-6 | Absolute paths | PASS | All paths built from `relay_root.join()` and `AdapterConfig` paths (canonicalized at construction) |
| INV-7 | Allowlisted environment | PASS | Both adapters call `env_clear()` then `envs(build_allowed_env(...))` — verified in IF1:134-135 and IF2:88-89 |
| INV-8 | Metadata persistence | PASS | IF1 writes `adapter/prompt-builder.metadata.json`; IF2 writes `adapter/worker-dispatch.metadata.json` — all required fields present |

### Constraints

| ID | Constraint | Verdict | Evidence |
|----|-----------|---------|----------|
| C-1 | Executor changes limited | PASS | Only DTO population + result consumption in `dispatch_attempt_workers()` |
| C-2 | Synchronous only | PASS | Zero `async fn`, `.await`, or `tokio` references in any adapter module |
| C-3 | Regression = green behavior | PASS | 710 tests pass (678 baseline + 32 new), 8 call sites updated coherently |
| C-4 | Unix/macOS semantics | PASS | `process_group`, `killpg`, `ExitStatusExt::signal()` properly used |
| C-5 | Dependency budget | PASS | Only `wait-timeout = "0.2"` and `libc = "0.2"` added; no `assert_fs` needed |

### Test Obligation Coverage (T1–T30)

All 30 test obligations present, registered in `mod.rs`, and asserting correctly:

- **IF1 (T1–T8, T24, T28, T29):** 11 tests in `real_prompt_builder.rs` — all pass
- **IF2 (T9–T14, T15–T20, T30):** 13 tests in `real_worker_dispatcher.rs` — all pass
- **Shared/Seam (T21–T27):** 7 tests in `adapter_seam.rs` — all pass

No missing tests. No tests asserting the wrong thing.

## Dead Code + Cruft Sweep Results (Group B)

| Check | Verdict | Notes |
|-------|---------|-------|
| Unused imports | CLEAN | `cargo check` reports zero unused warnings |
| Unused error variants | NOTE | `ProcessCrash` variant defined but never constructed in production code — used only in pre-existing error taxonomy tests. Kept intentionally: serves the error surface area and may be needed by future adapters. |
| Unused functions/structs | CLEAN | All exports (`ShellPromptBuilder`, `CodexWorkerDispatcher`, `AdapterConfig`, `build_allowed_env`, `write_preflight_if_needed`) have consumers |
| Stale doc references | CLEAN | No mentions of old narrow DTO contract anywhere in module comments |
| Test helpers | CLEAN | All helper functions called ≥1 time. No `#[allow(dead_code)]` annotations |
| fake-codex.sh harness | CLEAN | All 10 `FAKE_CODEX_*` env vars from execution packet implemented; all 9 required behaviors present |
| Cargo.toml dependencies | CLEAN | `wait-timeout` and `libc` only additions, within budget |

## Regression Results (Group C)

```
cargo fmt --check    → clean
cargo clippy -D warnings → clean
cargo test -p capacitor-core → 710 passed, 0 failed
```

## Findings Requiring No Action

1. **`ProcessCrash` variant unused in production** — pre-existing error taxonomy variant. Not constructed by any adapter but used in 3 pre-existing test files for error display/classification coverage. Keeping it doesn't hurt; removing it would break those tests and narrow the error API surface unnecessarily.

2. **Real adapters not yet wired to binary entry point** — `ShellPromptBuilder` and `CodexWorkerDispatcher` are consumed by integration tests only. The binary still uses fake adapters. This is by design per the execution packet scope; wiring to the binary is a future task.

## Files Audited

### Source (5 files)
- `core/capacitor-core/src/method_runner/adapter_config.rs` — 209 lines
- `core/capacitor-core/src/method_runner/adapters.rs` — 494 lines (DTOs, traits, fakes)
- `core/capacitor-core/src/method_runner/executor.rs` — dispatch_attempt_workers() seam (lines 917–1016)
- `core/capacitor-core/src/method_runner/prompt_builder_adapter.rs` — 189 lines
- `core/capacitor-core/src/method_runner/worker_dispatch_adapter.rs` — 220 lines

### Tests (3 files)
- `core/capacitor-core/tests/method_runner/adapter_seam.rs` — 385 lines (T21–T27)
- `core/capacitor-core/tests/method_runner/real_prompt_builder.rs` — 586 lines (T1–T8, T24, T28, T29)
- `core/capacitor-core/tests/method_runner/real_worker_dispatcher.rs` — 633 lines (T9–T20, T30)

### Harness (1 file)
- `scripts/test/fake-codex.sh` — 214 lines

### Contract (1 file)
- `.relay/method-runs/real-adapters/artifacts/execution-packet.md` — 340 lines (source of truth)
