# Active Claude Ready Projection: Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the volatile live-process refresh change:

```text
apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift
apps/swift/Tests/CapacitorTests/RuntimeSnapshotApplicatorTests.swift
docs/circuit/proofs/operator-product-loop/active-claude-ready-projection-live-2026-05-26.md
docs/circuit/proofs/operator-product-loop/current-hardening-scenario-ledger-2026-05-26.md
```

Question under attack:

```text
Can refreshing live Claude process evidence on duplicate runtime snapshot versions accidentally replay stale durable state, bypass snapshot version protection, or create misleading UI churn?
```

## Findings

No medium, high, or critical findings.

## Evidence

Durable state remains version-protected:

```text
RuntimeSnapshotApplicator applies lastAppliedProjectStates and lastAppliedSessions on duplicate snapshot versions instead of trusting the duplicate payload.
```

Regression coverage:

```text
testRepeatedNonzeroSnapshotVersionIsNoop
```

This test intentionally passes a duplicate-version snapshot with a different session, shell cwd, and run. The durable session remains `baseline-session`, shell cwd remains `/baseline`, and the changed run is not inserted.

Volatile evidence is refreshed:

```text
testRepeatedNonzeroSnapshotVersionRefreshesLiveProcessEvidence
```

This test starts from durable idle state plus live process evidence, verifies `Ready`, removes live evidence, and verifies the state clears to `Idle` after the existing two-poll idle hysteresis.

Live evidence:

```text
[2026-05-27T01:10:15.181Z] AppState.refreshSessionStates source=runtime_snapshot_volatile_refresh cid=app-snap-19 version=4
[2026-05-27T01:10:25.188Z] AppState.refreshSessionStates source=runtime_snapshot_volatile_refresh cid=app-snap-21 version=4
[2026-05-27T01:10:25.346Z] SessionStateManager.idleStabilize action=commit project=/Users/petepetrash/Code/pete-2025 count=2
```

Verification passed:

```bash
swift test --package-path apps/swift --filter RuntimeSnapshotApplicatorTests
swift test --package-path apps/swift --filter 'RuntimeSnapshotApplicatorTests|SessionStateManagerTests|AppStateRuntimeSnapshotEffectTests'
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift
```

## Residual Risk

Long-poll `unchanged` responses still only record the version. In the running app, periodic snapshot fetches still perform the volatile refresh, which is what cleared the live UI. If the periodic fetch cadence is later removed, long-poll unchanged handling should grow an explicit volatile-refresh path too.
