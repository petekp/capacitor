# Handoff — 2026-03-13 Closeout

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Mission

Terminal-routing-foundation is complete. The route-first, pane-aware terminal activation path is closed out with live Ghostty, iTerm, and Terminal.app proof.

## Changed

- Fixed shared-session activation for non-active panes by resolving tmux sessions from pane-level data.
- Hardened project-card AX automation to prefer the named `Open in Terminal` accessibility action.
- Captured the remaining Ghostty and host-driver live QA evidence in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`.
- Marked `slice-007-ghostty-pane-smoke`, `slice-008-host-driver-smoke`, and `slice-009-convergence` as `done`.
- Ran the final convergence gate:
  - `swift test`
  - `cargo test -p capacitor-core`
  - `bash docs/plans/terminal-routing-foundation/SHIP_CHECKLIST.md`

## Now True

- Project-card activation is proven live for:
  - Ghostty same-tab reuse
  - Ghostty cross-tab reuse
  - Ghostty detached-session reuse
  - Ghostty stale-pane fallback
  - iTerm host-driver focus
  - Terminal.app host-driver focus
- The remaining Ghostty card-click failures are fixed.
- The ship gate passes after the final fixes.

## Remains

- None for terminal-routing-foundation closeout.

## Shipping Blockers

- None.

## Next Steps

1. Reference `docs/releases/2026-03-13-terminal-routing-foundation-closeout.md` or `AGENT_CHANGELOG.md` when summarizing this milestone externally or in later sessions.
