# Agent Changelog

> This file helps coding agents understand project evolution, key decisions, and deprecated patterns. Updated: 2026-03-13

## Current State Summary

Capacitor now uses an app-owned local runtime service (`hud-hook serve`) as the authoritative runtime boundary. Rust (`core/capacitor-core`) owns ingest, reducer, and route derivation; Swift owns presentation and macOS side effects through `RoutingStateStore`, `TerminalActivationCoordinator`, `TmuxRouter`, first-class `TerminalDriver` implementations for Ghostty, iTerm, and Terminal.app, and `GhosttyAutomationClient`. Terminal switching is route-first, pane-aware, and proven live across Ghostty, iTerm, and Terminal.app, and host-terminal launch no longer relies on brittle `System Events` keystrokes.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `docs/manual-qa/ghostty-routing-smoke-2026-03-10.md` | Project-card AX automation was effectively GUI-only in that session | `scripts/ax/ax_runner.swift` now triggers project cards deterministically via the named `Open in Terminal` accessibility action; authoritative closeout proof lives in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` | 2026-03-13 |
| `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` (2026-03-13 convergence subsection) | Host-terminal proof references `[ScriptedTerminalDriver]` log labels | The 2026-03-13 host-adapter follow-up section in the same file is the current authority; host proof now uses `[ITermTerminalDriver]` and `[TerminalAppTerminalDriver]` after the host-adapter split and launch-path fix | 2026-03-13 |

## Timeline

### 2026-03-13 — Rust-Swift Boundary Legibility Cleanup

**What changed:** Swift now has an explicit `ActivationPolicy` seam for activation intent, `TerminalLauncher` consumes one `activationIntentResolver` instead of four separate resolver callbacks, fake runtime-boundary names were removed from `RuntimeClient`, and the temporary `DebugShellStateCard` was deleted. The old Rust `runtime_activation` test-only shadow owner was retired.

**Why:** The architecture review found that the main source of agent confusion was shadow ownership and fake boundaries, not execution correctness. The cleanup aligns the codebase with the real production lookup rule: Rust facts, Swift policy, Swift execution.

**Agent impact:** If you need to answer "why did activation choose this app/session/pane?", start in `apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift`. Do not look for a production Rust activation planner. If you touch `RuntimeClient`, keep Swift-local synthesis labeled as Swift-local.

**Deprecated:** `core/capacitor-core/src/runtime_activation/mod.rs`, `fetchRuntimeConfig()`, `fetchCoreRoutingDiagnostics()`, and `DebugShellStateCard`.

---

### 2026-03-13 — First-Class Host Adapters Closed Out

**What changed:** `ScriptedTerminalDriver` was removed and replaced with `ITermTerminalDriver` and `TerminalAppTerminalDriver`. `TerminalActivationFailureReason` moved into a terminal-neutral home, AppState now uses terminal-aware failure copy, and the host launch path stopped using `System Events` keystrokes. iTerm now injects commands with `write text`; Terminal.app now uses `do script ... in front window`. Live proof now covers no-client attach-or-create plus existing-client focus for both host terminals.

**Why:** The Ghostty cleanup raised the quality bar, but iTerm and Terminal.app were still structurally second-class and still reported blind launch success. Live QA on the first host-adapter pass exposed a real bug where the retained Terminal keystroke path mangled `tmux new-session -A ...` into `tmux newsession A ...`, which forced the final switch to direct app automation.

**Agent impact:** Treat iTerm and Terminal.app as first-class driver owners, not as variants of a shared generic host bucket. If you touch host launch behavior, keep the current open-plus-delay strategy but use direct app automation, not `System Events` keystrokes. If you touch failure UX, use the shared `TerminalActivationFailureReason` model and keep fallback copy terminal-neutral.

**Deprecated:** `ScriptedTerminalDriver`, host launch via `System Events` keystrokes, and assuming a successful host launch because `open -b ...` fired.

---

### 2026-03-13 — Ghostty Native Launch Migration Finished

**What changed:** `GhosttyTerminalDriver.launch(...)` and `TerminalScripts.launchWithCommand(...)` now create native Ghostty windows through `GhosttyAutomationClient` using `new surface configuration`, `initial working directory`, and `initial input`. The legacy Ghostty `open` plus `System Events` keystroke launch path is gone.

**Why:** The 2026-03-13 live matrix superseded the earlier “native launch not viable” conclusion, and the remaining launch gap was small enough to close cleanly in one follow-up slice.

**Agent impact:** If you touch Ghostty launch or resume, keep raw AppleScript in `GhosttyAutomationClient.swift`, use `new window` as the launch primitive, and use `initial input` rather than post-create `input text`.

**Deprecated:** Ghostty-specific `open` launch scripts, Ghostty-specific `System Events` keystroke launch, and treating D5’s launch reversal as current truth.

---

### 2026-03-13 — Ghostty Native Surface Creation Retest

**What changed:** Re-ran a live Ghostty 1.3.0 matrix against the native AppleScript surface-creation API. In both the running-app and cold-start cases, `new window` and the running-app `new tab` path honored `initial working directory`, `initial input`, and `command`, and both `initial input` and `command` successfully launched attached tmux sessions. Post-create `input text` did not produce reliable side effects.

**Why:** The prior Ghostty migration notes concluded that native surface creation was not ready, but the routing migration left launch on the legacy `open` path only because that older live evidence was negative.

**Agent impact:** This retest is the evidence behind the shipped native-launch follow-up. Native Ghostty surface creation is viable for the launch/resume behaviors we need; do not depend on post-create `input text`.

**Deprecated:** Treating the older “native Ghostty surface creation is not ready on 1.3.0” result as current truth.

---

### 2026-03 — Terminal Routing Foundation Closeout

**What changed:** Terminal-routing-foundation is fully closed out. Shared-session project lookup now uses `tmux list-panes` so non-active panes are discoverable, project-card AX clicks use deterministic named actions, and live proof now covers Ghostty same-tab, Ghostty cross-tab, detached-session reuse, stale-pane fallback, plus iTerm and Terminal.app host-driver focus.

**Why:** The remaining closeout blockers were inconsistent project-card activation and incomplete proof for the final ship gate.

**Agent impact:** Route metadata is authoritative when present, but tmux fallback logic must still see all panes in a session. If you touch card-click automation, prefer explicit named AX actions over geometry-only clicks.

**Deprecated:** Parent-directory route hijacks, `tmux list-windows` for session discovery, and visible-center-click-only project-card automation.

---

### 2026-03 — Dedicated Runtime Service Became The Live Boundary

**What changed:** The app now supervises and reads from an authenticated local runtime service hosted by `hud-hook serve`. Runtime reads moved to `/runtime/*` endpoints, and persisted files under `~/.capacitor/runtime/` became debug and recovery artifacts rather than the live app boundary.

**Why:** The migration needed one runtime owner, one source of truth, and deterministic reconnection/adoption behavior.

**Agent impact:** Read `~/.capacitor/runtime/runtime-service.json` for the ephemeral auth token and port before querying live runtime state. Treat persisted snapshot files as evidence, not live truth.

**Deprecated:** Daemon-era IPC assumptions, snapshot-file-first runtime reads, and raw `target_kind` / `target_value` route shapes.

---

### 2026-03 — Activation Boundaries Were Extracted And Legacy Paths Removed

**What changed:** Activation logic was reshaped around `RoutingStateStore`, `TerminalActivationCoordinator`, `TmuxRouter`, `SupportedTerminalApp`, `TerminalDrivers`, and `GhosttyAutomationClient`. `GhosttyAXReader` and other legacy compatibility paths were removed.

**Why:** The project needed one owner per behavior: routing preferences in state, request arbitration in one coordinator, tmux execution in one boundary, and host-terminal automation in drivers.

**Agent impact:** New activation behavior belongs in the coordinator, router, or a driver, not in views or ad hoc `TerminalLauncher` branches.

**Deprecated:** `GhosttyAXReader`, duplicate activation entrypoints, and raw tmux command strings outside `TmuxRouter`.

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Treat `~/.capacitor/runtime/app_snapshot.json` as live runtime truth | Query the authenticated runtime service using `runtime-service.json` | 2026-03 |
| Add terminal-specific focus logic directly in `TerminalLauncher` or views | Put host automation behind `TerminalDriver` implementations | 2026-03 |
| Add or restore a shared generic host-terminal driver | Keep iTerm and Terminal.app as separate concrete drivers with shared pure helpers only | 2026-03-13 |
| Use `System Events` keystrokes to deliver host launch commands | Use iTerm `write text` or Terminal.app `do script ... in front window` | 2026-03-13 |
| Use `tmux list-windows` to infer which shared session owns a project path | Use pane-level data via `tmux list-panes` | 2026-03 |
| Rely on mouse-center visibility alone for project-card AX automation | Prefer the named `Open in Terminal` accessibility action when available | 2026-03 |

## Trajectory

The routing and host-adapter migrations are complete. Near-term work should bias toward release hygiene, changelog or release-note maintenance, and targeted UX polish rather than more terminal-activation architecture churn.
