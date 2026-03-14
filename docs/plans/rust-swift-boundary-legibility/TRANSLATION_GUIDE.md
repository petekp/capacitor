# Translation Guide

Use this file during the implementation slices to keep the Option 2 target shape honest.

## Current Status

- `ActivationPolicy` now exists as the slice-001 policy seam.
- It is intentionally still narrow: pure facts in, intent out.
- `TerminalLauncher` now consumes one `ActivationPolicyIntent` resolver instead of four separate policy callbacks.
- The launcher no longer owns implicit fallback choice; `ActivationPolicyFallback` is the default owner of the fallback ladder.
- Slice-003 is complete: the fake runtime-boundary names are gone from app/test code, and the temporary debug card was deleted.
- Slice-004 is complete: the Rust shadow owner is gone, and the core crate no longer advertises a production activation planner.
- The remaining cleanup work is now convergence: full automated gates, residue sweep, and any manual verification still needed before ship.

## Old Surface -> New Owner

| Current surface | Why it is confusing today | Option 2 target |
|---|---|---|
| `core/capacitor-core/src/runtime_activation/mod.rs` | Looks like the production activation owner but only compiles in tests | Delete it or port any valuable cases into explicitly non-authoritative regression tests |
| `AppState` resolver closures -> `TerminalLauncher` | Real policy is split across injected callbacks and launcher helpers | One Swift `ActivationPolicy` owner consumes runtime facts plus local desktop state |
| `TerminalLauncher.resolvePreferredTerminalApp(...)` | Launcher ranks shell and session evidence directly | `ActivationPolicy` chooses the terminal app and explains why |
| `SupportedTerminalApp.detectAvailable()` from `TerminalLauncher` | Fallback policy is hidden in a helper call | `ActivationPolicy` owns an explicit fallback ladder and tests it |
| `RuntimeClient.fetchRuntimeConfig()` | Name implies runtime-backed config | Rename or relocate to an explicitly Swift-local freshness-policy surface |
| `RuntimeClient.fetchCoreRoutingDiagnostics()` | Name implies Rust-emitted diagnostics | Rename or relocate to explicitly Swift-local activation diagnostics |
| `DebugShellStateCard` | Temporary debug UI looks like a canonical boundary inspector | Remove it or replace it with a clearly local debug surface that points at the policy owner |

## Lookup Rule After The Migration

When the migration is done, the answer to "where does this decision live?" should be:

- Runtime facts, route payloads, and shell/session truth: Rust
- Activation intent, freshness interpretation, fallback choice, and diagnostics interpretation: Swift `ActivationPolicy`
- tmux command execution and terminal focus/launch side effects: Swift coordinator, router, and drivers

## Edge Cases And Gotchas

- Attached tmux routes with `terminal_app = nil` are allowed in Option 2. That is an incomplete runtime fact, not a broken runtime contract by itself.
- When a runtime route already provides `session_name` or `pane_id`, the policy owner should consume those facts, not silently re-derive them.
- If a local heuristic is required, do not expose it through a `core` or `runtime` API name.
- Rename tests in the same slice as the code move. Leaving old names around is how fake boundaries survive.
- The fallback terminal ladder is user-visible behavior. Keep it explicit and locked by tests.
- If the policy owner starts pulling in tmux command execution, AppleScript, or driver state changes, it is getting too wide. Stop and narrow it before continuing.

## Before / After Shape

### Before

`AppState -> injected resolver closures -> TerminalLauncher helper ranking -> SupportedTerminalApp.detectAvailable() -> coordinator/router/drivers`

### After

`AppState -> ActivationPolicy.resolveIntent(runtimeFacts, localDesktopState) -> TerminalLauncher executes intent -> coordinator/router/drivers`

## Suggested Test Cases

- Route has `terminal_app`, `session_name`, and `pane_id`: policy should return that intent without local re-ranking.
- Route has `session_name` and `pane_id` but `terminal_app = nil`: policy should choose host terminal from local shell/app state and record why.
- No route exists but fresh shell evidence matches the project: policy should choose the freshest supported host deterministically.
- No stronger signal exists: policy should use the explicit fallback ladder and the test should name that ladder.
