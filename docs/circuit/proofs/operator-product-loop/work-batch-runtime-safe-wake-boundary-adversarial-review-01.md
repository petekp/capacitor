# Work Batch Runtime Safe Wake Boundary Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the in-flight changes for:

- Runtime-derived safe wake boundary in `WorkBatchAutoRouter`.
- Safe wake tests in `WorkBatchAutoRouterTests`.
- Work Batch delivery policy documentation.
- Release-target UniFFI generation in restart/refresh/check/bootstrap scripts.
- Restart script regression coverage.

## Findings

No medium, high, or critical findings.

## Low / Follow-Up

1. Low: The release-target UniFFI guard in `tests/dev-scripts/restart-app.bats` covers `restart-app.sh` only.
   - Evidence: the new Bats assertion greps `SCRIPT_PATH`, which is `scripts/dev/restart-app.sh`.
   - Why it matters: `scripts/dev/refresh-uniffi-bindings.sh`, `scripts/ci/check-uniffi-bindings.sh`, and `scripts/bootstrap.sh` were also changed and are covered by direct command execution or review, not a static regression test.
   - Decision: acceptable for this slice because `./scripts/ci/check-uniffi-bindings.sh`, `bats tests/dev-scripts`, and `./scripts/dev/restart-alpha-stable.sh` all passed after the change.

2. Follow-up: The runtime safe wake policy still needs a live ready Claude Code Work Batch session to fully exercise the operator path.
   - Evidence: the live app had no Claude Code CLI process available; the app showed all visible projects as `Idle`.
   - Why it matters: the unit tests prove routing policy and delivery calls, but they do not prove Ghostty receives the wake prompt in the real ready-session condition.
   - Decision: keep the larger goal active and run this live scenario when a managed Claude Code Work Batch session is available.

## Checks Reviewed

- `./scripts/ci/swiftformat-lint.sh`
- `git diff --check`
- `swift test --package-path apps/swift --filter 'WorkBatchDeliveryPolicyTests|WorkBatchAutoRouterTests|AppStateRuntimeSnapshotEffectTests'`
- `swift test --package-path apps/swift`
- `bats tests/dev-scripts`
- `./scripts/ci/check-uniffi-bindings.sh`
- `./scripts/dev/restart-alpha-stable.sh`
- Live app process and runtime health checks.
