# Handoff — 2026-03-13

## Changed

- Added a failing regression around `GhosttyTerminalDriver.launch(...)`, then migrated Ghostty launch/resume to native Ghostty `new window` surface creation.
- Extended `GhosttyAutomationClient.swift` with a native `createWindow` capability and shared script helpers so raw Ghostty AppleScript still lives in one adapter boundary.
- Standardized Ghostty launch on `initial input` plus `initial working directory`, and updated the migration docs, audit, translation guide, and changelog to supersede the old launch-reversal conclusion.
- Restored zero-budget guard coverage for Ghostty's legacy open-based and `System Events`-based launch path.

## Now True

- Ghostty routing and launch are both native AppleScript on Ghostty 1.3+.
- The shipped Ghostty launch primitive is `new window`, not `open`, and the shipped launch semantic is `initial input`, not `command`.
- Post-create `input text` remains explicitly rejected for launch/resume work.

## Remains

- None in the Ghostty launch slice itself.

## Shipping Blockers

- None.

## Next Steps

1. Review the diff for commit readiness and make sure the unrelated dirty-tree files still look intentional.
2. If you want an extra release-level sweep, rerun `cargo test -p capacitor-core` and the broader ship checklist even though this slice only changed Swift/docs.
3. Commit the Ghostty native-launch closeout once the repo state looks good.
