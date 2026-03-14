# Release Note — Terminal Routing Foundation Closeout

Date: 2026-03-13

## Summary

Capacitor now reliably returns project cards to the right tmux session or pane across Ghostty, iTerm, and Terminal.app. This closes the route-first terminal activation migration and its remaining live QA gates.

The same March 13 follow-up also finished the host-terminal cleanup that routing-foundation left behind:

- iTerm and Terminal.app now use first-class host drivers instead of a shared generic host bucket.
- Host launch now uses direct app automation instead of `System Events` keystrokes.
- Live proof now covers both no-client attach-or-create and existing-client focus for iTerm and Terminal.app.

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
- At the time this routing-foundation closeout was written, Ghostty native launch was still deferred.
- Current shipped behavior is the 2026-03-13 follow-up Ghostty native launch migration: launch now uses native `new window` surface creation with `initial input`.
- Current shipped behavior also includes the 2026-03-13 host-adapter follow-up: iTerm launch uses `write text`, Terminal.app launch uses `do script ... in front window`, and the old host `System Events` keystroke path is gone.
- The local runtime service remains the authoritative live runtime boundary. Persisted runtime artifacts are for debugging and recovery, not live reads.

## Evidence

- Manual QA closeout: `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`
- Control-plane status: `docs/plans/terminal-routing-foundation/SLICES.yaml`
- Final ship gate commands:
  - `swift test`
  - `cargo test -p capacitor-core`
  - `bash docs/plans/terminal-routing-foundation/SHIP_CHECKLIST.md`
