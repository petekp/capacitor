# macOS Preview Work Adversarial Review 02

Date: 2026-05-27

## Scope

Second clean review of the final macOS Preview Work proof slice after the first review fixes.

Reviewed:

- coordinator status transitions and fail-closed behavior
- build script path safety, tool lookup, dedicated Swift scratch path, bundle identity rewrite, code signing
- Debug menu entry and live app invocation
- proof artifacts and ignored build outputs
- focused and full Swift verification output

## Findings

No medium, high, or critical findings.

No additional low findings require changes before continuing.

## Evidence

- `latest-preview-proof.json` records `ready_to_inspect` for `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorPreview.app`.
- The proof app identity matches the contract: `com.capacitor.app.preview` / `Capacitor Preview`.
- `apps/swift/.build-preview/` and `apps/swift/CapacitorPreview.app/` are ignored build artifacts.
- `latest-build.log` is ignored by the existing `*.log` rule.
- `swift test --package-path apps/swift` passed with 966 XCTest tests and 19 Swift Testing tests.

## Verification

Passed:

```bash
bash -n scripts/dev/build-preview-app.sh
git diff --check
swift test --package-path apps/swift --filter MacOSPreviewWorkProofTests
swift test --package-path apps/swift
```

Live proof passed:

```bash
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
osascript -e 'tell application "System Events" to tell process "Capacitor Debug" to click menu item "Build and Open Capacitor Preview" of menu "Debug" of menu bar item "Debug" of menu bar 1'
```

## Decision

The slice is solid enough to build on. The next product increment should connect this proof path to Work Batch state instead of keeping it as a Debug-menu proof.
