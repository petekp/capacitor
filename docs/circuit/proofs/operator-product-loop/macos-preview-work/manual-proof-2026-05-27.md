# macOS Preview Work Proof - 2026-05-27

## Intent

Prove the smallest useful macOS Preview Work contract for Capacitor:

- build a distinct `Capacitor Preview.app` from an explicit worktree path
- launch that exact app by path
- prove the launched app identity before saying it is ready
- record internal proof fields for agent/operator context

## Result

Passed.

The real proof built and launched:

- App path: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorPreview.app`
- Bundle id: `com.capacitor.app.preview`
- Display name: `Capacitor Preview`
- PID: `76869`
- Status: `ready_to_inspect`
- Worktree path: `/Users/petepetrash/Code/capacitor`
- Git head: `d8f0c9b499345e41623b8e93c3ca125e2c023adf`
- Dirty state: `dirty`

Proof artifacts:

- Proof JSON: `docs/circuit/proofs/operator-product-loop/macos-preview-work/latest-preview-proof.json`
- Build log: `docs/circuit/proofs/operator-product-loop/macos-preview-work/latest-build.log`

## Commands

```bash
swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests
bash -n scripts/dev/build-preview-app.sh
git diff --check
CAPACITOR_RUN_MACOS_PREVIEW_PROOF=1 swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests/testRealCapacitorPreviewBuildLaunchProof
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
osascript -e 'tell application "System Events" to tell process "Capacitor Debug" to click menu item "Build and Open Capacitor Preview" of menu "Debug" of menu bar item "Debug" of menu bar 1'
```

## Observations

- The first real proof attempt found that running `swift build` from inside `swift test` can block on SwiftPM's package lock.
- The build script now uses `apps/swift/.build-preview` as a dedicated scratch path for preview builds.
- The second proof attempt found an already-running `Capacitor Preview` app. The app coordinator still fails closed in that case; the explicit integration proof now closes stale preview instances before running so the proof is repeatable.
- The first app-menu attempt found that GUI-launched apps do not inherit a developer shell PATH. The build script now declares a small predictable developer-tool PATH and fails clearly if a required tool is missing.
- The app-menu path passed after relaunching the verified `CapacitorDebug.app`; the latest proof JSON records `ready_to_inspect` at `2026-05-27T21:11:20Z`.
- `apps/swift/.build-preview/` is ignored so preview scratch builds do not pollute Git.
- The first adversarial review found that the script should fail closed before a destructive app replacement, and that Sparkle's auto-check flag should be a real plist boolean. The script now guards `--app-path` so it must be inside the worktree and end in `.app`, and `SUEnableAutomaticChecks` is written as boolean false.
- The coordinator now refuses an already-running preview before building, so it does not rebuild over a live preview app.
- The current slice proves one active `Capacitor Preview` identity. Batch-specific multi-preview identity is intentionally left for the next product increment.
