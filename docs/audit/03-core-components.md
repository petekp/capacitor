# Core Runtime Component Diagram

```mermaid
C4Component
  title Component Diagram for capacitor-core

  Container(hudHook, "hud-hook", "Rust", "Hook ingress adapter")
  Container(swiftApp, "Swift macOS App", "Swift", "Reads snapshots and calls FFI")
  ContainerDb(snapshot, "Runtime Snapshot File", "JSON", "Persisted runtime truth")
  ContainerDb(claudeState, "Claude State", "Files", "~/.claude and project data")

  Container_Boundary(coreRuntime, "capacitor-core") {
    Component(ingestNorm, "Ingress Normalizer", "Rust", "Normalizes hook events, shell signals, paths, and identities")
    Component(reducer, "Reducer and Query Engine", "Rust", "Applies event/state rules and derives project summaries")
    Component(snapshotStore, "Snapshot Storage", "Rust", "Loads and saves app_snapshot.json")
    Component(setupService, "Setup and Validation Service", "Rust", "Manages hook install, dependency checks, validation, and diagnostics")
    Component(projectCatalog, "Project and Idea Services", "Rust", "Loads dashboard data, projects, ideas, worktrees, and related file-backed state")
  }

  Rel(hudHook, ingestNorm, "Submits normalized commands")
  Rel(ingestNorm, reducer, "Transforms commands into reducer inputs")
  Rel(reducer, snapshotStore, "Persists snapshots")
  Rel(snapshotStore, snapshot, "Reads and writes")
  Rel(swiftApp, snapshotStore, "Indirectly reads via file-backed RuntimeClient")
  Rel(swiftApp, setupService, "Calls setup and diagnostics APIs")
  Rel(swiftApp, projectCatalog, "Calls dashboard, project, and idea APIs")
  Rel(setupService, claudeState, "Reads and mutates Claude config")
  Rel(projectCatalog, claudeState, "Reads and writes project metadata and ideas")
```

Component observations:

- The reducer path is reasonably coherent and well-tested.
- The FFI surface does not preserve this clean split. `CoreRuntime` currently exposes runtime, setup, project catalog, and idea concerns as one object.
