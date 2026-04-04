# Agent Changelog

> Doc role: `recent-deltas`
> Status: Recent deltas only. This file is not the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md` -> `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md`
> Older history: `docs/archive/architecture-history/agent-changelog-history-through-2026-03-15.md`

Use this file only for recent migration context and retired seams that still matter for current agent work.

## Recent Active Deltas

### 2026-03-29 — ADR-005 Decided + Phase 1 Startup Unblocked

**State detection architecture** (`77ebe7f..279e4bc`): ADR-005 decided the authority-based multi-signal direction: hooks remain the nuanced-state authority, transcripts own existence and recovery, and shell CWD stays routing-only. Phase 1 shipped the first behavior change: hook repair no longer blocks startup, `HookStatus` now distinguishes `NotInstalled`, `PartiallyConfigured`, and `SettingsUnreadable`, and `isFirstRun` now keys off the persisted `~/.capacitor/setup_complete` marker instead of "no hook events seen." Only missing Claude CLI and explicit hook policy blocks still gate setup.

Key files: `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md`, `core/capacitor-core/src/runtime/setup/`, `core/capacitor-core/src/lib.rs`, `core/capacitor-core/src/runtime/storage.rs`, `apps/swift/Sources/Capacitor/App.swift`, `apps/swift/Sources/Capacitor/Models/SetupReadinessCoordinator.swift`, `apps/swift/Sources/Capacitor/Models/SetupStepCatalog.swift`.

### 2026-03-24 — Checkpoint Bridge Shipped + Documentation Sweep

**Checkpoint bridge** (7 commits, `69dee75..3db10d1`): `BridgeInteractiveIO` bridges method-runner sync gates to the run kernel checkpoint system via file-based protocol. The bridge is fail-closed (all errors fall back to interactive prompt); the relay side in `hud-hook` is fail-open (known limitation — errors swallowed after HTTP mutation succeeds). Ship review hardened: path sanitization, poll timeout, decision action validation.

Key files: `checkpoint_bridge.rs`, `checkpoint_bridge_protocol.rs` (capacitor-core), `checkpoint_bridge_relay.rs` (hud-hook), `RunCheckpointReviewWindow.swift`, `AppState.swift` (run checkpoint routing).

**Documentation sweep**: 16 stale/superseded tracked docs retired to `docs/archive/`. 5 new canonical docs created under `docs/orchestrator/` (checkpoint-bridge, review-surfaces, appstate-checkpoint-policy, terminology, idea-to-run-gap). Module doc comments added to 3 Rust files. `ARCHITECTURE.md` and `architecture-primer.md` updated with orchestrator read path.

## Stale Information Retired (2026-03-24)

| Location | Retired To | Why |
|----------|-----------|-----|
| `docs/plans/orchestrator-status.md` | `docs/archive/orchestrator-history/` | Claimed request-changes is terminal (false since multi-round review shipped) |
| `docs/method-runner-spec/step-6-closeout.md` | `docs/archive/method-runner-spec-history/` | Claimed real adapters deferred (false — `--real` flag wired to CLI) |
| 14 additional review/process docs | `docs/archive/` | Superseded by amended-spec.md and execution-packet.md |

## Current Warning Surface

- Swift no longer reconstructs terminal-app ranking from shell state during production activation.
- The authenticated local runtime service is the live runtime boundary; persisted files remain durability and debugging aids.
- iTerm and Terminal.app are first-class drivers, not a generic shared host bucket.
- Transport failure after `capture_complete` preserves artifacts on disk; the `ownedInProgress` retry path recovers from preserved artifacts before attempting a fresh browser capture.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `.pipeline/phases/phase-003-exec/artifacts/implementation-guide-v2.md` | "transport-layer finalization failures must also remove local artifacts" | Transport failure preserves artifacts; recovery finalizes from disk (PR #40 + #41) | 2026-03-23 |

## Recent Active Deltas

### 2026-03-23 — Capture Retry Artifact Recovery (PR #41)

`RunCaptureCoordinator` now recovers from preserved artifacts when retrying an `ownedInProgress` checkpoint. After a transport failure during `capture_complete`, artifacts stay on disk. On the next reconcile tick, `recoverPreservedArtifacts` checks for a complete set (screenshot + all expected mermaids, non-empty regular files) and finalizes directly from disk — the browser is never invoked. If artifacts are missing, incomplete, or corrupt (zero-byte, directory masquerading as file), recovery is skipped and a fresh capture runs instead.

Key files: `RunCaptureCoordinator.swift` (recovery logic), `RunCaptureCoordinatorTests.swift` (17 tests).

### 2026-03-23 — Capture Transport Failure Fix and Flow Hardening (PR #40)

The capture wiring slice shipped `RunCaptureCoordinator` — the orchestrator for the checkpoint capture lifecycle (claim → browser capture → finalize). Three hardening fixes landed alongside: `cleanupAfterFinalizationFailure` no longer deletes artifacts on transport failure, the Rust reducer rejects `capture_complete` with empty artifacts, and `Dictionary(uniquingKeysWith:)` prevents run-sink crashes on normalized path collisions. All `AppStateSessionObservationTests` now cancel runtime automation to fix cross-test interference.

Key files: `RunCaptureCoordinator.swift`, `RuntimeClient.swift` (mutations), `run_reducer.rs` (capture state machine), `serve.rs` (`/runtime/run/mutate` endpoint).

### 2026-03-22 — Run Kernel and Capture Service Types (PRs #38, #39)

The Rust domain layer gained `MediaArtifact`, `MermaidSource`, `CaptureClaim`, `CaptureStatus`, and the capture state machine in `run_reducer.rs` (pending → claimed → in-progress → completed/failed). `WebCaptureService` wraps `agent-browser` for screenshot and mermaid-to-PNG rendering. Method compiler design doc and 3 new method skills validated.

### 2026-03-21 — Checkpoint Media Artifacts and Review Window (#36, #37)

Checkpoints gained `media_artifacts`, `mermaid_sources`, and `capture_url` fields. `CaptureImageView` renders captured PNGs with click-to-zoom and "Copy Source" for mermaid diagrams. `DelegationReviewWindow` added a MEDIA section for artifact display.

### 2026-03-19 — Manage-Codex Relay Scripts (#35)

Added `scripts/relay/update-batch.sh` and `scripts/relay/compose-prompt.sh` for autonomous Codex batch orchestration. Templates for implement, review, ship-review, and converge phases.

### 2026-03-18 — Modular Development Pipeline v1

Three-phase pipeline orchestrator (triage → align → execute) with gates, phase transitions, and artifact management. Lives in `.claude/skills/pipeline/`.

### 2026-03-17 — AX Automation Verification Lane

`scripts/ci/ax-automation-verify.sh` — the canonical AX interface for agents. Seeds runtime project state, captures timestamped artifacts, classifies failures into deterministic reasons. `runtime-reliability.sh ci` includes the AX lane.

### 2026-03-15 — Final Swift Shell-Ranking Seam Removed

`ActivationPolicy` dropped the last production shell-ranking path. If activation has a route, trust the route. If it does not, preserve explicit hints and use the fallback ladder rather than reintroducing `ShellStateStore` heuristics.

### 2026-03-13 — Rust-Swift Boundary Legibility Cleanup

Swift now has one explicit `ActivationPolicy` seam for activation intent, fake runtime-boundary names are gone from `RuntimeClient`, and the Rust `runtime_activation` shadow owner was retired. If you need to explain activation choice, start in `apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift`.

### 2026-03-13 — First-Class Host Adapters Closed Out

`ScriptedTerminalDriver` is gone. iTerm and Terminal.app now own their own launch and focus behavior, and host launch no longer uses `System Events` keystrokes.

### 2026-03 — Dedicated Runtime Service Became The Live Boundary

Live runtime reads moved to authenticated `/runtime/*` endpoints hosted by `hud-hook serve`. Snapshot files under `~/.capacitor/runtime/` became debug and recovery artifacts instead of the live app boundary.

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Delete artifacts on transport failure during `capture_complete` | Preserve artifacts on disk; let `ownedInProgress` recovery finalize from preserved files | 2026-03-23 |
| Skip missing mermaid PNGs during artifact recovery (`continue`) | Require complete artifact set; return `nil` and fall through to fresh capture | 2026-03-23 |
| Use `fileExists` alone to validate preserved artifacts | Use `isNonEmptyFile` (checks `.typeRegular` + size > 0) | 2026-03-23 |
| Use `Dictionary(uniqueKeysWithValues:)` for `runStatesByID` | Use `Dictionary(_:uniquingKeysWith:)` with logging to handle path collisions | 2026-03-23 |
| Send `capture_complete` with empty `completed_media_artifacts` | Rust reducer rejects empty artifacts; at least one screenshot required | 2026-03-23 |
| Reconstruct terminal-app ranking from `ShellStateStore` during activation | Use runtime routes when present and fall back explicitly when they are not | 2026-03-15 |
| Treat `~/.capacitor/runtime/app_snapshot.json` as live runtime truth | Query the authenticated runtime service using `runtime-service.json` | 2026-03 |
| Add terminal-specific focus logic directly in `TerminalLauncher` or views | Put host automation behind `TerminalDriver` implementations | 2026-03 |
| Add or restore a shared generic host-terminal driver | Keep iTerm and Terminal.app as separate concrete drivers with shared pure helpers only | 2026-03-13 |
| Use `System Events` keystrokes to deliver host launch commands | Use iTerm `write text` or Terminal.app `do script ... in front window` | 2026-03-13 |
| Use `tmux list-windows` to infer which shared session owns a project path | Use pane-level data via `tmux list-panes` | 2026-03 |
| Rely on mouse-center visibility alone for project-card AX automation | Prefer the named `Open in Terminal` accessibility action when available | 2026-03 |
