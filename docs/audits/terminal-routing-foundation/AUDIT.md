# Terminal Routing Foundation Audit

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Method

- Inspected the current Rust runtime contract, reducer, `hud-hook` shell adapter, UniFFI bridge, Swift runtime snapshot client, AppState snapshot application, and terminal activation codepaths.
- Measured migration anti-patterns with regex-based ratchet counts and encoded the budgets in `docs/plans/terminal-routing-foundation/guard.sh`.
- Verified the new Rust pane-routing slice with targeted cargo tests.
- Verified the new Swift pane-routing and routing-state slices with targeted Swift tests.

## Current Metrics

| Pattern | Count | Why It Is Debt |
|---|---:|---|
| direct tmux command literals outside a dedicated router | 0 | tmux execution is now isolated behind `TmuxRouter` |
| terminal-specific `case` branches inside `TerminalLauncher` | 0 | terminal taxonomy no longer lives inside the launcher |
| raw `target_kind` / `target_value` route handling | 0 | migration has already ratcheted this to zero |
| host-focus AppleScript outside driver types | 0 | terminal focus behavior now lives in driver implementations |
| duplicate activation entrypoints/helpers | 0 | the old duplicated helper names are gone; activation flow now sits behind one coordinator |

## Leverage Assessment

- High leverage:
  - `core/capacitor-core/src/domain/types.rs`
  - `core/capacitor-core/src/reduce/mod.rs`
  - `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
  - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
  - `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
- Medium leverage:
  - `apps/swift/Sources/Capacitor/Models/AppState.swift`
  - `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
  - `docs/ARCHITECTURE.md`
- Low leverage / replace:
  - raw route-shape handling in Swift fixtures and decoders
  - session-only pane-blind tmux switching

## Hard Conclusions

- `tmux_pane` was the missing canonical routing fact; preserving it immediately unlocks pane-aware activation.
- Rust route derivation is the right long-term owner for pane-vs-session decisions.
- Swift must consume routing as part of the main runtime snapshot flow, not via a second diagnostic fetch path only.
- The bridge must be regenerated whenever the Rust route shape changes; manual bridge drift is too error-prone for this migration.
- The biggest remaining debt is now polish debt, not architecture debt: explicit route metadata exists, the coordinator/router/driver split exists, and the next work is mainly normalization and cleanup.
