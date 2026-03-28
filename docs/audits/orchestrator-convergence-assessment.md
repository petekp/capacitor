# Orchestrator Runtime Core Convergence Assessment

Date: 2026-03-17
Branch: `pkp/delegation-loop-stabilization`

## Verdict

**ISSUES REMAIN**

I am not comfortable declaring this batch complete and hardened. The runtime-core fixes themselves look real, but the merge-prep cut still has real residue and context-hygiene problems that keep it from being a fully clean closeout.

## Completeness

- `git diff main --stat` reports `157 files changed, 18126 insertions(+), 2070 deletions(-)`.
- The current cut spans Swift app code, Rust core, hook-server transport, verifier tooling, CI/scripts, and architecture/docs.
- The worktree is also still dirty beyond the tracked diff. `git status --short` shows untracked `docs/historical/`, `docs/plans/orchestrator-next-slices/`, `docs/superpowers/`, `AGENTS.md`, `.relay/`, `.capacitor/`, and multiple verifier `__pycache__` artifacts.

## Findings

### Medium — Historical-doc quarantine is incomplete and the cleanup slice is not fully landed in tracked repo state

- Location: `.claude/docs/architecture-primer.md:60-67`, `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md:1-11`, plus `git status --short docs/superpowers docs/historical docs/plans/orchestrator-next-slices`
- Observed evidence:
  - The architecture primer explicitly demotes `docs/historical/`, `docs/audits/`, `docs/plans/`, `docs/manual-qa/`, and `docs/archive/architecture-history/` as non-canonical current-state inputs.
  - An untracked file still exists at `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`, and it explicitly identifies itself as a `historical-design-spec`.
  - The quarantine directories themselves (`docs/historical/` and `docs/plans/orchestrator-next-slices/`) are still untracked in the current worktree.
- Inference:
  - The cleanup slice is only partially integrated into repo state.
  - A historical orchestrator design doc still lives in an active-looking path outside the new quarantine, and the quarantine bundle is not yet part of the tracked merge diff.
  - That directly conflicts with the mission to keep migration artifacts from dominating agent context.
- Recommendation:
  - Fully quarantine or remove `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`.
  - Make the redirect/quarantine paths part of the tracked merge diff before declaring this cut hardened.

### Medium — Generated Python bytecode remains in versioned repo state and continues to churn

- Location:
  - `.verifier/specs/__pycache__/HookSetupContracts.cpython-313.pyc`
  - `.verifier/specs/__pycache__/ReplayParityContracts.cpython-313.pyc`
  - `.verifier/specs/__pycache__/RuntimeBoundaryContracts.cpython-313.pyc`
  - `.verifier/specs/__pycache__/_helpers.cpython-313.pyc`
  - `scripts/verify/__pycache__/verifier_common.cpython-313.pyc`
  - `.gitignore:53-56`
- Observed evidence:
  - `git ls-files` shows the `.pyc` files above are tracked.
  - `git status --short` shows both modified tracked bytecode and additional untracked `__pycache__` outputs under `.verifier/specs/` and `scripts/verify/`.
  - `.gitignore` ignores verifier facts, reports, and `.venv`, but not `__pycache__/` or `*.pyc`.
- Inference:
  - Generated binary residue is still part of repo state.
  - Ordinary verifier runs keep dirtying the tree, which is the opposite of a hardened merge-prep cut.
- Recommendation:
  - Remove tracked `.pyc` artifacts.
  - Ignore `__pycache__/` and `*.pyc`.
  - Rerun `git status --short` after a verifier run to prove the tree stays clean.

### Low — Diff hygiene is still failing on whitespace-only residue

- Location:
  - `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift:4728`
  - `apps/swift/Sources/CapacitorCoreFFI/capacitor_coreFFI.h:869`
  - `apps/swift/Sources/CapacitorCoreFFI/capacitor_coreFFI.h:881`
  - `apps/swift/Sources/CapacitorCoreFFI/capacitor_coreFFI.h:911`
  - `docs/archive/architecture-history/agent-changelog-history-through-2026-03-15.md`
- Observed evidence:
  - `git diff --check main` exits `2` and reports trailing whitespace in the generated Swift/FFI files above plus a new blank line at EOF in the archived changelog.
- Inference:
  - The cut is not yet diff-clean.
- Recommendation:
  - Clean or regenerate those files and rerun `git diff --check main`.

## Verification

- `bash docs/historical/orchestrator-next-slices/guard.sh --status`
  - Exit: `0`
  - Result: PASS
  - Notable output: all expected control-plane artifacts present; WorkstreamsManager references `15 / 15`, WorkstreamsPanel references `2 / 2`, legacy workstreams flag references `15 / 15`; `Guard status: ok`

- `./scripts/verify/verify.sh --layers 1,2`
  - Exit: `0`
  - Result: PASS
  - Notable output: no stdout/stderr; log file remained empty

- `cargo fmt --check`
  - Exit: `0`
  - Result: PASS

- `cargo clippy -- -D warnings`
  - Exit: `0`
  - Result: PASS
  - Notable output: `Finished 'dev' profile [unoptimized + debuginfo] target(s) in 0.06s`

- `cargo test -p capacitor-core --test delegation_contract`
  - Exit: `0`
  - Result: PASS
  - Pass/fail count: `7 passed; 0 failed`

- `cargo test -p capacitor-core`
  - Exit: `101`
  - Result: **SANDBOX_LIMITED**
  - Pass/fail count: `195 passed; 8 failed`
  - Failure mode: all 8 failures are `PermissionDenied` / `Operation not permitted` while binding a mock runtime-service socket in `core/capacitor-core/src/runtime_state/snapshot.rs:180`

- `cargo test -p hud-hook`
  - Exit: `101`
  - Result: **SANDBOX_LIMITED**
  - Pass/fail count: unit tests `11 passed; 0 failed`; integration tests `0 passed; 17 failed`
  - Failure mode: all 17 integration failures are `PermissionDenied` / `Operation not permitted` while binding listeners in `core/hud-hook/tests/common/mod.rs:23` or `core/hud-hook/tests/serve_integration.rs:94`

- `cargo build -p capacitor-core --release`
  - Exit: `0`
  - Result: PASS

- `cp target/release/libcapacitor_core.dylib "$(cd apps/swift && swift build --show-bin-path)/"`
  - Exit: `0`
  - Result: PASS
  - Bin path copied into: `/Users/petepetrash/Code/capacitor/apps/swift/.build/arm64-apple-macosx/debug`

- `swift test --package-path apps/swift`
  - Exit: `1`
  - Result: **SANDBOX_LIMITED**
  - Failure mode: SwiftPM manifest evaluation cannot write to `/Users/petepetrash/.cache/clang/ModuleCache/...`; command fails before tests execute

- `swift build --package-path apps/swift`
  - Exit: `1`
  - Result: **SANDBOX_LIMITED**
  - Failure mode: same manifest/module-cache permission failure as `swift test`

- Supplemental check: `HOME=/tmp/capacitor-home CLANG_MODULE_CACHE_PATH=/tmp/capacitor-clang-cache swift test --package-path apps/swift`
  - Exit: `1`
  - Result: **SANDBOX_LIMITED**
  - Failure mode: still fails during manifest evaluation with `sandbox-exec: sandbox_apply: Operation not permitted`

## Fix Validation And Test Coverage

- The former High transport bug is fixed.
  - `RuntimeClient` now decodes mutation outcome bodies and throws `.mutationRejected(...)` on `ok == false` in `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:1084-1141`.
  - Regression tests exist in `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift:487-554`.

- The former Medium clear-session bug is fixed.
  - `OrchestratorMutationKind::Clear` now rejects mismatched `session_id` before removal in `core/capacitor-core/src/reduce/mod.rs:736-761`.
  - Regression test: `core/capacitor-core/tests/delegation_contract.rs:446-481`.

- The transport contract is covered end-to-end on the Rust side.
  - `core/hud-hook/tests/serve_integration.rs:441-482` asserts a `200 {"ok":false}` rejection body for mismatched orchestrator session IDs.

- The DLM cache-drift resolution is plausible and internally consistent.
  - `DelegationLoopManager` only applies side effects after `try await runtimeMutation(request)` succeeds in `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:573-592` and `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:738-750`.

- Coverage gap:
  - I did not find a direct `DelegationLoopManager` regression test that proves a rejected `attach_session` leaves `lastAttachedSessionIDs` untouched.
  - The risk is reduced by the new `RuntimeClient` rejection tests and the side-effect ordering above, but this seam is still only indirectly covered.

## Consistency

- Positive:
  - The active architecture read path is consistent across `README.md`, `CLAUDE.md`, `AGENT_CHANGELOG.md`, `docs/ARCHITECTURE.md`, and `.claude/docs/architecture-primer.md`.
  - The primer now stabilizes the core domain vocabulary (`Project`, `Project Key`, `Orchestrator`, `Worker`, `Worker Session`, `Run`, `Delegation Loop`, `Review`, `Decision`).

- Remaining low inconsistency:
  - `apps/swift/Tests/CapacitorTests/ProjectPrimaryActionResolverTests.swift:77-94` is still named `testFallsBackToTerminalWhenModeIsStaleOrchestrator`, while the implementation intentionally reconnects stale orchestrators in `apps/swift/Sources/Capacitor/Utilities/ProjectPrimaryActionResolver.swift:19-23`.
  - This matches the previously documented Low finding and remains non-blocking, but it is still residue.

## Residual Non-Blockers Already Acknowledged By Plan

- Snapshot persistence is still not crash-safe because snapshot writes lack an fsync barrier.
- The stale `ProjectPrimaryActionResolverTests` name remains cosmetic but misleading.
- Current Swift verification is limited by sandbox restrictions, so I could not independently reproduce the previously reported `swift test` / `swift build` passes from outside this sandbox.

## Conclusion

The functional fixes appear real and the required non-sandbox gates are green, but the merge-prep cut still has real residue:

- the doc quarantine is not fully landed in tracked repo state,
- a historical orchestrator spec still exists outside the quarantine path,
- tracked/generated `.pyc` files are still in repo state and still churning,
- and `git diff --check main` is not clean.

**Verdict: ISSUES REMAIN**
