# Decisions

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## 2026-03-11 — D1 Rust Owns Routing Derivation

Routing targets are derived inside `core/capacitor-core`, not recomputed in Swift. Swift consumes route state and executes it.

## 2026-03-11 — D2 Shell Signals Preserve `tmux_pane`

`TMUX_PANE` is part of the canonical shell signal contract. Hook adapters may discover it, but they may not discard it before the runtime snapshot.

## 2026-03-11 — D3 Routing Uses Nested `target`

`RoutingView` no longer carries `target_kind` and `target_value` as sibling fields. The route payload is a nested `target` record with `kind` and `value`.

## 2026-03-11 — D4 Pane Routing Includes Cross-Window Sessions

Pane routing is not limited to panes in the currently selected tmux window. The canonical route sequence is:

1. `switch-client`
2. `select-window -t <pane>`
3. `select-pane -t <pane>`

## 2026-03-11 — D5 Pane Failure Downgrades To Session Success

If `switch-client` succeeds but `select-window` or `select-pane` fails, activation succeeds at the session level and records the pane route as stale.

## 2026-03-11 — D6 Route-First Activation Is Introduced Incrementally

The migration is allowed to land the runtime route store and pane-aware activation ahead of the full `TerminalDriver`/`TmuxRouter` extraction, as long as new work continues to move responsibility toward those boundaries and does not create another long-lived path.

## 2026-03-11 — D7 Tmux Commands Live Behind `TmuxRouter`

Raw tmux command strings no longer belong in `TerminalLauncher` or terminal drivers. Session resolution, client resolution, pane selection, attach command building, and attach polling now live behind `TmuxRouter`.

## 2026-03-11 — D8 Terminal Host Behavior Lives Behind Drivers

Ghostty, iTerm, and Terminal.app host focus and launch behavior now live behind `TerminalDriver` implementations. `TerminalLauncher` selects a driver; it does not embed terminal-specific AppleScript or launch flows directly.

## 2026-03-11 — D9 Activation Flow Lives Behind `TerminalActivationCoordinator`

Request arbitration, stale-click suppression, result emission, and the unified activation flow now live behind `TerminalActivationCoordinator`. `TerminalLauncher` is a facade that wires runtime selectors, router, and drivers together.

## 2026-03-11 — D10 Routing Targets Carry Explicit Metadata

`RoutingTarget` no longer overloads a single `value` field. The canonical route payload carries explicit `terminal_app`, `session_name`, `pane_id`, and `host_tty` fields so Swift can execute routes without reconstructing context heuristically.
