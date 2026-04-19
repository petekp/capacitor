# Review Surfaces

> Doc role: `canonical-spec`
> Status: Current. Shared contract for delegation review and run checkpoint review windows.

## Overview

Capacitor presents two review surfaces that pause agent work and request human decisions:

1. **Delegation Review** -- driven by `DelegationLoopManager` milestone files during worker delegation loops.
2. **Run Checkpoint Review** -- driven by runtime snapshot `runs[].activeCheckpoint` state during managed runs.

Both surfaces share the same visual structure (left content pane, right decision rail, manifest-driven content) but differ in data source, lifecycle, and auto-close trigger. Each is registered as a dedicated `Window` scene in `App.swift`.

## Shared Structure

Both windows use an identical two-column layout:

| Region | Content |
|--------|---------|
| **Left pane** (~65% width) | Project name, review type badge, summary text, artifacts list, media artifacts, optional diff or mermaid sources |
| **Right rail** (~35% width) | Decision cards (Approve, Request Changes), optional notes `TextEditor`, submit button with spinner |

The left pane scrolls independently. The right rail has a fixed-width `background(Color.black.opacity(0.2))` region.

Both windows share:
- `DarkFrostedGlass()` background with `Color.black.opacity(0.15)` overlay
- `.defaultSize(width: 900, height: 650)` and `.windowResizability(.contentMinSize)` (`App.swift:174-175`, `App.swift:183-185`)
- `.suppressedFromWindowMenu()` -- not visible in the macOS Window menu
- `.preferredColorScheme(.dark)` forced dark mode
- `DelegationReviewManifest` as the shared decoder for manifest JSON

## Manifest Contract

`DelegationReviewManifest` (`DelegationReviewManifest.swift:3-97`) is the shared Decodable type used by both review windows.

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | `Int` | Yes | Schema version (currently `1`) |
| `milestone_id` | `String` | Yes | Identifies the milestone or checkpoint phase |
| `summary` | `String?` | No | Human-readable summary displayed in the content pane |
| `artifacts` | `[Artifact]` | Yes | Typed artifact array (see below) |
| `decisions` | `DecisionHints?` | No | Custom labels/descriptions for approve and request_changes buttons |
| `swift_changes` | `Bool?` | No | When `true`, shows a banner warning that the running app reflects the previous build (`DelegationReviewWindow.swift:196`) |

### Artifact Types

Defined in `DelegationReviewManifest.ArtifactType` (`DelegationReviewManifest.swift:4-28`):

| Type | `isMedia` | Usage |
|------|-----------|-------|
| `text` | `false` | File listings, logs |
| `screenshot` | `true` | Image rendered via `CaptureImageView` |
| `recording` | `true` | Video artifact with `duration_secs` |
| `mermaid` / `mermaid_diagram` | `true` | Mermaid diagram source (both strings decode to `.mermaid`, `DelegationReviewManifest.swift:19`) |

Each artifact carries optional `width`, `height`, and `duration_secs` metadata (`DelegationReviewManifest.swift:34-36`).

### DecisionHints

`DecisionHints` (`DelegationReviewManifest.swift:72-80`) provides custom labels for the approve/request_changes cards:

```json
{
  "decisions": {
    "approve": { "label": "Ship It", "description": "Changes look good" },
    "request_changes": { "label": "Needs Work", "description": "Layout is off" }
  }
}
```

Both windows fall back to default labels ("Approve" / "Request Changes") when hints are absent.

## Delegation Review Window

**Source:** `DelegationReviewWindow.swift`
**Scene ID:** `"delegation-review"` (`App.swift:169`)

### Data Source

Driven by `DelegationLoopManager` milestone files. The window reads:
- `appState.reviewWindowTarget` (`DelegationReviewWindow.swift:22-24`) for routing
- `appState.delegationState(forPath:)` for the `RuntimeDelegationState` (`DelegationReviewWindow.swift:26-29`)
- `currentReview.manifestPath` and `currentReview.briefPath` for artifact loading (`DelegationReviewWindow.swift:730-733`)

### Lifecycle

1. `reviewWindowTarget` is set explicitly by `AppState.showDelegationReview(_:)` (`AppState+Projects.swift`) when a delegation has an active review.
2. The window opens via `openWindow(id: "delegation-review")` triggered by `.onChange(of: appState.reviewWindowTarget)` in `ProjectsView` / `DockLayoutView`.
3. On submission, `submitDelegationReview(for:delegation:decision:note:fromWindow:)` is called (`DelegationReviewWindow.swift:670-688`).
4. After successful submission, the phase transitions to `.submitted` and a 2-second auto-close timer fires (`DelegationReviewWindow.swift:701-708`) that sets `reviewWindowTarget = nil`.
5. Setting `reviewWindowTarget = nil` triggers `dismissWindow(id: "delegation-review")` (`DelegationReviewWindow.swift:104-108`).

### Multi-Round Support

Supports revision iterations. When `milestoneNumber > 1`, a "Revision N" badge is shown (`DelegationReviewWindow.swift:153-163`). Previous round decisions are loaded from the prior milestone's `decision.json` and displayed in a "PREVIOUS ROUND" section (`DelegationReviewWindow.swift:361-393`, `DelegationReviewWindow.swift:781-801`).

### Decision Options

Three options (`DelegationReviewWindow.swift:806-810`):
- `.approve` -- maps to `DelegationLoopManager.ReviewDecision.approve`
- `.requestChanges` -- maps to `DelegationLoopManager.ReviewDecision.requestChanges`
- `.writeResponse` -- custom instructions (still submits as `requestChanges` with note, `DelegationReviewWindow.swift:662-664`)

The notes `TextEditor` appears only when `requestChanges` or `writeResponse` is selected (`DelegationReviewWindow.swift:459`).

### Swift Changes Banner

When `manifest.swiftChanges == true`, a dismissible banner warns that the running app reflects the previous build and offers a "Copy rebuild cmd" button that copies `./scripts/dev/restart-alpha-stable.sh` to the pasteboard (`DelegationReviewWindow.swift:196-238`).

## Run Checkpoint Review Window

**Source:** `RunCheckpointReviewWindow.swift`
**Scene ID:** `"run-checkpoint-review"` (`App.swift:178`)

### Data Source

Driven by the runtime snapshot's `runs` array. The window reads:
- `appState.runCheckpointWindowTarget` (`RunCheckpointReviewWindow.swift:19-21`) for routing
- `appState.runState(projectPath:runID:)` and `appState.runCheckpointState(target:)` to resolve the run and checkpoint (`RunCheckpointReviewWindow.swift:23-37`)
- `checkpoint.manifestPath` for optional manifest loading (`RunCheckpointReviewWindow.swift:460-494`)

### Lifecycle

1. `runCheckpointWindowTarget` is auto-selected by `RunStateStore.reconcileRunCheckpointWindowTarget` on every runtime snapshot apply (`RuntimeSnapshotApplicator.swift`, `RunState.swift`). The oldest paused checkpoint is chosen first.
2. The window opens via `openWindow(id: "run-checkpoint-review")` triggered by `.onChange(of: appState.runCheckpointWindowTarget)` in `ProjectsView` / `DockLayoutView`.
3. On submission, `submitRunCheckpointDecision(projectPath:runID:checkpointID:action:note:)` sends a `submit_decision` mutation to the runtime service (`AppState+Projects.swift`).
4. After successful submission, the phase transitions to `.submitted` and `refreshSessionStates()` is called (`RunCheckpointReviewWindow.swift:452-453`).
5. Auto-close occurs when the checkpoint disappears from the snapshot (resolved by the runtime). The `.onChange(of: resolvedCheckpointID)` observer dismisses the window when the checkpoint ID goes nil (`RunCheckpointReviewWindow.swift:90-94`).
6. Setting `runCheckpointWindowTarget = nil` also triggers `dismissWindow(id: "run-checkpoint-review")` (`RunCheckpointReviewWindow.swift:85-89`).

### Additional Content Sources

Beyond the shared manifest, run checkpoint review can display:
- `checkpoint.mediaArtifacts` filtered by `artifactType == "screenshot"` (`RunCheckpointReviewWindow.swift:193-205`)
- `checkpoint.mermaidSources` rendered as scrollable source blocks (`RunCheckpointReviewWindow.swift:207-235`)
- Checkpoint-native `title`, `summary`, `kind`, and `createdAt` metadata (`RunCheckpointReviewWindow.swift:132-149`)

### Decision Options

Two options (`RunCheckpointReviewWindow.swift:676-683`):
- `.approve` -- rawValue `"approve"`
- `.requestChanges` -- rawValue `"request_changes"`

Both buttons are always visible (no selection-then-submit pattern). The notes field is always visible with an "Optional Note" label (`RunCheckpointReviewWindow.swift:282-312`).

## Divergences

| Aspect | Delegation Review | Run Checkpoint Review |
|--------|-------------------|----------------------|
| **Data source** | `DelegationLoopManager` milestone files | Runtime snapshot `runs[].activeCheckpoint` |
| **Target type** | `ReviewWindowTarget(projectPath, workerID)` | `RunCheckpointWindowTarget(projectPath, runID, checkpointID)` |
| **Target assignment** | Explicit via `showDelegationReview(_:)` | Automatic via `reconcileRunCheckpointWindowTarget` |
| **Multi-round** | Yes (previous round decision display) | No |
| **Swift changes banner** | Yes | No |
| **Git diff display** | Yes (worktree `git diff HEAD`) | No |
| **Decision UX** | Select card, then submit | Two always-visible buttons |
| **Notes field visibility** | Only for `requestChanges`/`writeResponse` | Always visible |
| **Auto-close trigger** | 2-second timer after submission | Checkpoint disappears from runtime snapshot |
| **Submission target** | `DelegationLoopManager.acceptReviewDecision` | `RuntimeClient.mutateRun` (`submit_decision`) |
| **Scene ID** | `"delegation-review"` | `"run-checkpoint-review"` |

## Key Files

| Purpose | Path |
|---------|------|
| Delegation review window | `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift` |
| Run checkpoint review window | `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift` |
| Shared manifest decoder | `apps/swift/Sources/Capacitor/Models/DelegationReviewManifest.swift` |
| Window target types + routing | `apps/swift/Sources/Capacitor/Models/UIState.swift`, `apps/swift/Sources/Capacitor/Models/RunState.swift`, `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift` |
| Scene registration | `apps/swift/Sources/Capacitor/App.swift:169-185` |
| Window open triggers (dock) | `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift:110-115` |
| Window open triggers (projects) | `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:261-266` |

## Test Contracts

| Test | Validates |
|------|-----------|
| `DelegationReviewManifestTests` (`Tests/CapacitorTests/DelegationReviewManifestTests.swift`) | Manifest decoding: `swift_changes` flag (true/false/absent), `decisions` hints, `artifact_type` variants including `mermaid_diagram`, backwards compatibility for missing fields |
| `AppStateRunCheckpointTests` (`Tests/CapacitorTests/AppStateRunCheckpointTests.swift`) | Checkpoint routing policy: oldest-first selection, advance-on-clear, non-interference with delegation review state, submission mutation payload shape |
