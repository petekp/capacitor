# Ship-Review: Orchestrator Runtime Core

Date: 2026-03-17
Branch: pkp/delegation-loop-stabilization
Reviewer: Codex adversarial reviewer

## Subsystem 1: Rust Reducer/Projection Truth
### Findings
- Medium, Confirmed, Bug — `core/capacitor-core/src/reduce/mod.rs:736-749` ignores `session_id` for `OrchestratorMutationKind::Clear`, even though the command carries that qualifier in `core/capacitor-core/src/domain/types.rs:448-452` and `MarkStale` enforces it in `core/capacitor-core/src/reduce/mod.rs:704-714`. A delayed clear intended for a dead session can therefore erase a newer replacement orchestrator on the same `project_path`.
- Low, Confirmed, Reliability — `core/capacitor-core/src/storage/mod.rs:78-99` writes the snapshot temp file and renames it without `sync_all()` on the temp file or parent directory. Restart recovery depends on this snapshot being durable, so a crash/power loss can drop the newest orchestration shell state even though clean restart tests still pass.
### Evidence
- Code trace: orchestration precedence itself looks correct: `review_needed` wins over `active`, and `active` wins over `stale_orchestrator` in `core/capacitor-core/src/reduce/mod.rs:811-897`.
- Code trace: restart recovery and journal replay are covered on the happy path in `core/capacitor-core/tests/delegation_contract.rs:158-246` and `core/capacitor-core/tests/delegation_contract.rs:445-597`, but there is no session-mismatch clear case.
- Test results: `cargo test -p capacitor-core --test delegation_contract` passed (6 passed, 0 failed).
- Test results: `cargo test -p capacitor-core` passed (233 passed, 0 failed; plus 0 doc tests).

## Subsystem 2: Runtime Transport and Contract
### Findings
- High, Confirmed, Bug — the Rust mutation transport returns `MutationOutcome` in a `200 OK` response even when the reducer rejects the command (`core/hud-hook/src/serve.rs:273-275`, `core/hud-hook/src/serve.rs:301-302`; shape defined in `core/capacitor-core/src/domain/types.rs:470-474`). `RuntimeClient.mutateDelegation` and `RuntimeClient.mutateOrchestrator` only check `statusCode == 200` and never decode `ok` (`apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:1083-1105`, `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:1109-1132`). Existing Rust tests prove `ok: false` is a real contract for invalid mutations (`core/capacitor-core/tests/ffi_contract.rs:541-573`). Result: Swift callers silently treat reducer rejections as success.
### Evidence
- Code trace: reducer rejection paths include missing/mismatched delegation worker IDs and missing/mismatched orchestrator session IDs in `core/capacitor-core/src/reduce/mod.rs:362-379` and `core/capacitor-core/src/reduce/mod.rs:694-712`.
- Code trace: the server-side happy-path integration tests in `core/hud-hook/tests/serve_integration.rs:281-440` only assert successful 200 responses; they never exercise a `200 {"ok":false}` body.
- Test results: `cargo test -p hud-hook` passed (32 passed, 0 failed).
- Test results: `swift test --package-path apps/swift --filter RuntimeClientTests` passed (20 passed, 0 failed).

## Subsystem 3: Swift Orchestration Policy
### Findings
- Low, Confirmed, Stale docs/test — `apps/swift/Tests/CapacitorTests/ProjectPrimaryActionResolverTests.swift:77-95` is named `testFallsBackToTerminalWhenModeIsStaleOrchestrator`, but it actually asserts `.reconnectOrchestrator("orch-session-1")`. The implementation and assertion agree; the test name documents the opposite policy and is now misleading.
### Evidence
- Code trace: the resolver intentionally routes `review_needed` to native review and routes `active` / `stale_orchestrator` to reconnect in `apps/swift/Sources/Capacitor/Utilities/ProjectPrimaryActionResolver.swift:10-30`.
- Code trace: idea queue status precedence is straightforward and matches the tests in `apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift:77-104`.
- Test results: `swift test --package-path apps/swift` passed (351 passed, 0 failed), including `AppStateSessionObservationTests` (6/6) and `AppStateTerminalActivationTests` (18/18).
- Test results: `swift test --package-path apps/swift --filter ProjectPrimaryActionResolverTests` passed (6 passed, 0 failed).
- Test results: `swift test --package-path apps/swift --filter IdeaQueueStatusResolverTests` passed (7 passed, 0 failed).

## Subsystem 4: Remaining Side-Effect Seam
### Findings
- Medium, Confirmed, Bug — `DelegationLoopManager` keeps a local `lastAttachedSessionIDs` cache and updates it after any non-throwing runtime mutation (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:574-584`, `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:738-745`). Because `RuntimeClient.mutateDelegation` treats any `200` response as success (`apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:1083-1105`), a reducer-rejected `attach_session` still poisons that cache. Future reconciles then short-circuit on the `cache_already_attached` path (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:628-637`) even though runtime truth never accepted the attach.
### Evidence
- Code trace: the reconcile seam is intended to defer to runtime truth, but it currently combines runtime mutations with local attach-session caching in `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:502-571` and `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:604-657`.
- Code trace: the current file-driven reconcile path also advances `working -> complete` and `working -> review_ready` on marker/file presence alone in `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:522-571`; the tests only cover happy-path presence, not malformed or stale artifacts (`apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift:214-312`).
- Test results: `swift test --package-path apps/swift` passed (351 passed, 0 failed), including `DelegationLoopManagerTests` (11/11) and `TerminalLauncherTests` (24/24).

## Summary
### Critical Findings
- None.

### High Findings
- Swift mutation callers treat any `200 OK` mutation response as success and ignore `MutationOutcome.ok`, so reducer rejections are silently swallowed across the Rust/Swift runtime contract.

### Medium Findings
- `OrchestratorMutationKind::Clear` ignores its `session_id` qualifier and can clear the wrong orchestrator for a project.
- `DelegationLoopManager` can drift from runtime truth because it caches `attach_session` success without verifying the reducer actually accepted the mutation.

### Low Findings
- Snapshot persistence is not crash-safe because temp files are renamed without an fsync barrier.
- `ProjectPrimaryActionResolverTests` contains a stale test name that documents the opposite policy from the assertion it now checks.

### Positive Observations
- Reducer precedence and restart-recovery happy paths are well covered by `delegation_contract` and `ffi_contract`.
- Runtime transport auth and shared-state behavior are covered by `hud-hook` integration tests.
- Swift orchestration hysteresis, reconnect routing, and activation arbitration all have strong happy-path coverage in the package test suite.

### VERDICT
ISSUES FOUND
