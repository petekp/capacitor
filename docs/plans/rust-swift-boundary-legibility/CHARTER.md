# Migration Charter

## Mission
Converge the Rust-Swift activation boundary onto Option 2 (`Core Facts, Swift Policy`) so Rust emits canonical runtime facts, one explicit Swift policy owner chooses activation intent, and Swift execution layers perform macOS side effects.

## Scope
- Rust shadow-ownership surfaces under `core/capacitor-core/src` that still imply a production activation owner
- Swift activation-policy surfaces under `apps/swift/Sources/Capacitor/Models` and `apps/swift/Sources/Capacitor/Views/Debug`
- Swift regression suites under `apps/swift/Tests/CapacitorTests`
- Architecture and migration docs under `docs/ARCHITECTURE.md`, `docs/audits/rust-swift-boundary-seams/`, and `docs/plans/rust-swift-boundary-legibility/`

## Critical Workflows
- Clicking a project card reuses the routed tmux pane when the runtime route already has pane metadata
- Attached tmux activation preserves runtime route hints when `terminal_app = nil` and uses explicit local fallback instead of shell reconstruction
- Detached direct-shell activation respects runtime-emitted host-terminal facts
- No-client activation still attaches or creates the correct tmux session without changing visible behavior
- Fallback terminal selection remains deterministic and user-visible when no stronger signal exists
- Activation diagnostics explain `runtime facts` versus `Swift policy` without pretending the runtime authored local reasoning

## External Surfaces
- `GET /health`
- `GET /runtime/snapshot`
- `POST /runtime/ingest/hook-event`
- `POST /runtime/ingest/shell-signal`
- `TERM_PROGRAM`
- `TERM`
- `TMUX`
- `tmux` CLI
- `NSWorkspace`
- AppleScript terminal automation
- Runtime logs under `~/.capacitor/runtime/`

## Invariants
- All existing tests continue to pass.
- The local runtime service remains the live runtime boundary.
- Rust owns ingest, reducer/query truth, and canonical runtime facts.
- Swift owns activation policy interpretation, diagnostics interpretation, freshness policy, and macOS execution.
- Activation stays route-first, pane-aware, and tmux-backed.
- Snapshot-file-first reads do not return as the primary runtime boundary.
- Existing dirty worktree edits in `TerminalLauncher.swift` and `TerminalLauncherTests.swift` are reconciled intentionally; they are never blown away or silently reset.

## Non-Goals
- Building Option 3 (`Rust Candidate Engine, Swift Executor`) in this migration
- Adding support for new terminal hosts
- Rewriting the runtime transport or replacing the dedicated runtime service
- Pulling desktop-local preference or installation policy into Rust
- Reworking unrelated UI flows outside the activation boundary

## Guardrails
- The first implementation slice is a validation spike: prove a narrow Swift policy owner exists before broader code movement.
- Delete replaced code in the same slice; do not leave a second reasoning path alive.
- Every architecture decision goes into `DECISIONS.md`.
- Every touched file stays mapped in `MAP.csv`.
- CI ratchet budgets can only decrease, never increase.
- No compatibility alias for fake boundary names such as `fetchRuntimeConfig` or `fetchCoreRoutingDiagnostics`.
- If attached host-app identity turns out to require broader runtime-contract work than Option 2 assumes, stop after the spike and reopen the architecture decision instead of layering more heuristics.
- Reserve the final convergence slice for residue sweep, doc reconciliation, and ship verification.

## Ship Gate
### Automated Checks
- `bash docs/plans/rust-swift-boundary-legibility/guard.sh`
- `cargo test -p capacitor-core`
- `swift test --package-path apps/swift --filter 'ActivationPolicyTests|TerminalLauncherTests|RuntimeClientTests|SupportedTerminalAppTests|AppStateSessionObservationTests'`
- `swift test --package-path apps/swift`
- `swift build --package-path apps/swift`

### Manual Checks
- Click a project whose attached tmux route has `terminal_app = nil`; the app preserves the routed session/pane hints, uses the explicit fallback ladder for terminal choice, and records a Swift-policy reason.
- Click a project with a detached direct-shell route; the routed terminal app still wins over local fallback.
- Trigger a no-client activation path; the chosen fallback terminal matches the explicit policy ladder.
- Inspect debug or log output after activation; wording clearly separates runtime facts from Swift policy interpretation.

### Cleanliness Checks
- No temporary migration scripts, adapters, or placeholder policy types remain in scope.
- No stale docs, tests, or debug views describe Rust and Swift as parallel activation-policy owners.
- No fake `runtime config` or `core diagnostics` naming remains for Swift-local synthesis.
- Empty directories or one-off scratch files created by the migration are removed unless intentionally retained.
