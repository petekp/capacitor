# Resume: Swift activation shell-ranking seam removed

## Mission Status
The Rust/Swift activation-boundary cleanup target for Swift terminal-app ranking is complete. Swift activation now resolves terminal choice from either a runtime route or explicit local fallback; the last production `.shellEvidence` path is gone.

## Last Meaningful Action
- Deleted `ActivationPolicy` shell-based terminal-app ranking and the `shellState` activation input.
- Added verifier coverage that fails if `.shellEvidence` or `preferredTerminalAppFromShellState(...)` returns to production code.
- Reframed `ActivationPolicyTests.swift` so the old client-tty/session/project-path shell-ranking cases now prove route-miss fallback behavior instead.
- Reran the broad Swift/Rust/verifier checks green.
- Followed up on the lingering `hud-hook` readiness flake by moving the integration tests onto a retrying `ServerGuard::spawn_ready(...)` helper; `cargo test -p hud-hook --quiet` now passed repeatedly.

## Current State
- `ActivationPolicy` now exposes only `.runtimeRoute` and `.fallback` terminal-app sources.
- `AppState` still queries Rust on demand via `/runtime/routing/resolve` before activation fallback.
- `TerminalLauncher` still consumes one async `ActivationPolicyIntent` resolver, but no longer passes shell state into activation intent resolution.
- `ShellStateStore` still exists for snapshot/state/setup UX, but it is no longer activation-critical.

## Key Artifacts
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift`
  - runtime-route-or-fallback only; no `.shellEvidence`, no `preferredTerminalAppFromShellState(...)`
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift`
  - activation resolver still prefers cached/on-demand runtime routes before fallback
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
  - activation fallback path now uses the slimmer `ActivationPolicy.resolveIntent(...)` signature
- `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/ActivationPolicyTests.swift`
  - route-miss proofs now assert fallback behavior instead of shell-evidence ranking
- `/Users/petepetrash/Code/capacitor/.verifier/specs/RuntimeBoundaryContracts.py`
  - fails if Swift production activation reintroduces `.shellEvidence` or `preferredTerminalAppFromShellState(...)`

## Verification State
- Passed:
  - `swift test --package-path apps/swift`
  - `cargo test -p capacitor-core --quiet`
  - `cargo test -p hud-hook --test serve_integration -- --test-threads=1`
  - `cargo test -p hud-hook --test session_state_mapping_gate -- --test-threads=1`
  - `cargo test -p hud-hook --quiet`
  - repeated `cargo test -p hud-hook --quiet` loop: 8/8 passed after the retry-helper migration
  - `./scripts/verify/verify.sh --layers 1,2,3 --json`
  - `bash docs/plans/rust-swift-boundary-legibility/SHIP_CHECKLIST.md`
- Known residual warning only:
  - Layer 3 nesting warnings in:
    - `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs`
    - `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_state/snapshot.rs`
- Manual QA note:
  - `/Users/petepetrash/Code/capacitor/docs/manual-qa/activation-boundary-closeout-2026-03-15.md`
  - live runtime summary captured successfully, and later in the same session the AX-visible main window recovered enough to pass `bash scripts/ci/non-demo-ax-smoke.sh`
  - a focused live attached-route proof was earned via `ax.project-card.pete-2025`: the named `Open in Terminal` action fired, `ghostty` became frontmost, and an attached tmux client moved from session `capacitor` to `dev`
  - the AX/window issue still appears intermittent: earlier in the session `scripts/ax/ax_runner.swift` reported `No AX windows were found for com.capacitor.app.debug`, the app still had a real onscreen CG window, and direct AX attribute probes sometimes returned `kAXErrorCannotComplete`
  - a follow-up experiment that explicitly set `NSWindow` accessibility role/subrole/element state did not change the behavior and was reverted

## Established Decisions
- Rust owns runtime facts and route derivation; Swift owns macOS execution and explicit local fallback only.
- Swift should not reconstruct terminal-app ranking from shell state now that Rust can answer on-demand activation routing for ad hoc project paths.
- If a runtime route is missing or incomplete, Swift should preserve route hints when present and otherwise fall back locally without inventing pane or host identity.
- `hud-hook` integration tests should not choose a port in one step and wait on readiness in another; startup now owns retrying candidate ports inside `ServerGuard::spawn_ready(...)` / `spawn_service_bootstrap_ready(...)`.

## Best Next Loop
1. Keep this slice closed unless a new activation-boundary regression appears.
2. If someone needs more manual proof, reuse `/Users/petepetrash/Code/capacitor/docs/manual-qa/activation-boundary-closeout-2026-03-15.md` plus `scripts/ax/ax_runner.swift`; the highest-value remaining checks are a visible detached `terminal_app` project card and a no-client fallback-ladder scenario.
3. If `hud-hook` startup flakes return, inspect `/Users/petepetrash/Code/capacitor/core/hud-hook/tests/common/mod.rs` before touching runtime-route behavior.

## Notes For The Next Agent
- Start with `git worktree list` in fresh sessions.
- Do not revert unrelated dirty files; this repo is still carrying many parallel edits.
- Treat any new Swift activation heuristic proposal as suspect unless it is purely a fallback UX decision and not routing semantics.
