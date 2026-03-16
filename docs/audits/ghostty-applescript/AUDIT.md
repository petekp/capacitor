# Ghostty AppleScript Migration Audit

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Method

- Inspected the Swift activation flow, Ghostty routing helpers, tests, and user-facing docs.
- Measured the Ghostty-specific debt with `rg` before the migration.
- Re-ran the same patterns after the migration and ratcheted Ghostty AX debt to zero.
- Re-opened the launch slice after fresh live Ghostty 1.3.0 surface-creation smoke tests proved native launch viable for the tmux attach/resume cases Capacitor ships.
- Performed live Ghostty 1.3.0 smoke tests for native terminal focus and confirmed `focus terminal id ...` reliably reselects an existing routed tab.
- Replaced the remaining legacy Ghostty launch path with native `new window` creation using `initial working directory` plus `initial input`.

## Initial Metrics

| Pattern | Count | Why It Was Debt |
|---|---:|---|
| `GhosttyAXReader.swift` file presence | 1 | Entire Ghostty path depended on AX APIs and AX-only tab models |
| `open -a Ghostty.app` | 4 | Launch path used the legacy open-based Ghostty launch mechanism |
| `tell process "Ghostty"` | 1 | Running-Ghostty launch typed commands with `System Events` |
| `AXUIElement|kAX|AXPress|AXRaise|Accessibility` in Ghostty code/docs scope | 41 | Ghostty routing and docs encoded AX assumptions that the new API replaces |

## Final Metrics

| Pattern | Count |
|---|---:|
| `GhosttyAXReader.swift` file presence | 0 |
| `open -a Ghostty.app` | 0 |
| `tell process "Ghostty"` | 0 |
| `AXUIElement|kAX|AXPress|AXRaise|Accessibility tab targeting` in Ghostty code/docs scope | 0 |

## Leverage Assessment

- High leverage:
  - `TerminalDrivers.swift`
  - `TerminalLauncher.swift`
  - new `GhosttyAutomationClient.swift`
  - `TerminalLauncherTests.swift`
- Medium leverage:
  - `ProjectCreationCoordinator.swift` through `TerminalScripts.launchWithCommand`
  - activation docs and QA checklists
- Low leverage / replace:
  - `GhosttyAXReader.swift`
  - `GhosttyAXReaderTests.swift`
  - Ghostty-specific `open -a` and `System Events` keystroke scripts

## Hard Conclusions

- Ghostty’s native AppleScript model is good enough to replace Ghostty-specific AX routing entirely.
- Ghostty’s native surface-construction API is good enough on local Ghostty 1.3.0 to replace the remaining launch path for the tested tmux attach/resume behaviors.
- `initial input` is the right launch semantic for Capacitor because it preserves the existing shell-first resume behavior without extra keep-alive handling.
- Working directory is a strong routing signal, but not sufficient by itself; the terminal ID cache and title/session fallbacks remain necessary.
- The raw AppleScript surface must stay behind one adapter because the upstream API is preview in Ghostty 1.3.
- The migration only counts as complete if the old Ghostty AX code, tests, docs, and legacy Ghostty launch scripts are deleted or ratcheted away in the same session.
