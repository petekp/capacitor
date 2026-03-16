# Capacitor: A Literate Guide

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

*A narrative walkthrough of the Capacitor codebase, ordered for human understanding.*

---

## §1. The Problem: Agent Blindness

You're running five Claude Code sessions across three projects. One is writing tests, another is refactoring a module, a third is waiting for you to approve a file write. You can't see any of this. Each session lives in a terminal tab, and terminals are opaque rectangles — they show you text, not status. The only way to know what's happening is to switch to each tab, scan the output, and build a mental model of the whole system by hand.

This is the problem Capacitor exists to solve. Not by replacing Claude Code — not by intercepting its conversations or calling the Anthropic API — but by *observing* it. Capacitor is a glanceable companion app: a small macOS window that shows you what every agent session is doing, right now, and lets you click to jump to the right terminal.

That description sounds simple, but making it real requires solving several hard problems: How do you know what Claude Code is doing? How do you map a session to a project? How do you find the right terminal window? How do you keep the UI from flickering when hook events arrive milliseconds apart?

This guide tells the story of how each of those problems is solved.

---

## §2. The Sidecar Principle

Before we look at any code, we need to understand the architectural constraint that shapes everything else. Capacitor is a *sidecar*. It observes Claude Code's behavior without participating in it:

- **Read from `~/.claude/`** — transcripts, configuration, plugin registries. This is Claude Code's namespace.
- **Write to `~/.capacitor/`** — runtime artifacts, logs, state files. This is our namespace.
- **Never call the Anthropic API** — if we need to invoke Claude, we call the `claude` CLI.
- **Never modify Claude's state** — no writing to Claude's config, no injecting behavior.

This isn't just a design preference — it's the load-bearing constraint. Capacitor must work with any version of Claude Code, must not interfere with ongoing sessions, and must gracefully degrade if Claude Code changes its hook contract. The sidecar principle keeps us on the safe side of all three.

The practical consequence is a clean data flow: Claude Code fires lifecycle hooks → Capacitor's Rust core ingests and reduces them into a world model → Swift reads that model and renders the UI. Information flows one direction, from Claude's namespace into ours, never the reverse.

---

## §3. Two Languages, One Boundary

Capacitor is built in two languages, and the split is deliberate.

**Rust** (`core/capacitor-core/`, `core/hud-hook/`) owns everything that must be fast, deterministic, and testable without a GUI: event ingestion, state reduction, project identity resolution, snapshot storage, and the runtime HTTP service. Rust is the *source of truth* for domain semantics.

**Swift** (`apps/swift/`) owns everything that must be native to macOS: the SwiftUI view layer, window management, terminal automation via AppleScript, and the projection/hysteresis logic that turns raw state into stable UI. Swift is the *source of truth* for user experience.

The boundary between them is a local HTTP service. The Rust binary `hud-hook` runs a small server on `127.0.0.1:7474` that exposes the current state via `GET /runtime/snapshot`. Swift polls this endpoint every two seconds. There's also a UniFFI bridge for non-runtime APIs (setup checks, project CRUD, dashboard loading), but for live session state, the HTTP service is the canonical path.

This split means you can test the entire domain model — every state transition, every edge case in project identity — with `cargo test`, no Xcode required. And you can iterate on the UI with `swift build` without touching Rust, as long as the dylib is already built.

---

## §4. The Vocabulary

Every system has a vocabulary, and learning it early saves confusion later. Here are Capacitor's core concepts, defined in `core/capacitor-core/src/domain/types.rs`:

**Session** — A single Claude Code conversation. Identified by a `session_id` (UUID), associated with a project path and a process ID. A session has a *state*:

```rust
// core/capacitor-core/src/domain/types.rs:7-14
pub enum SessionState {
    Working,     // Agent is executing tools
    Ready,       // Awaiting user input
    Idle,        // Default / no recent activity
    Compacting,  // Transcript compaction in progress
    Waiting,     // Permission dialog active
}
```

Notice that each state has a *priority*:

```rust
// core/capacitor-core/src/domain/types.rs:18-26
pub fn priority(self) -> u8 {
    match self {
        Self::Waiting => 4,
        Self::Working => 3,
        Self::Compacting => 2,
        Self::Ready => 1,
        Self::Idle => 0,
    }
}
```

Waiting is highest priority because it requires immediate human attention — the agent is blocked. Working is next because something is actively happening. This priority ordering drives the UI: when a project has multiple sessions, the project's overall state is the *maximum priority* across all its sessions (§8).

**Project** — A directory on disk where code lives. Identified by a `project_path` (normalized, lowercased on macOS) and a `project_id` (typically the `.git` directory path). A project *aggregates* sessions: it has a state derived from its sessions, counts of total and active sessions, and timestamps.

**Shell** — A terminal shell process. Identified by PID. Reports its current working directory, TTY device, parent terminal app (Ghostty, iTerm, etc.), and tmux context. Shells are how Capacitor knows *where* a session is running — which terminal tab, which tmux pane.

**Routing** — The mapping from a project to a terminal target. Given a project's shells, Capacitor derives a `RoutingView` that says: "this project is reachable via tmux pane `%3` in session `capacitor`, attached to Ghostty via `/dev/ttys004`." Routing is what makes "click project → land in terminal" possible (§10, §15).

**Snapshot** — The complete world state at a point in time:

```rust
// core/capacitor-core/src/domain/types.rs:143-151
pub struct AppSnapshot {
    pub projects: Vec<ProjectSummary>,
    pub sessions: Vec<SessionSummary>,
    pub shells: Vec<ShellSignal>,
    pub routing: Vec<RoutingView>,
    pub diagnostics: DiagnosticsSummary,
    pub generated_at: String,
}
```

This is the data structure that crosses every boundary in the system: Rust produces it, the HTTP service serves it, Swift consumes it. Its shape defines the contract between the two halves of the application.

---

## §5. Hearing What Claude Does

How does Capacitor know that a session just started working, or that a permission dialog appeared? Through **hooks** — lifecycle callbacks that Claude Code fires at defined moments.

Claude Code supports 18 hook event types. Capacitor cares about the stateful ones:

| Event | Meaning |
|-------|---------|
| `SessionStart` | A new conversation began |
| `UserPromptSubmit` | The user sent a message |
| `PreToolUse` / `PostToolUse` | Agent is calling tools |
| `PermissionRequest` | Agent needs human approval |
| `PreCompact` | Transcript is being compacted |
| `Notification` | Various (idle prompt, auth, permission) |
| `TaskCompleted` | An agent task finished |
| `Stop` | Session stopped |
| `SessionEnd` | Session terminated |

And the informational ones it acknowledges but skips: `SubagentStart`, `SubagentStop`, `TeammateIdle`, `WorktreeCreate`, `WorktreeRemove`, `ConfigChange`. These are recognized so they don't trigger "unknown event" warnings, but they don't change session state.

Hooks arrive as HTTP POST requests to the `hud-hook` server. The hook configuration is installed into Claude Code's `~/.claude/settings.json` by Capacitor's setup process, pointing each hook type at `http://127.0.0.1:7474/runtime/ingest/hook-event`.

---

## §6. The Gate

Not every hook event should change state. The handler in `core/hud-hook/src/handle.rs` acts as a *gate* — a classification pass that decides whether an event is stateful, informational, or should be skipped entirely.

```rust
// core/hud-hook/src/handle.rs:206-283
fn process_event(
    event: &HookEvent,
    current_state: Option<SessionState>,
    input: &HookInput,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    match event {
        HookEvent::SessionStart => {
            if is_active_state(current_state) {
                (Action::Skip, None, None)   // Don't downgrade working→ready
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }
        HookEvent::UserPromptSubmit => (Action::Upsert, Some(SessionState::Working), None),
        HookEvent::PreToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Refresh, None, None) // Already working, just refresh timestamp
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }
        // ...
    }
}
```

Two guards deserve special attention:

**The subagent stop guard** (line 80): When a subagent finishes, Claude Code fires a `Stop` event with the *parent* session's ID. Without this guard, the parent session would incorrectly transition from Working to Ready every time a subagent completed. The fix is simple — if the event has an `agent_id`, skip it:

```rust
// core/hud-hook/src/handle.rs:78-92
if matches!(event, HookEvent::Stop { .. }) && hook_input.agent_id.is_some() {
    // Skipping subagent Stop event — they share the parent session_id
    // but shouldn't affect the parent session's state.
    return Ok(());
}
```

**The stop_hook_active guard**: When `stop_hook_active` is `true`, it means a stop hook is *about to run* (the session is pausing to execute the hook, not actually stopping). We skip these — the session will resume after the hook completes.

After classification, the event is forwarded to the runtime service via the dual-transport mechanism described in §11.

---

## §7. Normalizing the Signal

Before the reducer (§8) sees an event, the ingest layer normalizes it. This is a short but critical piece of code in `core/capacitor-core/src/ingest/mod.rs`:

```rust
// core/capacitor-core/src/ingest/mod.rs:6-23
pub fn normalize_hook_event(command: IngestHookEventCommand) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: command.event_id.trim().to_string(),
        session_id: command.session_id.trim().to_string(),
        project_path: normalize_required_path(&command.project_path),
        cwd: normalize_optional_path(command.cwd),
        notification_type: normalize_optional_text(command.notification_type),
        // ...
    }
}
```

Every string is trimmed. Every path is normalized via `normalize_path_for_matching`, which strips trailing slashes and — crucially on macOS — lowercases the entire path. Empty optional fields become `None` rather than `Some("")`. This means the reducer never has to worry about whitespace, trailing slashes, or case sensitivity. It receives clean, canonical input.

Why lowercase on macOS? Because APFS is case-insensitive by default. `/Users/Pete/Code` and `/users/pete/code` are the same directory, and if we don't normalize for this, we'll create duplicate project entries every time Claude reports a path with different casing. The normalization is behind a `#[cfg(target_os = "macos")]` gate so it doesn't affect case-sensitive filesystems:

```rust
// core/capacitor-core/src/domain/identity.rs:92-101
#[cfg(target_os = "macos")]
{
    normalized.to_lowercase()
}

#[cfg(not(target_os = "macos"))]
{
    normalized.to_string()
}
```

---

## §8. The Reducer

The reducer is the heart of the Rust core. It lives in `core/capacitor-core/src/reduce/mod.rs` and implements a pure state machine: given the current state and an incoming event, produce the next state.

The `ReducerState` holds four collections:

```rust
// core/capacitor-core/src/reduce/mod.rs:17-22
pub struct ReducerState {
    pub projects: BTreeMap<String, ProjectSummary>,  // sorted by path
    pub sessions: HashMap<String, SessionSummary>,    // keyed by session_id
    pub shells: HashMap<u32, ShellSignal>,             // keyed by PID
    pub routing: BTreeMap<String, RoutingView>,        // keyed by workspace_id|path
    // ...diagnostics counters...
}
```

`BTreeMap` for projects and routing (sorted output, deterministic iteration). `HashMap` for sessions and shells (fast lookup by ID/PID).

When a hook event arrives, `apply_hook_event` does four things:

1. **Validate** — reject if event_id or session_id is missing.
2. **Stale-check** — if the session already has a more recent event, skip this one. This handles out-of-order delivery with a 5-second grace window.
3. **Reduce** — call `reduce_session` to compute the session update.
4. **Recompute** — rebuild the projects and routing views from the updated sessions.

The `reduce_session` function is the state machine itself:

```rust
// core/capacitor-core/src/reduce/mod.rs:579-692
fn reduce_session(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
) -> SessionUpdate {
    match event.event_type {
        HookEventType::SessionStart => {
            let already_working = current
                .map(|r| r.state == SessionState::Working || r.state == SessionState::Waiting)
                .unwrap_or(false);
            if already_working {
                SessionUpdate::Skip("session_start_already_active")
            } else {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Ready, None))
            }
        }
        HookEventType::UserPromptSubmit | HookEventType::PreToolUse => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
        }
        HookEventType::PermissionRequest => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Waiting, None))
        }
        HookEventType::SessionEnd => {
            let pid = event.pid.or_else(|| current.map(|r| r.pid)).unwrap_or(0);
            if pid > 0 && is_pid_alive(pid) {
                // PID still alive — session was cleared, not terminated
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Ready, Some("session_cleared".into())))
            } else {
                SessionUpdate::Delete(event.session_id.clone())
            }
        }
        // ...
    }
}
```

A subtle design decision lives in the `SessionEnd` branch: before deleting a session, we check if its PID is still alive. If the process is still running, we treat the event as a "session cleared" (transition to Ready) rather than a deletion. This handles the case where Claude Code restarts a session in-place — the old session ends but the process continues.

After updating the sessions map, `recompute_projects` rolls up session state into project summaries. The key insight: a project's state is the *maximum priority* across all its sessions. If one session is Idle but another is Working, the project shows Working. If any session is Waiting (priority 4), the project shows Waiting — because that's the thing that needs human attention most urgently.

---

## §9. Knowing Which Project

Given a file path — say `/Users/pete/Code/capacitor/apps/swift/Sources/main.swift` — which *project* does it belong to? This is the project identity problem, solved in `core/capacitor-core/src/domain/identity.rs`.

The algorithm walks upward from the given path, looking for project markers:

```rust
// core/capacitor-core/src/domain/identity.rs:4-16
const PROJECT_MARKERS: &[(&str, u8)] = &[
    ("CLAUDE.md", 1),      // Highest priority — definitive project root
    ("package.json", 2),
    ("Cargo.toml", 2),
    ("pyproject.toml", 2),
    ("go.mod", 2),
    // ...
    (".git", 3),
    ("Makefile", 4),
    ("CMakeLists.txt", 4),
];
```

`CLAUDE.md` has priority 1 (lowest number = highest priority) and *terminates the walk* — if you find it, that's the project root, period. This makes sense: `CLAUDE.md` is the one marker that's definitionally associated with a Claude Code project. Package manifests like `Cargo.toml` and `package.json` have priority 2 — strong signals, but the walk continues upward in case there's a `CLAUDE.md` above. `.git` has priority 3 — it's a project boundary, but a less specific one than a manifest file.

But there's a twist. In monorepos, a single `.git` directory covers multiple packages. And with git worktrees, the `.git` entry might be a *file* pointing to a `gitdir:` path in the main repo's `.git/worktrees/` directory. The identity system handles both:

```rust
// core/capacitor-core/src/domain/identity.rs:236-285
fn resolve_git_info(path: &Path) -> Option<GitInfo> {
    // ...
    let git_entry = dir.join(".git");
    if git_entry.is_dir() {
        // Normal repo — .git is a directory
        return Some(GitInfo { is_worktree: false, /* ... */ });
    }
    // Worktree — .git is a file with "gitdir: ..." content
    let git_dir = parse_gitdir(&git_entry, &dir)?;
    if let Some(common_dir) = parse_commondir(&git_dir) {
        // Found commondir — this is a worktree of another repo
        return Some(GitInfo { is_worktree: true, /* ... */ });
    }
}
```

The `workspace_id` is computed as `MD5(project_id|relative_path)`, lowercased on macOS. This gives each project a stable identifier that doesn't change when the user types the path in a different case, and — critically — resolves to the *same* ID whether you're working in the main repo or a worktree of it. The test at line 376 makes this guarantee explicit:

```rust
// core/capacitor-core/src/domain/identity.rs:369-373
fn workspace_id_is_stable_for_case_changes() {
    let first = workspace_id("/Users/Pete/Code/Repo/.git", "/Users/Pete/Code/Repo");
    let second = workspace_id("/users/pete/code/repo/.git", "/users/pete/code/repo");
    assert_eq!(first, second);
}
```

---

## §10. Routing: Matching Shells to Projects

Once we know which sessions belong to which projects, we need to figure out *where* those sessions are running — which terminal, which tmux session, which pane. This is routing, and it's computed in `recompute_routing` after every state change.

The algorithm selects the *best shell* for each project by ranking candidates:

```rust
// core/capacitor-core/src/reduce/mod.rs:401-421
fn shell_match_rank(shell: &ShellSignal, project_path: &str, session_pids: &[u32]) -> u8 {
    if session_pids.contains(&shell.pid) {
        2  // Shell PID matches a known session — strongest signal
    } else if paths_match(shell.cwd.as_str(), project_path) {
        1  // Shell CWD is within the project — good signal
    } else {
        0  // No match
    }
}

fn shell_target_rank(shell: &ShellSignal) -> u8 {
    if shell.tmux_pane.is_some() {
        3  // Pane-level precision — best for activation
    } else if shell.tmux_session.is_some() {
        2  // Session-level — good enough to switch
    } else if routing_parent_app(shell.parent_app.as_str()).is_some() {
        1  // Know the terminal app — can at least activate it
    } else {
        0  // No usable routing target
    }
}
```

The resulting `RoutingView` tells Swift everything it needs for terminal activation (§15): the routing status (attached, detached, or unavailable), the target type (tmux pane, tmux session, or terminal app), and the host TTY that connects the tmux client to a specific terminal window.

---

## §11. The Runtime Service

The Rust core doesn't run inside the Swift app. It runs as a separate process — `hud-hook serve` — that listens on `127.0.0.1:7474` and handles both hook event ingestion and snapshot queries.

```rust
// core/hud-hook/src/serve.rs:44-87
pub fn run(port: u16) -> Result<(), String> {
    let server = tiny_http::Server::http(&addr).map_err(/* ... */)?;
    let runtime_service = RuntimeServerState::new(port)?;
    loop {
        if SHUTDOWN.load(Ordering::Relaxed) { break; }
        let request = match server.recv_timeout(Duration::from_millis(500)) {
            Ok(Some(req)) => req,
            Ok(None) => continue,  // timeout, check shutdown flag
            Err(e) => { continue; }
        };
        dispatch(request, &runtime_service);
    }
}
```

The server uses `tiny_http` — a minimal, zero-dependency HTTP server. It polls with a 500ms timeout so it can check the shutdown flag between requests, enabling graceful SIGTERM handling.

The dispatch table is clean:

```rust
// core/hud-hook/src/serve.rs:89-108
fn dispatch(request: tiny_http::Request, runtime_service: &RuntimeServerState) {
    match (request.method(), request.url()) {
        (&Get, "/health")                        => handle_health(/* ... */),
        (&Get, "/runtime/snapshot")              => handle_runtime_snapshot(/* ... */),
        (&Post, "/runtime/ingest/hook-event")    => handle_runtime_ingest_hook_event(/* ... */),
        (&Post, "/runtime/ingest/shell-signal")  => handle_runtime_ingest_shell_signal(/* ... */),
        (&Post, "/hook")                         => handle_hook(request),
        _ => { let _ = request.respond(json_error(404, "not found")); }
    }
}
```

The health endpoint is authenticated: it reads a bootstrap token from `~/.capacitor/runtime/runtime-service.json` and checks the `Authorization` header. This prevents other processes on the machine from querying or tampering with the runtime state.

**The dual-transport trick** lives in `core/hud-hook/src/runtime_client.rs`. When the hook handler runs *inside* `hud-hook serve`, it doesn't make an HTTP call to itself — it calls `CoreRuntime::ingest_hook_event` directly via a registered `Arc<CoreRuntime>`:

```rust
// core/hud-hook/src/runtime_client.rs:110-127
enum RuntimeTransport {
    Service(RuntimeServiceEndpoint),       // HTTP call to external service
    RegisteredService(Arc<CoreRuntime>),   // Direct in-process call
}

fn runtime_transport() -> Result<RuntimeTransport, String> {
    if let Some(runtime) = REGISTERED_SERVICE_RUNTIME.get() {
        return Ok(RuntimeTransport::RegisteredService(Arc::clone(runtime)));
    }
    // Fall back to HTTP endpoint discovery
    runtime_service_endpoint()?.map(RuntimeTransport::Service)
        .ok_or_else(|| "runtime service endpoint unavailable".to_string())
}
```

This means `hud-hook cwd` (the shell integration command, §16) can send events either way: in-process if it's running within the serve context, or via HTTP if it's an external invocation. Same semantic path, different transports.

---

## §12. Crossing the Bridge

The Rust core exports types and methods to Swift via [UniFFI](https://mozilla.github.io/uniffi-rs/). The facade lives in `core/capacitor-core/src/lib.rs`:

```rust
// core/capacitor-core/src/lib.rs:77-82
#[derive(uniffi::Object)]
pub struct CoreRuntime {
    state: std::sync::Mutex<reduce::ReducerState>,
    snapshot_storage: Arc<dyn SnapshotStorage>,
    app_storage: StorageConfig,
}
```

The `#[uniffi::Object]` attribute generates Swift bindings that let Swift hold a reference to the Rust object and call methods on it. Record types like `AppSnapshot`, `ProjectSummary`, and `SessionSummary` use `#[uniffi::Record]` and become Swift structs. Enums like `SessionState` use `#[uniffi::Enum]` and become Swift enums.

One gotcha lives at this boundary: UniFFI generates a type called `Task`, which shadows Swift's `_Concurrency.Task`. Any async Swift code that touches UniFFI-generated types must explicitly qualify `_Concurrency.Task` to avoid ambiguity. This is called out in the project's gotchas file and is easy to forget.

Errors cross the bridge as simple strings:

```rust
// core/capacitor-core/src/lib.rs:57-61
#[derive(uniffi::Error)]
pub enum CoreRuntimeError {
    #[error("{message}")]
    General { message: String },
}
```

This is a deliberate simplification. Rich error types don't survive FFI boundaries well, and Swift's error handling is different enough from Rust's that a simple string message is more useful than a structured error that requires complex mapping.

For live session state, though, Swift doesn't use the UniFFI bridge at all — it queries the HTTP service via `RuntimeClient.swift`. The UniFFI path is reserved for setup, configuration, project CRUD, and other non-real-time operations.

---

## §13. The Swift Projection Layer

Here's the central insight of Capacitor's UI architecture: **raw truth is not good enough for a UI**.

The Rust reducer produces correct state, but it produces it at the cadence of hook events — which can arrive in bursts, drop out temporarily, or lag behind reality. If Swift rendered the raw state directly, you'd see:

- **Flicker on transient gaps** — when one session ends and another starts for the same project, there's a brief window where the project has no active sessions. The UI would flash to Idle and back to Working in under a second.
- **Phantom emptiness** — if the runtime service takes a moment to respond, the snapshot might be empty. The UI would blank out and then repopulate.
- **Stale working states** — Claude Code doesn't always fire `Stop` on interrupt. A session might show "Working" forever.

The `SessionStateManager` in `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` solves all three with a projection and stabilization pipeline:

```
Runtime Snapshot → Merge with Pinned Projects → Stabilize Empty → Stabilize Idle → Animate
```

**Empty snapshot stabilization** holds the previous state for 2 consecutive empty snapshots before committing:

```swift
// apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:172-215
private func stabilizeEmptyRuntimeSnapshotIfNeeded(
    _ merged: [String: ProjectSessionState],
) -> [String: ProjectSessionState] {
    if merged.isEmpty {
        guard !sessionStates.isEmpty else {
            return merged  // Nothing to hold — we were already empty
        }
        consecutiveEmptySnapshotCount += 1
        if consecutiveEmptySnapshotCount < Constants.emptySnapshotCommitThreshold {
            return sessionStates  // Hold previous state
        }
        consecutiveEmptySnapshotCount = 0
        return merged  // Threshold reached — commit the empty state
    }
    consecutiveEmptySnapshotCount = 0
    return merged
}
```

**Idle transition hysteresis** is asymmetric: active→idle requires 2 consecutive idle snapshots (at 2-second polling, that's a 4-second hold), but idle→active is instant. This prevents brief idle flickers during session hand-offs:

```swift
// apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:223-263
private func stabilizeIdleTransitions(
    _ incoming: [String: ProjectSessionState],
) -> [String: ProjectSessionState] {
    for (path, incomingState) in incoming {
        let isIncomingIdle = incomingState.state == .idle
        let wasActive = sessionStates[path].map { $0.state != .idle } ?? false

        if isIncomingIdle, wasActive {
            let count = (consecutiveIdleCounts[path] ?? 0) + 1
            consecutiveIdleCounts[path] = count
            if count < Constants.idleCommitThreshold {
                result[path] = sessionStates[path]!  // Hold active state
            }
            // else: threshold reached, commit idle
        }
    }
}
```

**Stale working detection** catches the case where Claude Code was interrupted without firing `Stop`. If a session has been in Working state for over 2 minutes with no new events, it's downgraded to Ready. This happens in `normalizedRuntimeState`:

```swift
// apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:578-586
private nonisolated func normalizedRuntimeState(_ state: RuntimeProjectState, now: Date) -> SessionState {
    var mappedState = mapRuntimeState(state.state)
    if SessionStaleness.isWorkingStale(state: mappedState, updatedAt: state.updatedAt, now: now) {
        mappedState = .ready
    }
    return mappedState
}
```

The matching logic in `mergeRuntimeProjectStates` is also worth understanding. It doesn't just match by exact path — it handles monorepos (where the runtime might report activity at a different subdirectory than the user pinned) and worktrees (where two paths resolve to the same logical project). Direct path matches have priority over repo-fallback matches, and more recent activity wins ties. This is what makes the UI feel correct even when users pin a subdirectory of a monorepo but sessions run elsewhere in the same repo.

---

## §14. The Composition Root

`AppState` in `apps/swift/Sources/Capacitor/Models/AppState.swift` is the composition root — the single `@Observable @MainActor` class that holds the entire app's state and coordinates between subsystems. At ~1500 lines, it's the largest file in the codebase.

It holds:
- **Projects and their states** — the list of pinned projects, their session states (via `SessionStateManager`), ordering, and dormancy.
- **Runtime communication** — the `RuntimeClient` that polls the service, the refresh timer, the latest snapshot.
- **Feature flags** — channel/profile (alpha/stable, stable/frontier), and gates for features like idea capture and project details.
- **Coordinators** — `HookServerManager` (manages the hud-hook process), `ProjectCreationCoordinator` (tracks new project creations), `SetupReadinessCoordinator` (startup validation), and `TerminalActivationCoordinator` (deduplicates rapid clicks).

The refresh cycle is straightforward: every 2 seconds, `AppState` fetches a snapshot from the runtime service, passes it to `SessionStateManager.applyRuntimeProjectStates()`, and lets the projection pipeline (§13) handle stabilization and animation. This polling approach is simpler and more resilient than a push-based system — if the service restarts, the next poll picks up the new state automatically.

---

## §15. Terminal Activation

The signature feature: you click a project card, and Capacitor brings you to the right terminal. This is `TerminalLauncher` in `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`.

The activation flow for Ghostty + tmux (the primary path):

1. **Resolve tmux session name** — check routing hints, query existing tmux sessions, fall back to the project directory name.
2. **Resolve any attached tmux client** — via `tmux list-clients`, preferring a client attached to the target session.
3. **If a client exists**: ensure the session exists → switch the client to it → focus the terminal window.
4. **If no client exists**: launch a new Ghostty tab with `tmux new-session -A -s <name>`.

The `TerminalActivationCoordinator` wraps this in deduplication logic: if the user clicks project A, then immediately clicks project B, the first activation is cancelled and only B proceeds. This prevents tab proliferation from rapid clicks.

```swift
// apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:87-132 (structure)
@MainActor
final class TerminalLauncher {
    private lazy var driverRegistry = TerminalDriverRegistry(/* ... */)
    private var tmuxRouter: TmuxRouter { TmuxRouter(/* ... */) }
    private lazy var activationCoordinator = TerminalActivationCoordinator(
        resolveSessionName: { [weak self] project in
            await self?.resolveSessionName(for: project)
        },
        runResolvedActivation: { [weak self] sessionName, projectPath in
            await self?.runResolvedActivation(sessionName: sessionName, projectPath: projectPath)
        },
    )
}
```

Terminal-specific behavior is abstracted behind the `TerminalDriver` protocol. Ghostty gets native AppleScript automation via `GhosttyAutomationClient`. iTerm2 and Terminal.app get their own drivers. This means adding support for a new terminal is a matter of implementing the protocol, not modifying the activation logic.

Shell scripts are executed via `runBashScriptWithResult`, which uses `Process` with a 10-second timeout, task cancellation support, and thread-safe continuation handling via a `ContinuationBox` pattern — a defensive approach to the fact that `Process.terminationHandler` runs on an arbitrary thread while Swift's structured concurrency needs a `CheckedContinuation`.

---

## §16. Shell Integration

How does Capacitor know which terminal has which project open? Through shell CWD tracking, implemented in `core/hud-hook/src/cwd.rs`.

Every time your shell prompt redraws (via `precmd` in zsh or `PROMPT_COMMAND` in bash), a snippet calls:

```bash
hud-hook cwd "$PWD" $$ "$(tty)"
```

This sends the current working directory, the shell PID, and the TTY device to the runtime. The `cwd` module has a hard performance target: **under 15 milliseconds**, because it runs on every prompt. The shell spawns it in the background, so users never wait, but we still want it fast.

The module does four things:

1. **Normalize the path** — strip trailing slashes, resolve case on macOS by walking the real directory entries:

```rust
// core/hud-hook/src/cwd.rs:115-156
fn merge_canonical_case(original: &Path, _canonical: &Path) -> String {
    for part in &original_parts {
        if let Ok(entries) = std::fs::read_dir(&real_path) {
            for entry in entries.filter_map(Result::ok) {
                if name.eq_ignore_ascii_case(part) {
                    real_path.push(name);  // Use the actual case from the filesystem
                    break;
                }
            }
        }
    }
}
```

2. **Detect the parent terminal app** — read `TERM_PROGRAM` for most terminals, `TERM` for Kitty/Alacritty, `TMUX` as a fallback:

```rust
// core/hud-hook/src/cwd.rs:200-231
fn detect_parent_app(_pid: u32) -> ParentApp {
    if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
        match normalized.as_str() {
            "ghostty" => return ParentApp::Ghostty,
            "iterm.app" | "iterm2" => return ParentApp::ITerm,
            "cursor" => return ParentApp::Cursor,
            // ...
        }
    }
}
```

3. **Detect tmux context** — if the `TMUX` env var is set, run `tmux display-message -p "#S\t#{client_tty}"` to get the session name and client TTY. This has a 500ms timeout with kill-on-timeout to prevent hangs.

4. **Send to runtime** — construct an `IngestShellSignalCommand` and send it via the dual-transport mechanism (§11).

The parent app detection uses environment variables rather than process tree walking because it's faster and more portable. The tradeoff is that inside tmux, `TERM_PROGRAM` reflects the *host* terminal (Ghostty, iTerm), not tmux itself — which is actually what we want, since we need to know which terminal app to activate.

---

## §17. Storage: Crash-Safe Persistence

Every time the reducer state changes, the snapshot is persisted to `~/.capacitor/runtime/app_snapshot.json`. The `JsonFileSnapshotStorage` in `core/capacitor-core/src/storage/mod.rs` uses atomic writes to prevent corruption:

```rust
// core/capacitor-core/src/storage/mod.rs:78-103
fn save_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), String> {
    let _guard = self.io_lock.lock().map_err(/* ... */)?;

    Self::ensure_parent_dir(&self.path)?;

    let payload = serde_json::to_vec_pretty(snapshot).map_err(/* ... */)?;

    // Write to temp file, then rename — atomic on POSIX
    let temp_path = self.path.with_file_name(format!("{file_name}.tmp"));
    fs::write(&temp_path, payload).map_err(/* ... */)?;
    fs::rename(&temp_path, &self.path).map_err(/* ... */)?;

    Ok(())
}
```

The temp-file-then-rename pattern ensures that the snapshot file is always either the old version or the new version, never a half-written intermediate. If the process crashes mid-write, the temp file is left behind and the real file remains intact.

The storage trait is simple enough to have two implementations:

- `InMemorySnapshotStorage` — for tests. Wraps an `Option<AppSnapshot>` in a `Mutex`.
- `JsonFileSnapshotStorage` — for production. The atomic-write implementation above.

The trait-based design means tests never touch the filesystem, and the `CoreRuntime` constructor decides which storage backend to use:

```rust
// core/capacitor-core/src/lib.rs:84-100
impl CoreRuntime {
    fn from_storage(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Result<Arc<Self>, CoreRuntimeError> {
        let state = snapshot_storage
            .load_snapshot()?
            .map(reduce::ReducerState::from_snapshot)
            .unwrap_or_default();
        Ok(Arc::new(Self {
            state: std::sync::Mutex::new(state),
            snapshot_storage,
            app_storage,
        }))
    }
}
```

On startup, `from_snapshot` rehydrates the full reducer state from the persisted snapshot, rebuilding the projects and routing maps. This means restarting `hud-hook serve` is seamless — the new process picks up where the old one left off.

---

## §18. The Operational Surface

Capacitor ships with a rich set of scripts that encode the team's development workflow.

**Daily development** is one command:

```bash
./scripts/dev/restart-alpha-stable.sh
```

This kills any running Capacitor instance, builds the Rust core in release mode, copies the dylib, builds the Swift app, and launches it with `--channel alpha --profile stable`. It's the default command for both humans and coding agents.

**Observability** lives in `./scripts/dev/agent-observe.sh`, a comprehensive diagnostic CLI:

```bash
./scripts/dev/agent-observe.sh diagnose   # Full diagnostic dump
./scripts/dev/agent-observe.sh health     # Runtime service health
./scripts/dev/agent-observe.sh sessions   # Active sessions
./scripts/dev/agent-observe.sh routing-snapshot  # Terminal routing state
```

This script queries the runtime service first (using the bootstrap token for authentication), falling back to the persisted artifact only when the service is unavailable. The fallback mode is treated as degraded, not healthy — a distinction that matters when debugging "why isn't the UI updating?"

**CI** (`/.github/workflows/ci.yml`) runs seven jobs: test surface audit, script tests (via bats), Rust formatting/linting/testing, hook smoke tests, session-state reliability gate, Swift tests, and a build smoke test. Rust jobs run on macOS 14; Swift jobs on macOS 15 (for Xcode 26.3 / Swift 6.2).

**Release** is a single script with preflight checks:

```bash
./scripts/release/release.sh patch
```

This bumps the version, builds a signed and notarized app bundle, creates a DMG, and generates the Sparkle appcast for auto-updates. The bundle must include the Rust dylib, the hud-hook binary, Sparkle.framework, and fresh UniFFI bindings — a checklist that's easy to get wrong manually but is automated in the script.

---

## Afterword: The Shape of the System

If you step back, Capacitor has a clean diamond shape:

```
    Shell Hooks (precmd)     Claude Code Hooks
              \                    /
               ↘                ↙
          hud-hook (Rust HTTP server)
                    ↓
         ReducerState (pure state machine)
                    ↓
             AppSnapshot (JSON)
                    ↓
         Swift Projection + Hysteresis
                    ↓
              SwiftUI Views
                    ↓
         Terminal Activation (AppleScript + tmux)
```

Events flow in from two sources (shell CWD tracking and Claude Code hooks), converge in the reducer, get projected through the stabilization pipeline, and flow out through the UI and terminal activation system. Information flows one direction. Each layer has a single owner. The boundary between Rust and Swift is a well-defined HTTP contract.

This is not an accident — it's the sidecar principle (§2) carried to its conclusion. When you're observing a system you don't control, clarity of ownership and direction of data flow aren't luxuries. They're load-bearing.

---

*This guide covers the Capacitor codebase as of March 2026, across 18 sections. For runtime debugging, see `.claude/docs/debugging-guide.md`. For implementation hazards, see `.claude/docs/gotchas.md`. For terminal activation UX, see `.claude/docs/terminal-activation-ux-spec.md`.*
