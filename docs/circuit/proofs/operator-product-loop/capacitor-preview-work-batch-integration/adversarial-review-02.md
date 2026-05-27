# Adversarial Review 02

Date: 2026-05-27
Scope: Second clean pass after Adversarial Review 01.

## Findings

No medium, high, or critical findings.

## Acceptance Criteria Rechecked

- Work Batch cards can show preview availability for Capacitor batches.
- The preview affordance builds from the exact batch worktree and writes internal proof state under `~/.capacitor`.
- A matching running preview is brought forward/reused instead of rebuilt.
- No-binding, unsupported worktree, build failure, stale proof, and non-matching running preview states are reflected honestly.
- The preview affordance is separate from Claude/Ghostty cockpit activation.
- Debug and Preview apps can coexist without reopening the wrong Capacitor build during manual verification.

## Evidence Checked

- `WorkBatchListSection` wires preview to `onOpenPreview`, while the terminal icon still uses `onOpenCockpit`.
- `AppState.openWorkBatchPreview` now uses honest initial toasts: ready previews say `Bringing preview forward...`, builds say `Building preview...`, and failures show the stored reason when present.
- `AppState.workBatches(for:)` reads an observed Work Batch projection revision, and preview record changes bump it so external preview proof writes can update the card immediately.
- `WorkBatchPreviewProjector` is intentionally Capacitor-only and carries the TODO to replace it with explicit project preview capabilities later.
- `WorkBatchPreviewActionTests` covers exact running-preview reuse, no-binding unavailability, batch worktree request construction, failed proof persistence, projection invalidation callbacks, and no rebuild when activation is best-effort.
- `WorkBatchPreviewStateTests` covers stale unavailable records, closed ready proofs, non-matching running preview conflicts, and executable-url matching when `bundleURL` is missing.
- `MacOSPreviewWorkProofTests` covers exact preview identity, launched-path mismatch, bundle mismatch, and already-running failure.
- The final Debug guard reported `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app` frontmost with no release or preview Capacitor process active.

## Verification

- `git diff --check`
- `swift test --package-path apps/swift --filter WorkBatchPreviewActionTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewStateTests`
- `swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests`
- live Debug app retest: preview card showed `Preview building`, then `Ready to inspect`, then repeat click showed `Preview ready`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`

## Residual Low Risks

- The first slice supports Capacitor macOS previews only.
- Only one `Capacitor Preview` identity is allowed at a time; simultaneous preview instances are deferred until the broader preview model exists.
- Manual verification covers one real Capacitor Work Batch; other preview states are covered by focused tests.
