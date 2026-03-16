# Translation Guide

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Old → New

| Old pattern | New pattern |
|---|---|
| `target_kind` / `target_value` | `target.kind` / `target.value` |
| pane/session/app encoded in one `value` field | explicit `terminal_app`, `session_name`, `pane_id`, `host_tty` fields |
| shell-state-only session inference | runtime-derived routing plus shell fallback |
| `TMUX_PANE` read then dropped | `TMUX_PANE` captured in `IngestShellSignalCommand` and `ShellSignal` |
| session-only `switch-client` | `switch-client` + `select-window` + `select-pane` for pane targets |
| `TerminalLauncher` choosing app/session from local heuristics only | `RoutingStateStore` supplies the preferred route first |

## Current gotchas

- `CoreRoutingTarget` should be treated as explicit metadata, not as a generic `value` slot.
- A successful session switch with a stale pane id is still considered a successful activation, by design.
- Ghostty routing and launch both depend on Ghostty 1.3+ AppleScript support; if Ghostty automation is unavailable, Capacitor cannot natively switch or create Ghostty surfaces.
- The new bridge is generated; manual edits to `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift` should be treated as disposable.
