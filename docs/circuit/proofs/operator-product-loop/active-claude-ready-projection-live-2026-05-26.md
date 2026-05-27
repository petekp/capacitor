# Active Claude Ready Projection: Live Check

Date: 2026-05-26

## Scenario

Active Claude Code cockpits should remain visible as `Ready` rather than silently falling into `Idle`.

This check used `pete-2025` because the visible Debug app had no real Claude process running for that project. A controlled Claude-like process was started with cwd at the project root so Capacitor's live process scanner could see the same shape it expects from a manual Claude cockpit.

## Product Policy

If a Claude-like process is alive for a project, Capacitor should keep that project visible as `Ready for input` even when durable runtime state is otherwise idle or stale.

That does not mean the task is completed or healthy. It means there is an active cockpit consuming attention/memory and the user should be able to re-enter it.

## Live State

Strict Debug diagnostics showed the correct build and one Claude-like process:

```text
timestamp: 2026-05-27T01:01:49Z
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_debug_processes:
86521 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
capacitor_release_processes:
capacitor_non_debug_processes:
claude_processes:
90086 manual
```

Computer Use inspected the same Debug app process:

```text
App=/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/
bundleID com.capacitor.app.debug
pid 86521
Window: "Capacitor Debug"
```

The `pete-2025` project card was visible in the `In Progress` section:

```text
container Description: pete-2025, Details: Ready for input, ID: ax.project-card.pete-2025
button Description: Ready, Value: Ready for input
button Pushing feature commit
```

The screenshot state matched the accessibility tree:

```text
IN PROGRESS
pete-2025    READY
Pushing feature commit
```

## Result

Pass. A live Claude-like process kept `pete-2025` visible as `Ready for input` in the running Debug app.

## Sticky Ready Finding

The first live cleanup check exposed a bug. After the controlled process exited, the visible card remained `Ready` even though diagnostics showed no Claude processes:

```text
timestamp: 2026-05-27T01:03:14Z
claude_processes:
```

Log evidence showed why:

```text
AppState.refreshSessionStates source=runtime_snapshot_noop cid=app-snap-55 version=4
```

The runtime service snapshot version had not changed, so `RuntimeSnapshotApplicator` skipped fanout entirely. That made sense for durable runtime state, but it also skipped fresh Swift-side live process scanning. The live process overlay could become stale.

## Fix

`RuntimeSnapshotApplicator` now stores the last applied durable project/session state. When the runtime service returns the same nonzero snapshot version, the applicator still treats durable state as unchanged, but re-applies the last durable project/session state with fresh live Claude process evidence.

Changed files:

```text
apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift
apps/swift/Tests/CapacitorTests/RuntimeSnapshotApplicatorTests.swift
```

Focused regression:

```text
testRepeatedNonzeroSnapshotVersionRefreshesLiveProcessEvidence
```

It proves the durable snapshot payload remains version-protected while the volatile live-process overlay can move `Ready -> Idle` after the existing two-poll idle hysteresis.

## Final Live Retest

After rebuilding and relaunching the Debug app:

```text
timestamp: 2026-05-27T01:08:50Z
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app
capacitor_debug_processes:
10075 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
claude_processes:
```

Initial UI state:

```text
pete-2025: Idle
```

Controlled process state:

```text
timestamp: 2026-05-27T01:09:44Z
claude_processes:
11752 manual
```

UI state with the process alive:

```text
container Description: pete-2025, Details: Ready for input, ID: ax.project-card.pete-2025
button Description: Ready, Value: Ready for input
button Push starstruck changes
```

After stopping the controlled process:

```text
timestamp: 2026-05-27T01:10:28Z
claude_processes:
```

The rebuilt app refreshed the volatile overlay even though the durable snapshot version stayed at `4`:

```text
[2026-05-27T01:10:15.181Z] AppState.refreshSessionStates source=runtime_snapshot_volatile_refresh cid=app-snap-19 version=4
[2026-05-27T01:10:15.343Z] SessionStateManager.idleStabilize action=hold project=/Users/petepetrash/Code/pete-2025 count=1/2
[2026-05-27T01:10:25.188Z] AppState.refreshSessionStates source=runtime_snapshot_volatile_refresh cid=app-snap-21 version=4
[2026-05-27T01:10:25.346Z] SessionStateManager.idleStabilize action=commit project=/Users/petepetrash/Code/pete-2025 count=2
[2026-05-27T01:10:25.347Z] [DEBUG][ProjectsView][ResolvedCardStates] capacitor:Idle | pete-2025:Idle | arc-design-studio:Idle | parable-school:Idle | capacitor-circuit:Idle
```

Final UI state:

```text
container Description: pete-2025, Details: Idle, ID: ax.project-card.pete-2025
button Description: Idle, Value: Session is idle
button Push starstruck changes
```

## Verification

Passed:

```bash
swift test --package-path apps/swift --filter RuntimeSnapshotApplicatorTests
swift test --package-path apps/swift --filter 'RuntimeSnapshotApplicatorTests|SessionStateManagerTests|AppStateRuntimeSnapshotEffectTests'
./scripts/ci/swiftformat-lint.sh
git diff --check
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
swift test --package-path apps/swift
```

Results:

```text
RuntimeSnapshotApplicatorTests: 11 tests passed.
Adjacent snapshot/session/app-state tests: 45 tests passed.
SwiftFormat lint: 0 files require formatting.
git diff --check: passed.
Canonical Debug restart: passed.
Strict Debug preflight: Debug app pid 10075 frontmost, no release/non-Debug Capacitor processes, no Claude processes.
Full Swift: 953 XCTest cases, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
```

## Cleanup

The controlled process was stopped after the check.

Cleanup verification:

```text
timestamp: 2026-05-27T01:10:28Z
claude_processes:
```

## Remaining Risk

This proves the visible Ready projection for a process shape Capacitor recognizes. It does not replace a future live check with a real Claude Code process in an ordinary user-created cockpit, because real Claude process command lines and cwd shapes can vary.
