# Debug Build Target Guardrail

Date: 2026-05-26

## Scenario

Live operator-loop verification was intermittently using the installed release app at `/Applications/Capacitor.app` instead of the repo-built Debug app at `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`.

That made manual evidence unreliable: both apps have the same product name in normal macOS surfaces, so an automation tool or a human click could attach to the wrong build while the code under test was running elsewhere.

## Intended Behavior

Dev restart and live diagnostics should make wrong-build testing hard to do by accident:

- `./scripts/dev/restart-alpha-stable.sh` should end with only the repo Debug app running.
- `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost` should activate the Debug app, print the front app path, Debug app process, and release app process.
- The diagnostic should fail loudly if `/Applications/Capacitor.app` is running during Debug verification.
- The diagnostic should fail if no Debug app is running or if a foreground Capacitor app cannot be proven to be the repo Debug bundle.
- The canonical Debug launch should also carry the Task-first feature set, so the app cannot be the right bundle with the wrong product-loop flags.
- Computer Use/manual automation should target `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`, not the ambiguous app name `Capacitor`.

## Source Changes

- `scripts/dev/restart-app.sh` now has `terminate_installed_release_capacitor` and `assert_no_installed_release_capacitor`.
- `scripts/dev/restart-app.sh` kills the installed release app before the normal restart kill sweep and again after launching the Debug app.
- `scripts/dev/restart-app.sh` now fails the restart if the Debug app does not stay running or cannot be proven frontmost at the end of launch.
- `scripts/dev/restart-alpha-stable.sh` forces `projectDetails,ideaCapture,llmFeatures`. The Swift flag is still named `ideaCapture` for legacy reasons, but this is the Task capture front door.
- `scripts/dev/check-terminal-activation-state.sh` now prints `front_app_path`.
- `scripts/dev/check-terminal-activation-state.sh` now supports `--activate-debug` and `--require-debug-frontmost`.
- `scripts/dev/check-terminal-activation-state.sh` now fails through guard functions when the installed release app is present, the Debug app is missing, or the foreground Capacitor identity is not provably Debug.
- `tests/dev-scripts/restart-app.bats` covers release-app cleanup.
- `tests/dev-scripts/check-terminal-activation-state.bats` covers diagnostic failure, explicit override behavior, missing Debug app handling, foreground-release handling, strict frontmost handling, and Debug activation by PID.

## Verification

Focused script tests passed:

```bash
bats tests/dev-scripts/restart-app.bats
bats tests/dev-scripts/check-terminal-activation-state.bats
bats tests/dev-scripts/restart-alpha-stable.bats
```

Observed results:

```text
restart-app.bats: 5 tests passed
check-terminal-activation-state.bats: 10 tests passed
restart-alpha-stable.bats: 3 tests passed
```

Full dev-script suite also passed:

```bash
bats tests/dev-scripts
```

Result: 82 tests passed.

Full Swift verification passed:

```bash
swift test --package-path apps/swift
```

Result: 941 XCTest cases passed with 1 skipped, plus 19 Swift Testing tests passed.

Canonical restart passed with the new guard:

```bash
./scripts/dev/restart-alpha-stable.sh
```

Post-restart diagnostic proved the live target:

```text
timestamp: 2026-05-26T23:22:04Z
front_app: Capacitor
front_app_pid: 32401
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app

capacitor_debug_processes:
32401 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:
```

Bundle metadata also proves the debug identity and product-loop feature set:

```text
CFBundleIdentifier: com.capacitor.app.debug
CFBundleDisplayName: Capacitor Debug
CapacitorFeaturesEnabled: projectDetails,ideaCapture,llmFeatures
```

The stricter diagnostic also caught a bad manual-test state before activation:

```text
front_app: Slack
front_app_path: /Applications/Slack.app
error: Capacitor Debug is not frontmost.
```

Computer Use attached to the correct bundle when given the full path during the earlier proof:

```text
App=/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/
bundleID com.capacitor.app.debug
Window: "Capacitor Debug", App: Capacitor Debug.
```

## Result

Pass for wrong-build prevention. The release app can still be launched intentionally, but the dev restart removes it, the live diagnostic refuses mixed release+Debug state, and the strict preflight can activate and prove the Debug app before manual UI work.

Remaining practice rule: manual/Computer Use checks should target the full Debug app path, not the ambiguous name `Capacitor`. The canonical preflight is:

```bash
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
```
