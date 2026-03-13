# Release Note — Terminal Routing Foundation Closeout

Date: 2026-03-13

## Summary

Capacitor now reliably returns project cards to the right tmux session or pane across Ghostty, iTerm, and Terminal.app. This closes the route-first terminal activation migration and its remaining live QA gates.

## User-Visible Changes

- Project cards now reuse the correct attached tmux client more consistently instead of raising the wrong terminal surface.
- Shared-session projects now land on the correct pane, even when the target pane is not currently active in that tmux session.
- Ghostty card activation is proven for:
  - same-tab routing
  - cross-tab routing
  - detached-session reuse
  - stale-pane fallback to session-level success
- Host-terminal reuse is now proven for both iTerm and Terminal.app.

## Important Notes

- Ghostty native routing stays in place.
- Ghostty native launch is still deferred; launch remains on the proven `open` path.
- The local runtime service remains the authoritative live runtime boundary. Persisted runtime artifacts are for debugging and recovery, not live reads.

## Evidence

- Manual QA closeout: `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`
- Control-plane status: `docs/plans/terminal-routing-foundation/SLICES.yaml`
- Final ship gate commands:
  - `swift test`
  - `cargo test -p capacitor-core`
  - `bash docs/plans/terminal-routing-foundation/SHIP_CHECKLIST.md`
