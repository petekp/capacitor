# Agent Changelog

> Doc role: `recent-deltas`
> Status: Recent deltas only. This file is not the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
> Older history: `docs/archive/architecture-history/agent-changelog-history-through-2026-03-15.md`

Use this file only for recent migration context and retired seams that still matter for current agent work.

## Current Warning Surface

- Swift no longer reconstructs terminal-app ranking from shell state during production activation.
- The authenticated local runtime service is the live runtime boundary; persisted files remain durability and debugging aids.
- iTerm and Terminal.app are first-class drivers, not a generic shared host bucket.

## Recent Active Deltas

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
| Reconstruct terminal-app ranking from `ShellStateStore` during activation | Use runtime routes when present and fall back explicitly when they are not | 2026-03-15 |
| Treat `~/.capacitor/runtime/app_snapshot.json` as live runtime truth | Query the authenticated runtime service using `runtime-service.json` | 2026-03 |
| Add terminal-specific focus logic directly in `TerminalLauncher` or views | Put host automation behind `TerminalDriver` implementations | 2026-03 |
| Add or restore a shared generic host-terminal driver | Keep iTerm and Terminal.app as separate concrete drivers with shared pure helpers only | 2026-03-13 |
| Use `System Events` keystrokes to deliver host launch commands | Use iTerm `write text` or Terminal.app `do script ... in front window` | 2026-03-13 |
| Use `tmux list-windows` to infer which shared session owns a project path | Use pane-level data via `tmux list-panes` | 2026-03 |
| Rely on mouse-center visibility alone for project-card AX automation | Prefer the named `Open in Terminal` accessibility action when available | 2026-03 |
