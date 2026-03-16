# Agent Changelog History Through 2026-03-15

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

This archive preserves the longer-form changelog material that used to live at the repo root before `AGENT_CHANGELOG.md` was reduced to a recent-deltas surface.

## Previously Tracked Stale-Information Notes

| Location | Historical note | Superseding reality | Since |
|----------|-----------------|---------------------|-------|
| `docs/manual-qa/ghostty-routing-smoke-2026-03-10.md` | Project-card AX automation looked effectively GUI-only in that session | `scripts/ax/ax_runner.swift` now triggers project cards deterministically via the named `Open in Terminal` accessibility action; closeout proof lives in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` | 2026-03-13 |
| `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` (2026-03-13 convergence subsection) | Host-terminal proof referenced `[ScriptedTerminalDriver]` log labels | The later 2026-03-13 host-adapter follow-up in the same file is the newer evidence; host proof now uses `[ITermTerminalDriver]` and `[TerminalAppTerminalDriver]` after the host-adapter split and launch-path fix | 2026-03-13 |

## Longer Timeline Material

### 2026-03-13 — Ghostty Native Launch Migration Finished

`GhosttyTerminalDriver.launch(...)` and `TerminalScripts.launchWithCommand(...)` moved onto `GhosttyAutomationClient` using `new surface configuration`, `initial working directory`, and `initial input`. The legacy Ghostty `open` plus `System Events` keystroke launch path was removed.

### 2026-03-13 — Ghostty Native Surface Creation Retest

A fresh Ghostty 1.3.0 matrix showed that `new window` and the running-app `new tab` path honored `initial working directory`, `initial input`, and `command`, while post-create `input text` remained unreliable. This evidence replaced the earlier negative conclusion and unblocked the shipped native-launch follow-up.

### 2026-03 — Terminal Routing Foundation Closeout

Shared-session project lookup moved to `tmux list-panes`, project-card AX clicks switched to deterministic named actions, and live proof covered Ghostty same-tab, Ghostty cross-tab, detached-session reuse, stale-pane fallback, plus iTerm and Terminal.app host-driver focus.

### 2026-03 — Activation Boundaries Were Extracted And Legacy Paths Removed

Activation logic was reshaped around `RoutingStateStore`, `TerminalActivationCoordinator`, `TmuxRouter`, `SupportedTerminalApp`, `TerminalDrivers`, and `GhosttyAutomationClient`. `GhosttyAXReader` and other legacy compatibility paths were removed so each behavior had one obvious owner.

## Archived Deprecated-Pattern Context

The root `AGENT_CHANGELOG.md` still carries the active deprecated-pattern table. This archive exists only to preserve the longer narrative and superseded evidence trail that no longer belongs in the first-read surface.

