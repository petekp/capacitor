# Manual Work Batch Routing And Delivery Adversarial Review 01

Date: 2026-05-25

## Scope

Reviewed the Work Batch routing/delivery changes, hook cleanup changes, manual proof artifacts, and verification results for the current goal:

- Automatic Task delivery into Work Batches.
- Related Task wake-in-place behavior.
- Unrelated Task separate batch/session behavior.
- Ghostty no-window-spray behavior.
- Claim, Done, checkpoint, queued, and idle projection honesty.
- Retired Capacitor hook cleanup.

Primary files reviewed:

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchExistingSessionWaker.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchClaudeProcessScanner.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `core/capacitor-core/src/runtime/setup/env.rs`
- `core/capacitor-core/src/runtime/setup/settings.rs`

## Findings

No medium, high, or critical findings.

### Low: Hook repair events reuse the `missing_events` field

- Location: `core/capacitor-core/src/runtime/setup/settings.rs`
- Evidence: `hooks_registered_in_settings` now reports duplicate or retired managed hooks as `HookSettingsStatus::PartiallyConfigured`, carrying repair event names in the existing `missing_events` field.
- Why it matters: user-facing setup copy may describe a repair-needed event as "missing" even when the current hook exists but stale managed entries also exist.
- Why not medium: the install/repair behavior is correct, live settings were cleaned, and tests cover both repair-needed detection and post-repair installed status.
- Future fix: introduce a distinct `repair_events` field or status variant if setup UX needs more precise copy.

### Low: Process probing depends on local `ps`/`lsof`

- Location: `apps/swift/Sources/Capacitor/Models/WorkBatchClaudeProcessScanner.swift`
- Evidence: exact live-session recovery uses `ps -axo pid=,command=` and `lsof -a -p <pid> -d cwd -Fn` to confirm Claude sessions inside batch worktrees.
- Why it matters: if `lsof` is unavailable, slow, or blocked, Capacitor falls back to runtime hook state and may be less confident about exact live sessions.
- Why not medium: this is a fallback hardening path over the existing runtime snapshot, and focused tests cover process parsing and non-Claude filtering.
- Future fix: add a small timeout wrapper for process probes if this ever shows up as UI latency.

## Checks Reviewed

Passed:

```bash
CARGO_INCREMENTAL=0 cargo test -p capacitor-core runtime::setup -j1
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|CompletionReport|CheckpointExchange|AutoRouter|DeliveryPolicy|TaskSession|State)Tests|AppStateRuntimeSnapshotEffectTests|GhosttyAutomationClientTests|WorkBatchBindingReconcilerTests|WorkBatchClaudeProcessScannerTests|ProjectCardContextLineResolverTests|GhosttyTerminalDriverTests'
swift test --package-path apps/swift
```

Manual proof reviewed:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-routing-delivery-verification-2026-05-25.md`

## Verdict

Clean for medium-or-above risk. The implementation matches the agreed slice closely enough to continue building on it.
