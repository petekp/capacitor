# Container Diagram

```mermaid
C4Container
  title Container Diagram for Capacitor

  Person(user, "User", "Uses Capacitor alongside Claude Code")
  System_Ext(claude, "Claude Code", "Local agent CLI")
  System_Ext(terminals, "Terminal Apps", "Ghostty, iTerm2, Terminal, tmux")
  System_Ext(ingest, "Optional Ingest Worker", "Cloudflare Worker + D1")

  System_Boundary(capacitor, "Capacitor System") {
    Container(swiftApp, "Swift macOS App", "SwiftUI, Swift", "UI shell, projection, setup orchestration, terminal activation, workstreams, feedback")
    Container(hudHook, "hud-hook", "Rust, tiny_http", "Local hook ingress server and shell CWD adapter")
    Container(coreRuntime, "capacitor-core", "Rust, UniFFI", "Reducer, snapshot persistence, setup services, project and idea APIs")
    ContainerDb(snapshot, "Runtime Snapshot", "JSON file", "~/.capacitor/runtime/app_snapshot.json")
    ContainerDb(claudeState, "Claude State", "JSON files, transcripts, project files", "~/.claude plus tracked project directories")
  }

  Rel(user, swiftApp, "Uses")
  Rel(claude, hudHook, "POSTs hook events and invokes cwd signals", "HTTP, CLI")
  Rel(hudHook, coreRuntime, "Calls ingest APIs", "UniFFI-linked Rust calls")
  Rel(coreRuntime, snapshot, "Reads and writes canonical runtime state")
  Rel(swiftApp, snapshot, "Reads runtime snapshot through RuntimeClient")
  Rel(swiftApp, coreRuntime, "Calls setup, catalog, and idea APIs", "UniFFI")
  Rel(coreRuntime, claudeState, "Reads and mutates Claude settings, project metadata, ideas")
  Rel(swiftApp, terminals, "Activates target terminal context")
  Rel(swiftApp, ingest, "Optionally sends telemetry and feedback", "HTTPS")
```

Container observations:

- The actual architecture is closer to a file-backed, local-first sidecar than a daemon/client model.
- `capacitor-core` is currently overloaded: it is both runtime engine and a broad service façade.
