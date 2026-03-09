# True Ending Reference

Date: 2026-03-08

## Translation Guide

| Current pattern | Target pattern |
| --- | --- |
| nested support infrastructure still under `Models/` | move it under `Support/` with a focused subnamespace |
| historical checkpoint doc that still contains `TODO (user-run)` or deleted-path claims | replace it with an archive note that points at the current authoritative audit/checkpoint |
| live reliability ratchet pointing at deleted code | retarget it to the live file first, then calibrate the budget truthfully |
| stale ratchet budget with zero live matches | lower the budget to `0` immediately |
| startup subprocess probe in a live manager | replace synchronous `waitUntilExit()` with an async termination callback or background task that preserves stop/restart dominance |
| broad `AppState` collaborator surface | decide explicitly whether it is intentional environment access or residual service-locator debt before shrinking |

## Finish-Line Gotchas

- Namespace cleanup is not finished until nested subtrees are counted too. Getting the top-level `Models/*.swift` budget to `0` was necessary but not sufficient.
- Historical docs are dangerous when they still look actionable. A clearly archived stub is better than a detailed but stale checkpoint.
- Fixing a stale ratchet can make the repo look worse before it looks better. That is expected. A newly red guard against live code is progress.
- `WindowAnchoring` is AppKit support infrastructure. Do not move it into `Application` just because it touches UI behavior.
- `AppState` surface cleanup is high blast radius because many views/tests access collaborators through the environment object. Do not start that slice without deciding what should remain intentionally reachable.

## Example Patterns

### Archive stale historical guidance

Before:

```md
## Manual Smoke Checklist
| Scenario | Result |
| --- | --- |
| Cold launch | TODO (user-run) |
```

Target shape:

```md
## Historical Note
This checkpoint is archived and superseded by the latest finish-line audit.
The original manual checklist was never executed and is preserved only in git history.
```

### Rehome support infrastructure out of `Models`

Before:

```text
apps/swift/Sources/Capacitor/Models/WindowAnchoring/WindowAnchoringController.swift
```

Target shape:

```text
apps/swift/Sources/Capacitor/Support/WindowAnchoring/WindowAnchoringController.swift
```

This move is now complete for:

- `AnchorTypes.swift`
- `WindowBoundsProvider.swift`
- `WindowAnchoringController.swift`

### Fix a stale ratchet honestly

Before:

```bash
check_budget "HookServer waitUntilExit" 'waitUntilExit()' 0 "apps/swift/Sources/Capacitor/Models/HookServerManager.swift"
```

Target sequence:

```bash
check_budget "HookServer waitUntilExit" 'waitUntilExit()' 1 "apps/swift/Sources/Capacitor/Support/HookServerManager.swift"
```

Then remove the live call in the next slice and ratchet from `1` to `0`.

## Final Decisions

- `Composition/AppState.swift` remains the intentional SwiftUI shell-environment hub.
- `architecture/` remains the repo’s permanent architecture-governance surface rather than archived migration debris.
