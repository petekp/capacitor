# Agent Changelog

> This file helps coding agents understand project evolution, key decisions, and deprecated patterns. Updated: 2026-03-13

## Current State Summary

Capacitor now uses an app-owned local runtime service (`hud-hook serve`) as the authoritative runtime boundary. Rust (`core/capacitor-core`) owns ingest, reducer, and route derivation; Swift owns presentation and macOS side effects through `RoutingStateStore`, `TerminalActivationCoordinator`, `TmuxRouter`, `TerminalDriver` implementations, and `GhosttyAutomationClient`. Terminal switching is route-first, pane-aware, and proven live across Ghostty, iTerm, and Terminal.app.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `docs/manual-qa/ghostty-routing-smoke-2026-03-10.md` | Project-card AX automation was effectively GUI-only in that session | `scripts/ax/ax_runner.swift` now triggers project cards deterministically via the named `Open in Terminal` accessibility action; authoritative closeout proof lives in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` | 2026-03-13 |

## Timeline

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
| Use `tmux list-windows` to infer which shared session owns a project path | Use pane-level data via `tmux list-panes` | 2026-03 |
| Rely on mouse-center visibility alone for project-card AX automation | Prefer the named `Open in Terminal` accessibility action when available | 2026-03 |

## Trajectory

The routing migration is complete. Near-term work should bias toward polish, release readiness, and documentation cleanup rather than more activation architecture churn.
