# Manual QA Report — Ghostty AX Tab Routing

- Date (UTC): 2026-02-23
- Scope: Ghostty tab-first AX routing (`tab_press -> window_raise -> app fallback`)
- Canonical protocol: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`
- Canonical UX contract: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`

## Why This Report Exists

This report tracks manual verification for the Ghostty routing change from window-title matching to deterministic tab-level AX targeting.

## Required Focus Areas

1. Ghostty multi-tab scenario routes via `activateGhosttyWithAXRouting route=tab_press` when a deterministic tab match exists.
2. If tab press fails, route degrades to `route=window_raise`.
3. If neither tab press nor window raise can be applied, route degrades to `route=app_activate_fallback`.
4. No uncontrolled `launchNewTerminal` fan-out in reuse-eligible scenarios.

## Preflight

Run the canonical host-hygiene and daemon checks from `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`.

## Scenario Matrix (Ghostty-specific)

| ID | Scenario | Expected Route | Result | Notes |
|---|---|---|---|---|
| GT-1 | Matching project tab in active Ghostty window | `tab_press` | PASS | Post-TCC refresh + matcher update: marker `ghostty-ax-tmux-title-match` shows `matchedTabTitle=assistant-ui:1:zsh - ...` and `route=tab_press` at `2026-02-23T18:39:40Z`. |
| GT-2 | Matching project tab in background Ghostty window | `tab_press` + foreground focus | TODO | Not executed after GT-1 block because AX route was unavailable at process level. |
| GT-3 | Tab press blocked/fails | `window_raise` | TODO | |
| GT-4 | No deterministic tab/window route | `app_activate_fallback` | TODO | |
| GT-5 | AX unavailable | `app_activate_fallback` | PASS | Reproduced repeatedly for `assistant-ui`; logs consistently show `activateGhosttyWithAXRouting ax unavailable tty=<none> path=/Users/petepetrash/Code/aui/assistant-ui`. |
| GT-6 | No-client attached tmux + Ghostty running | Reuse path, no launch fan-out | PARTIAL | `tool-ui` click under marker `ghostty-tab-focus-repro-tool-ui` followed ensure/reuse path (`ensureTmuxSession` + `activateFirstRunningTerminal`), with no launch fan-out in this change. |

## Required Log Markers

Use:

```bash
rg -n "activateGhosttyWithAXRouting|route=tab_press|route=window_raise|route=app_activate_fallback|launchNewTerminal" ~/.capacitor/daemon/app-debug.log
```

Expected:

- At least one `route=tab_press` in matching-tab scenarios.
- `route=window_raise` only when tab press cannot succeed.
- `route=app_activate_fallback` only when deterministic routing is unavailable.
- No repeated `launchNewTerminal` in GT-1..GT-3/GT-6.

Observed in this run:

- Marker `ghostty-tab-focus-repro` (`~/.capacitor/daemon/app-debug.log:102310-102372`) shows Ghostty activation for `assistant-ui` but AX route unavailable (`...ax unavailable...`), so no tab-press/window-raise route markers emitted.
- Marker `ghostty-tab-focus-repro-tool-ui` (`~/.capacitor/daemon/app-debug.log:102712-102777`) shows no fan-out; path used ensure/reuse flow.
- Direct AX control sanity check outside Capacitor process confirmed Ghostty tabs are discoverable and pressable on this host (tab state toggled via `AXPress` using a standalone Swift script).
- Marker `ghostty-ax-tmux-title-match` (`~/.capacitor/daemon/app-debug.log`, start/end markers at `2026-02-23T18:39:37Z/18:39:42Z`) confirms deterministic tab selection from tmux-style tab title and `route=tab_press`.
- Marker `ghostty-tab-press-order-fix` (`~/.capacitor/daemon/app-debug.log`, start/end markers at `2026-02-23T18:44:10Z/18:44:14Z`) validates the regression fix where non-tmux tab was preselected: routing resolved `route=tab_press`, and post-click AX state confirmed `assistant-ui` tab selected.

## Automated Evidence Captured During This Change

- `swift test --filter GhosttyAXReaderTests`
- `swift test --filter ActivationActionExecutorTests`
- `swift test --filter TerminalLauncherTests`

Notes:

- Core new tests for tab routing and fallback ordering are present in:
  - `apps/swift/Tests/CapacitorTests/GhosttyAXReaderTests.swift`
  - `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
  - `apps/swift/Tests/CapacitorTests/ActivationActionExecutorTests.swift`

## Sign-off

- Tester: Codex (instrumented AX + log-driven run)
- Build/Commit: `b41501a` (debug app)
- Result: PASS for GT-1 after Accessibility regrant + tmux-title matching update
- Follow-ups:
  - Verify/re-grant macOS Accessibility permission for `com.capacitor.app.debug` / `CapacitorDebug.app` and rerun GT-1..GT-4.
  - Add explicit AX availability diagnostics to app logs (include accessibility trust state and AX API error code) so this failure mode is immediately obvious in future runs.
  - Add deeper automated coverage for Ghostty AX side effects where feasible (current unit suite cannot directly model Ghostty's `AXPress` + `AXRaise` ordering behavior).
