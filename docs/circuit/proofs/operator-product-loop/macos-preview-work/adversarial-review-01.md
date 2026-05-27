# macOS Preview Work Adversarial Review 01

Date: 2026-05-27

## Scope

Reviewed the macOS Preview Work proof slice:

- `apps/swift/Sources/Capacitor/Debug/MacOSPreviewWorkProof.swift`
- `apps/swift/Sources/Capacitor/Debug/AppDebugSupport.swift`
- `apps/swift/Tests/CapacitorTests/MacOSPreviewWorkProofTests.swift`
- `scripts/dev/build-preview-app.sh`
- `.gitignore`
- `docs/circuit/proofs/operator-product-loop/macos-preview-work/latest-preview-proof.json`
- `docs/circuit/proofs/operator-product-loop/macos-preview-work/manual-proof-2026-05-27.md`

## Findings

No medium, high, or critical findings remain.

## Resolved During Review

1. The preview script previously rebuilt the app before checking whether a preview with the same bundle id was already running.
   - Fix: `MacOSPreviewWorkCoordinator` now checks for an already-running preview before running the build script and checks again before launch.
   - Verification: `MacOSPreviewWorkProofTests.testFailsClosedWhenPreviewIdentityIsAlreadyRunning` now fails before the build command.

2. The preview script removed `APP_PATH` without first proving the path was a safe app bundle target.
   - Fix: `build-preview-app.sh` now normalizes `--app-path`, requires its parent to exist, requires the final path to be inside the worktree, and requires a `.app` suffix before `rm -rf`.
   - Verification: script syntax passed and the real proof still built the preview app.

3. The preview script wrote `SUEnableAutomaticChecks` with the string writer.
   - Fix: added `write_plist_bool` and write `SUEnableAutomaticChecks` as boolean false.
   - Verification: `plutil -p apps/swift/CapacitorPreview.app/Contents/Info.plist` shows `SUEnableAutomaticChecks => 0`.

4. The app-menu path initially failed because GUI-launched apps did not inherit a developer shell PATH.
   - Fix: `build-preview-app.sh` declares a narrow developer-tool PATH and fails clearly when required tools are missing.
   - Verification: the Debug menu command produced `ready_to_inspect` in `latest-preview-proof.json`.

## Verification

Passed:

```bash
bash -n scripts/dev/build-preview-app.sh
git diff --check
swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests
CAPACITOR_RUN_MACOS_PREVIEW_PROOF=1 swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests/testRealCapacitorPreviewBuildLaunchProof
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
swift test --package-path apps/swift
```

Manual proof:

- Invoked `Debug > Build and Open Capacitor Preview` from the verified `CapacitorDebug.app`.
- Latest proof JSON recorded status `ready_to_inspect`, bundle id `com.capacitor.app.preview`, display name `Capacitor Preview`, app path `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorPreview.app`, PID `76869`.

## Residual Risk

- This slice intentionally proves one active `Capacitor Preview` identity. Batch-specific side-by-side native previews remain a future increment.
- The preview app still shares the current local Capacitor runtime/state model. That is acceptable for this proof slice, but the product version should decide how preview instances should isolate app state.
