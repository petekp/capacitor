# Namespace Purity Reference

Date: 2026-03-08

## Translation Guide

| Current path pattern | Target path pattern |
| --- | --- |
| setup policy/presentation helper in `Models/` | `Application/Setup/` |
| runtime value object in `Models/` | `Application/Runtime/` |
| runtime/session projector or shell state store in `Models/` | `Application/Runtime/` |
| worktree workflow state in `Models/` | `Application/Projects/` |
| outer UI/composition state in `Models/` | `Composition/` |
| shell/windowing helper in `Models/` | `Support/` |
| AX reader helper in `Models/` | `Support/` |

## First Slice Targets

Moved in `NP-301`:

- `Models/HookDiagnosticPresentation.swift` → `Application/Setup/HookDiagnosticPresentation.swift`
- `Models/HookPresentationPolicy.swift` → `Application/Setup/HookPresentationPolicy.swift`
- `Models/SetupStepCatalog.swift` → `Application/Setup/SetupStepCatalog.swift`
- `Models/SetupReadinessCoordinator.swift` → `Application/Setup/SetupReadinessCoordinator.swift`
- `Models/ShellSetupInstructions.swift` → `Application/Setup/ShellSetupInstructions.swift`
- `Models/RuntimeStatus.swift` → `Application/Runtime/RuntimeStatus.swift`
- `Models/WindowFrameStore.swift` → `Support/WindowFrameStore.swift`
- `Models/GhosttyAXReader.swift` → `Support/GhosttyAXReader.swift`

## Rehomed In NP-303

- `Models/RuntimeClient.swift` -> `Support/RuntimeClient.swift`
- `Models/SessionStateManager.swift` -> `Application/Runtime/SessionStateManager.swift`
- `Models/ShellStateStore.swift` -> `Application/Runtime/ShellStateStore.swift`
- `Models/TerminalLauncher.swift` -> `Support/TerminalLauncher.swift`
- `Models/WorkstreamsManager.swift` -> `Application/Projects/WorkstreamsManager.swift`
- `Models/AppState.swift` -> `Composition/AppState.swift`

## Remaining Namespace Debt

- no top-level Swift files remain under `Models/`
- the only remaining `Models/` residency is the nested `WindowAnchoring/` subtree

## Gotchas

- This tranche is about path hygiene, not architecture invention. Prefer moves over redesign.
- Preserve symbol names unless a name is itself misleading enough to justify a follow-on rename slice.
- Update any file-path assertions or docs that mention old locations.
