# Adversarial Review 01

Date: 2026-05-27
Scope: Final Capacitor-only macOS Work Batch Preview integration after manual fixes.

## Findings

No medium, high, or critical findings.

## Reviewed Scope

- Work Batch card preview status and separate preview affordance in `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`.
- Preview projection, store, exact running-app matching, stale-state handling, and Capacitor-only capability gate in `apps/swift/Sources/Capacitor/Models/WorkBatchPreviewState.swift`.
- `WorkBatchAutoRouter.openPreview` behavior for no binding, unavailable worktrees, existing ready preview reuse, build failure, and proof storage in `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`.
- macOS proof coordinator identity/path checks, build command, already-running guard, and executable-url path fallback in `apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift`.
- Capacitor-only preview build script and Debug/Preview coexistence guards in `scripts/dev/build-preview-app.sh`, `scripts/dev/check-terminal-activation-state.sh`, and `scripts/dev/restart-app.sh`.
- Focused preview tests, restart-script tests, and live manual proof notes under `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/`.

## Evidence Checked

- The preview button is a separate action from the card body and terminal button, so preview clicks do not route through cockpit activation.
- Projection returns `Ready to inspect` only when the stored proof matches the current binding worktree and a matching preview process is still running.
- Projection now clears stale `preview_unavailable` reasons once the current batch has a preview-capable worktree.
- Projection disables the action when a non-matching `Capacitor Preview` identity is already running.
- `openPreview` reuses and activates an exact running ready preview before building again.
- Preview record writes invalidate the observed Work Batch projection so the card re-renders after `previews.json` changes.
- The proof coordinator fails closed on bundle ID mismatch, display name mismatch, wrong launched path, and another running preview identity.
- Debug verification allows `CapacitorPreview.app` beside Debug but still rejects the wrong app when `--require-debug-frontmost` is used.

## Verification

- `git diff --check`
- `bash -n scripts/dev/check-terminal-activation-state.sh scripts/dev/restart-app.sh scripts/dev/build-preview-app.sh`
- `swift test --package-path apps/swift --filter WorkBatchPreviewActionTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewStateTests`
- `swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests`
- live Debug app retest: `Preview available` -> `Preview building` -> `Ready to inspect`, then repeat click -> `Preview ready`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`

## Residual Low Risks

- The implementation is intentionally hardcoded to Capacitor until the generic preview-provider model is designed.
- Preview foregrounding is best-effort after an exact running match; the code keeps the ready state rather than rebuilding or failing when macOS activation does not prove focus.
- Live manual testing covered the Capacitor happy path and repeat-click path; no-binding and already-running conflict paths are covered by focused tests.
