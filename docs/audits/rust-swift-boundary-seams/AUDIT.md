# Rust-Swift Boundary Seam Audit

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

Date: 2026-03-13

## Scope Brief

- System under review: the redesigned Rust core, `hud-hook` runtime service shell, Swift runtime client/projection layer, and terminal activation path.
- Anchor workflow: click a project card and return to the right tmux/terminal context.
- Goal: map every meaningful seam, decision owner, source of truth, and shadow policy path before prescribing any further architectural changes.
- Out of scope: proposing fixes, migration slices, API redesigns, or cleanup work beyond naming the decisions that must be made later.
- Output mode: artifact audit in `docs/audits/`.

## Method

- Read the declared architecture from `README.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md`, ADR-004, and `AGENT_CHANGELOG.md`.
- Traced the production click path through SwiftUI card taps, `AppState`, `TerminalLauncher`, `TerminalActivationCoordinator`, `TmuxRouter`, and terminal drivers.
- Inspected the Rust runtime contract and reducer path for shell signals, routing targets, and runtime snapshot transport.
- Inspected the debug-only and test-only paths that still describe or exercise activation policy.
- Validated the audit with live runtime artifacts and targeted tests:
  - `cargo test -p capacitor-core test_prefers_most_recent_shell`
  - `swift test --package-path apps/swift --filter RuntimeClientTests/testFetchRuntimeConfigReturnsCoreDefaults`
  - `swift test --package-path apps/swift --filter TerminalLauncherTests/testResolvePreferredTerminalAppPrefersExactProjectPathWhenClientTTYIsUnknown`

## Declared Architecture

| Concern | Declared owner | Evidence | Notes |
|---|---|---|---|
| Runtime ingest, reducer, query truth | Rust | `CLAUDE.md:76-77`, `docs/ARCHITECTURE.md:3-27`, `AGENT_CHANGELOG.md:7` | This is consistently declared. |
| Runtime service boundary | `hud-hook serve` + local authenticated HTTP | `docs/architecture-decisions/004-dedicated-local-runtime-service.md`, `docs/ARCHITECTURE.md:5-17`, `core/hud-hook/src/serve.rs:89-104` | Live runtime reads are HTTP, not snapshot-file-first. |
| Swift runtime projection and stabilization | Swift | `CLAUDE.md:76-77`, `docs/ARCHITECTURE.md:17-27` | `AppState`, `SessionStateManager`, `ShellStateStore`, and `RoutingStateStore` are the named owners. |
| Activation orchestration | Swift | `docs/ARCHITECTURE.md:42-48`, `AGENT_CHANGELOG.md:80-84` | Coordinator, router, and drivers are explicitly named. |
| One production owner per behavior | Intended architecture principle | `docs/ARCHITECTURE.md:3-5`, `AGENT_CHANGELOG.md:82-84` | This audit tests whether the code fully matches that claim. |
| No parallel runtime policy paths across Rust and Swift | Explicit non-goal | `docs/ARCHITECTURE.md:49-52` | This is the main declared contract the audit checks. |

## Coverage Ledger

| Subsystem | Entrypoints | Invariants under audit | Risk | Status |
|---|---|---|---|---|
| Hook ingress and runtime service shell | `core/hud-hook/src/serve.rs`, `core/hud-hook/src/cwd.rs` | Adapters forward signals, do not own runtime semantics | High | Done |
| Rust runtime contract and reducer | `core/capacitor-core/src/domain/types.rs`, `reduce/mod.rs`, `runtime_state/*` | Runtime snapshot should provide the canonical facts Swift needs | High | Done |
| Swift runtime client and projection | `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`, `AppState.swift`, `RoutingStateStore.swift`, `ShellStateStore.swift` | Swift should consume and stabilize runtime data, not silently replace runtime policy | High | Done |
| Activation orchestration | `ProjectsView.swift`, `TerminalLauncher.swift`, `TerminalActivationCoordinator.swift`, `TmuxRouter.swift` | Every click-path decision should have one production owner | High | Done |
| Terminal execution | `TerminalDrivers.swift`, `GhosttyAutomationClient.swift`, `SupportedTerminalApp.swift` | Drivers should own macOS side effects; policy should not hide in fallback order | Medium | Done |
| Diagnostics and shadow paths | `RuntimeClient.swift`, `DebugShellStateCard.swift`, Rust test-only activation module | Diagnostics should reflect the real boundary and not create shadow ownership | High | Done |

## Seam Map

| Lifecycle stage | Seam | Producer -> consumer | Declared owner | Actual production owner | Notes |
|---|---|---|---|---|---|
| Hook input | Shell CWD forwarding | shell hook -> `hud-hook cwd` -> runtime service | `hud-hook` adapter | `core/hud-hook` | `detect_parent_app(...)` and tmux context forwarding happen before Rust reduce. |
| Hook input | Runtime HTTP ingress | `hud-hook serve` `/runtime/ingest/*` -> `capacitor-core` | runtime service shell | `core/hud-hook` transport + `capacitor-core` reducer | Service boundary is explicit and local-only. |
| Runtime state derivation | Shell/session/routing reduction | reducer -> `AppSnapshot.routing` and `AppSnapshot.shells` | Rust | Rust | Core route and shell facts are produced here. |
| Runtime transport | Snapshot read | `/runtime/snapshot` -> `RuntimeClient.requireSnapshot(...)` | runtime service | `core/hud-hook` + Swift runtime client | Runtime reads bypass UniFFI for live state. |
| Swift projection | Snapshot mapping | `SnapshotPayload` -> `RuntimeSnapshot` -> `ShellStateStore` / `RoutingStateStore` / `SessionStateManager` | Swift projection | Swift | Mapping is faithful, but some evidence/confidence is re-derived locally. |
| Activation orchestration | Card tap -> launch request | `ProjectsView` / `DockLayoutView` -> `AppState.launchTerminal(...)` | Swift | Swift | UI click path is entirely Swift-owned. |
| Activation orchestration | Route and shell preference resolution | `AppState` injected closures -> `TerminalLauncher` | Swift | Swift | Runtime facts are consumed here, but host app and session fallback policy are also interpreted here. |
| Activation orchestration | tmux client/session/pane operations | `TerminalActivationCoordinator` -> `TmuxRouter` | Swift | Swift | Raw tmux commands are centralized. |
| Terminal execution | Focus and launch side effects | `TerminalDriverRegistry` -> Ghostty/iTerm/Terminal drivers | Swift | Swift | Driver ownership is clean. |
| Diagnostics | Routing diagnostics and debug shell card | `RuntimeClient.fetchCoreRoutingDiagnostics(...)` -> `DebugShellStateCard` | unclear | Swift debug path | Diagnostics are partly reconstructed in Swift, not emitted by Rust. |

## Ownership Matrix

| Decision class | Declared owner | Actual production owner today | Other participants | Status |
|---|---|---|---|---|
| Runtime truth | Rust | Rust | `hud-hook` forwards input, Swift decodes snapshot | Clean |
| Freshness policy | Swift | Swift, with multiple local constant sources | Docs imply runtime-backed config | Ambiguous |
| Route derivation | Rust | Rust for route payload shape; Swift for missing host-app interpretation | `hud-hook` parent-app detection shapes route completeness | Ambiguous |
| Session discovery | Rust route if present | Swift fallback when route is absent | `TmuxRouter.findSessionForPath(...)` shells out directly | Ambiguous |
| Host-terminal selection | Not explicitly declared | Swift | Rust sometimes provides `terminal_app`, sometimes does not | Ambiguous |
| Fallback terminal choice | Not explicitly declared | Swift hidden in `SupportedTerminalApp.detectAvailable()` | Running/install state from `NSWorkspace` | Ambiguous |
| Diagnostics | Unclear | Split: Rust snapshot + Swift local evidence/confidence synthesis | Debug-only shell card consumes alternate path | Ambiguous |
| User preference | Not defined | No first-class owner | Fallback order currently acts as implicit preference | Missing |
| Failure copy | Swift | Swift | Driver failures mapped in Swift | Clean |

## Source-of-Truth Matrix

| Datum | Producer | Primary consumers | Authoritative owner today | Shadow owners | Live app uses it? | Notes |
|---|---|---|---|---|---|---|
| `project_path` | hook event + shell signal -> Rust reducer | Swift project/session/routing lookups | Rust | none | Yes | Stable contract field. |
| `session_name` on routing targets | Rust reducer | `AppState.preferredRoutingSessionResolver` | Rust when route exists | Swift `findSessionForPath(...)` fallback | Yes | Ownership becomes conditional when route is absent. |
| `pane_id` | Rust reducer from `tmux_pane` | `AppState.preferredTmuxPaneResolver` | Rust | none | Yes | Cleanest route field. |
| `host_tty` | Rust reducer from `tmux_client_tty` | `preferredHostTtyResolver`, Swift diagnostic evidence synthesis | Rust | Swift diagnostic evidence builder | Yes | Good runtime fact, but not enough by itself to identify host terminal app. |
| `terminal_app` on routes | Rust reducer when `routing_parent_app(...)` succeeds | `AppState.preferredTerminalAppResolver` | Split: Rust when present, Swift heuristics when absent | test-only Rust activation policy, Swift shell ranking | Yes | This is the key split-brain field. |
| Shell freshness thresholds | Swift constants in `RuntimeClient` and `ShellStateStore` | Runtime config API, shell-state telemetry/debug, selection heuristics | Swift | docs/runtime-config naming imply runtime ownership | Partly | Config-looking API is synthetic. |
| Fallback terminal choice | none | `SupportedTerminalApp.detectAvailable()` | Swift | enum order itself | Yes | Hidden UX policy. |
| Routing confidence / tmux evidence | Swift `mapCoreRoutingSnapshot(...)` / `tmuxClientEvidence(...)` | debug-only diagnostics consumers | Swift | none | Debug only | Not emitted by Rust runtime snapshot. |

## Rust -> Swift Contract Map

### Live runtime transport contract

- Runtime service endpoints:
  - `GET /health`
  - `GET /runtime/snapshot`
  - `POST /runtime/ingest/hook-event`
  - `POST /runtime/ingest/shell-signal`
  - Evidence: `core/hud-hook/src/serve.rs:89-104`
- Live runtime reads in Swift go through `/runtime/snapshot`, not UniFFI:
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:657-666`
  - `docs/ARCHITECTURE.md:28-41`

### Runtime snapshot fields Swift consumes directly

| Contract area | Rust shape | Swift consumer | Re-derivation in Swift | Status |
|---|---|---|---|---|
| Sessions | `SessionSummary` in `domain/types.rs:43-65` | `RuntimeClient.mapSessions(...)` -> `SessionStateManager` | none | Clean |
| Shells | `ShellSignal` in `domain/types.rs:67-78` | `RuntimeClient.mapShellState(...)` -> `ShellStateStore` | stale counting and later selection heuristics | Mostly clean |
| Routes | `RoutingTarget` and `RoutingView` in `domain/types.rs:91-120` | `RuntimeClient.mapRoutingViews(...)` -> `RoutingStateStore` | local scope resolution, local confidence/evidence in diagnostics | Ambiguous |
| Config-looking runtime values | no service payload; Swift constants in `RuntimeClient.Constants` | `fetchRuntimeConfig()` | entire API is local synthesis | Fake boundary |

### Places Swift adds meaning after decoding

- `RuntimeClient.resolveRoutingView(...)` does workspace-first, path-second resolution locally.
- `RuntimeClient.mapCoreRoutingSnapshot(...)` assigns confidence locally.
- `RuntimeClient.tmuxClientEvidence(...)` synthesizes trust-ranked tmux client evidence locally.
- `AppState.preferredTerminalAppResolver` uses route `terminal_app` if present, otherwise falls back to shell heuristics.
- `TerminalLauncher.resolvePreferredTerminalApp(...)` ranks shell/session/TTY evidence locally.

## Dynamic Path Trace: Project Card Click

### Production path

| Step | Location | Decision | Classification | Production owner |
|---|---|---|---|---|
| 1 | `ProjectsView.swift:290-292`, `DockLayoutView.swift:170-174` | Card tap invokes `appState.launchTerminal(for:)` | macOS side effect entrypoint | Swift UI |
| 2 | `AppState.swift:1251-1254` | Sets manual override and delegates to launcher | override prior fact + orchestration | `AppState` |
| 3 | `TerminalActivationCoordinator.swift:86-108` | Arbitrates stale requests and resolves session name before activation | derive new fact + orchestration | `TerminalActivationCoordinator` |
| 4 | `TerminalLauncher.swift:181-196` | Chooses session name from route, optional fallback resolver, tmux pane scan, or project slug | consume runtime fact + derive new fact + fallback | `TerminalLauncher` |
| 5 | `TerminalActivationCoordinator.swift:48-58` | If no tmux client TTY exists, choose launch path | fallback | `TerminalActivationCoordinator` |
| 6 | `TmuxRouter.swift:48-98` | Resolve client TTY from current client, list-clients, preferred host TTY, or target session | consume runtime fact + derive new fact | `TmuxRouter` |
| 7 | `TmuxRouter.swift:17-45`, `238-257` | Ensure session, switch client, optionally select pane | macOS-external side effect via tmux | `TmuxRouter` |
| 8 | `AppState.swift:215-274` | Decide preferred terminal app, route session, host TTY, and pane preference | consume runtime fact + derive new fact | `AppState` closures |
| 9 | `TerminalLauncher.swift:286-340`, `455-460` | Rank shell/session/TTY evidence and fall back to `detectAvailable()` | derive new fact + fallback | `TerminalLauncher` |
| 10 | `TerminalDrivers.swift:560-597` plus concrete drivers | Focus or launch Ghostty/iTerm/Terminal | macOS side effect | Terminal drivers |

### Live evidence pass

| Scenario | Evidence | What it proves |
|---|---|---|
| Detached direct shell route | `~/.capacitor/runtime/app_snapshot.json:5610-5619` shows `claude-code-setup` as `detached` with `target.kind=terminal_app` and `terminal_app=ghostty` | Rust can fully encode detached direct-shell host-app identity. |
| Attached tmux route without host app | `~/.capacitor/runtime/app_snapshot.json:5158-5165` shows a `capacitor` tmux shell with `parent_app="tmux"` and `tmux_client_tty="/dev/ttys017"`; `~/.capacitor/runtime/app_snapshot.json:5640-5649` shows the attached `capacitor` route with `terminal_app=null` | Rust route derivation preserves tmux identity but not host-terminal identity for this attached case. |
| Fresh direct Ghostty shell for same project | `~/.capacitor/runtime/app_snapshot.json:1928-1935` shows a direct Ghostty `capacitor` shell on `/dev/ttys031` | Swift has fresh shell evidence that can conflict with attached-route or fallback logic. |
| No-client launch path picked Terminal | `~/.capacitor/runtime/app-debug.log:1247-1248`, `2352-2353`, `2462-2463` show `runActivationFlow noClient` followed by `launchTerminalWithTmuxSession app=Terminal session=capacitor` | The user-visible fallback terminal choice is happening in Swift production logic, not as a Rust runtime decision. |

## Production-vs-Shadow Logic Inventory

| Logic surface | Location | Why it looks authoritative | Production status | Classification |
|---|---|---|---|---|
| Rust activation decision engine | `core/capacitor-core/src/runtime_activation/mod.rs` | It defines `ActivationDecision`, `resolve_activation(...)`, and many policy tests | Not compiled into production; `lib.rs:14-15` gates it behind `#[cfg(test)]` | Dead/shadow architecture |
| Swift runtime config API | `RuntimeClient.fetchRuntimeConfig()` | API name implies runtime-backed config | Returns local constants only | Fake boundary |
| Swift routing diagnostics | `RuntimeClient.fetchCoreRoutingDiagnostics()` | API name implies core-emitted diagnostics | Confidence, conflicts, and candidate targets are synthesized locally | Diagnostic shadow path |
| Debug shell state card | `DebugShellStateCard.swift:6-13`, `117-130` | Reads live shell state and routing diagnostics, looks like a boundary inspector | Debug-only and explicitly temporary | Debug-only alternate reasoning surface |
| Fallback terminal choice | `SupportedTerminalApp.detectAvailable()` | Hidden behind one helper used by launch/focus paths | Production fallback | Implicit policy |

## Findings Register

### F1. High — Confirmed — Dead/shadow architecture

- Decision under audit: activation policy ownership
- Declared owner: Rust domain/runtime policy
- Actual production owner: Swift activation path
- Location:
  - `core/capacitor-core/src/lib.rs:1-15`
  - `core/capacitor-core/src/runtime_activation/mod.rs:202-225`
  - `core/capacitor-core/src/runtime_activation/mod.rs:1529-1565`
  - `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:290-292`
  - `apps/swift/Sources/Capacitor/Models/AppState.swift:1251-1254`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:181-196`
- Impacted behavior: an engineer can change or trust Rust activation policy thinking it governs project-card behavior when the live app never executes it.
- Observed evidence:
  - the core crate labels itself the long-term source of truth for domain policy, but `runtime_activation` is only compiled under `#[cfg(test)]`
  - the test-only module still defines a full activation decision model and the test `runtime_activation::tests::test_prefers_most_recent_shell` passes under `cargo test -p capacitor-core test_prefers_most_recent_shell`
  - the production click path is entirely Swift-owned
- Inference: this is not just dormant code; it is an executable policy model that can drift away from the production owner while still looking canonical.
- What I checked:
  - static module inclusion in `lib.rs`
  - Rust unit test execution
  - Swift production entrypoints for card click and activation
- Decision required: should `runtime_activation` become a production-exported owner, remain an explicitly non-authoritative spec artifact, or be retired?

### F2. High — Confirmed — Missing contract

- Decision under audit: host-terminal identity for attached tmux contexts
- Declared owner: Rust route derivation
- Actual production owner: split between Rust route facts and Swift re-inference
- Location:
  - `core/capacitor-core/src/reduce/mod.rs:436-472`
  - `core/capacitor-core/src/reduce/mod.rs:509-517`
  - `core/hud-hook/src/cwd.rs:200-228`
  - `~/.capacitor/runtime/app_snapshot.json:5158-5165`
  - `~/.capacitor/runtime/app_snapshot.json:5640-5649`
  - `apps/swift/Sources/Capacitor/Models/AppState.swift:215-237`
- Impacted behavior: Swift cannot always determine the host terminal app from the route contract alone and therefore must apply local heuristics.
- Observed evidence:
  - attached tmux routes set `terminal_app` from `routing_parent_app(shell.parent_app)` only when the shell signal is not `tmux`
  - `routing_parent_app(...)` explicitly drops `Unknown` and `Tmux`
  - the live `capacitor` route is attached and includes `session_name`, `pane_id`, and `host_tty`, but `terminal_app` is `null`
  - the matching live shell signal has `parent_app="tmux"`
- Inference: Rust derives enough information to route tmux, but not enough to tell Swift which host terminal currently owns the attached client in this case.
- What I checked:
  - hook-side parent-app detection
  - reducer route construction
  - live runtime snapshot for `capacitor`
  - Swift terminal-app resolver
- Decision required: must attached tmux routes carry host-terminal identity as a canonical runtime fact, or is host-terminal selection intentionally a Swift-owned inference?

### F3. High — Confirmed — Duplicate policy

- Decision under audit: terminal app selection after routing
- Declared owner: route-first activation with one owner per behavior
- Actual production owner: Swift, with multiple local policy layers
- Location:
  - `apps/swift/Sources/Capacitor/Models/AppState.swift:215-274`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:286-340`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:455-460`
  - `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift:628-657`
- Impacted behavior: card-click behavior depends on a mix of runtime route facts and local shell heuristics, rather than one explicit production owner.
- Observed evidence:
  - `AppState` first prefers `route.target.terminalApp`, then falls back to local shell ranking
  - `TerminalLauncher.resolvePreferredTerminalApp(...)` locally ranks client TTY, shell TTY, exact project path, and session matches
  - the Swift test `testResolvePreferredTerminalAppPrefersExactProjectPathWhenClientTTYIsUnknown` passes, proving this local ranking is an active production policy surface
- Inference: Swift is not only executing runtime facts; it is deciding which runtime facts matter most when the route contract is incomplete or ambiguous.
- What I checked:
  - production resolver closures
  - local terminal ranking function
  - Swift test coverage for ranking behavior
- Decision required: should terminal-app preference ranking be a first-class client policy, or should the runtime contract eliminate the need for Swift to rank these signals?

### F4. Medium — Confirmed — Fake boundary

- Decision under audit: freshness/config ownership
- Declared owner: unclear in docs; runtime naming implies service-backed config
- Actual production owner: Swift local constants
- Location:
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:231-240`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:473-478`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:630-637`
  - `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift:52-54`
  - `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift:351-359`
- Impacted behavior: engineers can believe runtime freshness thresholds come from the runtime service when they are actually hardcoded in the client.
- Observed evidence:
  - `RuntimeRoutingConfig` exists as a decodable type
  - `fetchRuntimeConfig()` does not hit a config endpoint and simply returns Swift constants
  - `ShellStateStore` also defines its own stale threshold separately
  - the Swift test `testFetchRuntimeConfigReturnsCoreDefaults` proves the API is currently asserting those local constants
- Inference: this API surface looks like a runtime boundary but is actually a client-owned constant bundle.
- What I checked:
  - runtime client implementation
  - runtime service routes
  - shell state store
  - targeted Swift test
- Decision required: is freshness/config supposed to be runtime-owned, client-owned, or intentionally duplicated with documented mirroring?

### F5. Medium — Confirmed — Diagnostic blind spot

- Decision under audit: routing diagnostics ownership
- Declared owner: not clearly declared
- Actual production owner: split between Rust snapshot and Swift local synthesis
- Location:
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:210-229`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:817-930`
  - `apps/swift/Sources/Capacitor/Views/Debug/DebugShellStateCard.swift:6-13`
  - `apps/swift/Sources/Capacitor/Views/Debug/DebugShellStateCard.swift:117-130`
- Impacted behavior: diagnostics can imply a stronger runtime-owned explanation surface than the system actually provides.
- Observed evidence:
  - `CoreRoutingDiagnostics` includes `signalAgesMs`, `candidateTargets`, `conflicts`, and `confidence`
  - `fetchCoreRoutingDiagnostics()` returns empty `signalAgesMs` and `conflicts`, while `mapCoreRoutingSnapshot(...)` and `tmuxClientEvidence(...)` synthesize local confidence and evidence
  - the only live consumer found is the explicitly temporary `DebugShellStateCard`
- Inference: the app has a diagnostic abstraction that sounds core-authored but is currently mostly a Swift interpretation layer for debug use.
- What I checked:
  - runtime client diagnostics implementation
  - debug-only consumer
  - search for production uses
- Decision required: which parts of routing diagnostics are meant to be canonical runtime output versus client-side debugging interpretation?

### F6. Medium — Confirmed — Hidden policy

- Decision under audit: fallback terminal choice
- Declared owner: not explicitly declared
- Actual production owner: `SupportedTerminalApp.detectAvailable()`
- Location:
  - `apps/swift/Sources/Capacitor/Models/SupportedTerminalApp.swift:4-29`
  - `apps/swift/Sources/Capacitor/Models/SupportedTerminalApp.swift:97-109`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:455-460`
  - `~/.capacitor/runtime/app-debug.log:1247-1248`
  - `~/.capacitor/runtime/app-debug.log:2352-2353`
  - `~/.capacitor/runtime/app-debug.log:2462-2463`
- Impacted behavior: when stronger evidence is absent or incomplete, the user-visible terminal choice is governed by enum order and installation/running state, not an explicitly owned product rule.
- Observed evidence:
  - `detectAvailable()` returns the first running app in `SupportedTerminalApp.allCases`, then the first installed app, then `.terminal`
  - `TerminalLauncher.preferredTerminalApp(...)` uses that helper as the final fallback
  - live logs show a no-client `capacitor` click launching `Terminal`
- Inference: fallback terminal choice is a real UX policy surface, but it is currently implicit and unowned.
- What I checked:
  - fallback helper implementation
  - terminal-launch call site
  - live runtime logs
- Decision required: who owns fallback terminal choice, and should it be explicit product policy or user preference?

### F7. Medium — Confirmed — Ambiguous session-discovery ownership

- Decision under audit: session discovery when route metadata is missing
- Declared owner: Rust route derivation
- Actual production owner: Swift fallback
- Location:
  - `docs/ARCHITECTURE.md:42-48`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:181-196`
  - `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift:101-113`
- Impacted behavior: session resolution still depends on client-side tmux discovery when the runtime route does not supply a session.
- Observed evidence:
  - `resolveSessionName(...)` prefers route session, then optional injected fallback, then `findSessionForPath(...)`, then project slug
  - `findSessionForPath(...)` shells out to `tmux list-panes -a`
- Inference: route derivation is not yet the single owner of session discovery; Swift still has a meaningful route-discovery fallback.
- What I checked:
  - production session-resolution path
  - `TmuxRouter` discovery logic
  - declared activation boundaries
- Decision required: is client-side tmux session discovery a permanent part of the design, or a temporary gap-filler when runtime routing is incomplete?

## Ambiguity Map

| Decision | Declared owner | Actual owner | Other participants | Production path | Shadow path | Risk |
|---|---|---|---|---|---|---|
| Activation decision model | Rust domain policy | Swift | none | `ProjectsView -> AppState -> TerminalLauncher -> Coordinator -> TmuxRouter -> Drivers` | Rust `runtime_activation` tests | High |
| Host-terminal identity for attached tmux | Rust route derivation | Split Rust + Swift | `hud-hook` parent-app detection | route `host_tty` plus Swift app ranking | Rust test-only activation expectations | High |
| Terminal app preference ranking | not explicitly declared | Swift | route `terminal_app` when present | `AppState.preferredTerminalAppResolver` + `resolvePreferredTerminalApp(...)` | Rust activation tests encode similar intent | High |
| Freshness/config | Swift per docs, but runtime naming is ambiguous | Swift local constants | debug tools and docs | `RuntimeClient.Constants`, `ShellStateStore.Constants` | `RuntimeRoutingConfig` API surface | Medium |
| Routing diagnostics | unclear | Swift local synthesis | Rust snapshot transport | `fetchCoreRoutingDiagnostics()` debug flow | temporary debug card | Medium |
| Fallback terminal choice | not explicitly declared | Swift hidden helper | `NSWorkspace` app state | `SupportedTerminalApp.detectAvailable()` | none | Medium |
| Session discovery without route | Rust route derivation | Swift | tmux CLI | `resolveSessionName()` -> `findSessionForPath()` | none | Medium |

## Decision Backlog

These are the architecture decisions the audit says must be made before prescribing further changes:

1. Is the Rust `runtime_activation` model intended to be a real production owner, an explicit spec artifact, or dead code?
2. Must attached tmux routes carry canonical host-terminal identity, or is host-app selection intentionally a Swift concern?
3. Is terminal-app ranking after route consumption a legitimate client policy layer, or a temporary overlap caused by an incomplete runtime contract?
4. Is runtime config/freshness supposed to be emitted by the runtime service, or is it intentionally a client-owned policy surface despite the current API naming?
5. Which parts of routing diagnostics should be runtime-authored facts versus client-authored debug interpretation?
6. Who owns fallback terminal choice: runtime policy, Swift product policy, or explicit user preference?
7. Is client-side session discovery by shelling out to tmux part of the target architecture, or only a resilience fallback to be retired later?

## Coverage Gaps

- This audit did not attempt to manually repro every terminal-driver failure mode under denied Automation permissions; it focused on seam ownership rather than platform QA.
- Runtime-service supervision and adoption behavior were only inspected statically; the audit did not simulate bootstrap corruption or reconnect races.
- The FFI boundary was checked only for its architectural role, not for a full exhaustive API-by-API drift review.

## Appendix: Code Evidence Index

### Declared contract

- `CLAUDE.md:71-77`
- `docs/ARCHITECTURE.md:1-52`
- `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
- `AGENT_CHANGELOG.md:5-8`
- `AGENT_CHANGELOG.md:80-84`

### Runtime service boundary

- `core/hud-hook/src/serve.rs:89-104`
- `core/hud-hook/src/cwd.rs:200-228`

### Rust runtime contract

- `core/capacitor-core/src/domain/types.rs:67-120`
- `core/capacitor-core/src/reduce/mod.rs:436-517`
- `core/capacitor-core/src/lib.rs:1-15`
- `core/capacitor-core/src/runtime_activation/mod.rs:202-225`
- `core/capacitor-core/src/runtime_activation/mod.rs:1529-1565`

### Swift runtime consumption and projection

- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:166-240`
- `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift:751-930`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:215-274`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:542-566`
- `apps/swift/Sources/Capacitor/Models/RoutingStateStore.swift:1-57`
- `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift:50-79`

### Activation path

- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:286-292`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:324-329`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1251-1254`
- `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift:39-80`
- `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift:86-123`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:181-196`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:286-340`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:455-460`
- `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift:17-113`
- `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift:238-257`
- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift:560-597`
- `apps/swift/Sources/Capacitor/Models/SupportedTerminalApp.swift:4-29`
- `apps/swift/Sources/Capacitor/Models/SupportedTerminalApp.swift:97-109`

### Debug-only and shadow paths

- `apps/swift/Sources/Capacitor/Views/Debug/DebugShellStateCard.swift:6-13`
- `apps/swift/Sources/Capacitor/Views/Debug/DebugShellStateCard.swift:117-130`
- `apps/swift/Tests/CapacitorTests/RuntimeClientTests.swift:351-359`
- `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift:628-657`

### Live artifact evidence

- `~/.capacitor/runtime/app_snapshot.json:1928-1935`
- `~/.capacitor/runtime/app_snapshot.json:5158-5165`
- `~/.capacitor/runtime/app_snapshot.json:5610-5619`
- `~/.capacitor/runtime/app_snapshot.json:5640-5649`
- `~/.capacitor/runtime/app-debug.log:1247-1248`
- `~/.capacitor/runtime/app-debug.log:2352-2353`
- `~/.capacitor/runtime/app-debug.log:2462-2463`
