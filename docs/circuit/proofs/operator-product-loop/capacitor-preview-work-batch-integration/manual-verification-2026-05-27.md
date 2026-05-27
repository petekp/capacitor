# Capacitor Preview Work Batch Integration Manual Verification

Date: 2026-05-27
Verifier: Codex
Scope: Capacitor-only macOS preview affordance on Work Batch cards

## Environment

- Repo: `/Users/petepetrash/Code/capacitor`
- App under test: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`
- Preview app identity: `Capacitor Preview`, `com.capacitor.app.preview`
- Project: `capacitor`
- Batch: `batch-some-kind-of-menu-bar-has-become-visible-at-the-`
- Batch worktree: `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-some-kind-of-menu-bar-has-become`

## Manual Scenario

1. Relaunched the correct debug app with `./scripts/dev/restart-alpha-stable.sh`.
2. Verified the frontmost app with `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`.
3. Opened the Capacitor project detail view.
4. Confirmed the selected Work Batch card showed `Preview available`.
5. Clicked the preview affordance, not the card body or terminal/cockpit button.
6. Observed the preview state move through build/open and then show `Ready to inspect`.
7. Confirmed the launched app path was the batch worktree app:
   `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-some-kind-of-menu-bar-has-become/apps/swift/CapacitorPreview.app`.
8. Clicked the preview affordance again while the matching preview was already running.
9. Confirmed Capacitor returned `Preview ready`, kept the same preview process, and did not rebuild or launch a Claude/Ghostty session.

## Bugs Found And Fixed During Manual Verification

- Existing batch worktrees did not contain the new preview build script. Fixed by keeping the script in the main Capacitor checkout and passing the selected batch worktree as explicit input.
- `NSWorkspace` sometimes returned a running app without `bundleURL`, which made the ready proof fail with a launched-path mismatch. Fixed by resolving the app bundle path from the executable URL when needed.
- A second preview click on an already running exact preview could overwrite the ready state with `Preview failed`. Fixed by checking for the exact running preview before rebuilding and treating it as ready even if activation focus is best-effort.
- The debug app guard treated `CapacitorPreview.app` as an unwanted non-debug Capacitor process. Fixed the guard and restart script so `Capacitor Preview` can coexist with `Capacitor Debug`.
- Adversarial review found that an older `No batch worktree yet` unavailable record could leak into the card after the batch later gained a preview-capable worktree. Fixed projection so current capability wins and stale unavailable reasons are not shown beside an enabled preview action.
- Adversarial review found that another running `Capacitor Preview` could make a different batch look actionable until click-time failure. Fixed projection so a non-matching running preview identity disables the action and says to close the existing preview first.
- Final polish made the ready-preview action say `Bringing preview forward...` instead of `Building preview...`, and preview failures now surface their stored failure reason in the toast.
- A final live retest found that `previews.json` could update to `ready_to_inspect` while the Work Batch card still showed `Preview available`. Fixed by adding an observed Work Batch projection revision counter and having preview record writes invalidate the projection immediately.

## Artifacts

- Screenshot: `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/01-card-preview-available.png`
- Screenshot: `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/02-card-preview-click-building-toast.png`
- Screenshot: `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/03-card-ready-to-inspect.png`
- Screenshot: `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/04-final-ready-after-retry.png`
- Screenshot: `docs/circuit/proofs/operator-product-loop/capacitor-preview-work-batch-integration/05-second-click-preview-ready-no-rebuild.png`
- Persisted preview state: `/Users/petepetrash/.capacitor/projects/p2_%2Fusers%2Fpetepetrash%2Fcode%2Fcapacitor/work-batches/previews.json`
- Latest ready proof: `/Users/petepetrash/.capacitor/projects/p2_%2Fusers%2Fpetepetrash%2Fcode%2Fcapacitor/work-batches/previews/batch-some-kind-of-menu-bar-has-become-visible-at-the/latest-preview-proof.json`
- Latest build log: `/Users/petepetrash/.capacitor/projects/p2_%2Fusers%2Fpetepetrash%2Fcode%2Fcapacitor/work-batches/previews/batch-some-kind-of-menu-bar-has-become-visible-at-the/latest-build.log`

## Verification Commands

- `swift test --package-path apps/swift --filter RestartAppScriptTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewActionTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewStateTests`
- `swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewActionTests`
- `swift test --package-path apps/swift --filter WorkBatchPreviewStateTests`
- `bash -n scripts/dev/check-terminal-activation-state.sh scripts/dev/restart-app.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`
- `swift test --package-path apps/swift --filter SessionSummarizerTests/testFingerprintCacheProceedsOnChangedContext`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh`
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`

## Result

The implemented slice behaves as intended for the tested Capacitor Work Batch:
the card exposes preview availability, builds from the selected batch worktree,
opens the exact `Capacitor Preview.app`, records internal proof state under
`~/.capacitor`, foreground/reuses the matching running preview on repeat click,
and keeps preview separate from Claude/Ghostty cockpit activation.

One full Swift run initially hit a timeout in an unrelated summarizer test. The
single test passed on rerun, and the full Swift suite passed on the next run.

After the final Swift polish, the full Swift suite passed again with 986 XCTest
tests plus 19 Swift Testing tests, and the debug guard confirmed the frontmost
app was `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app` with
no release or preview Capacitor process active.

After the projection invalidation fix, a live retest from the correct Debug app
showed the card move to `Preview building` during the build and then
`Ready to inspect` after launch. A repeat click showed `Preview ready` and kept
the existing preview PID rather than rebuilding.
