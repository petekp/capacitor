# Handoff — 2026-03-13 Implementation Pass

## Mission

Option 2 is implemented and closed out in Swift with first-class iTerm and Terminal.app host adapters.

## Changed

- Added `apps/swift/Sources/Capacitor/Models/TerminalActivationFailure.swift` and moved `TerminalActivationFailureReason` out of the Ghostty-only file.
- Replaced `ScriptedTerminalDriver` with `ITermTerminalDriver` and `TerminalAppTerminalDriver`.
- Made `TerminalDriver.launch(...)` async and changed the activation coordinator plus launcher to use checked host launch results.
- Replaced the remaining brittle host `System Events` launch injection with direct app automation:
  - iTerm `write text`
  - Terminal.app `do script ... in front window`
- Added dedicated regression suites:
  - `apps/swift/Tests/CapacitorTests/ITermTerminalDriverTests.swift`
  - `apps/swift/Tests/CapacitorTests/TerminalAppTerminalDriverTests.swift`
  - `apps/swift/Tests/CapacitorTests/AppStateTerminalActivationTests.swift`
- Updated `.claude/docs/terminal-activation-ux-spec.md` and `docs/ARCHITECTURE.md` to reflect the new ownership shape.
- Refreshed live manual QA in `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` with:
  - iTerm no-client attach-or-create proof
  - iTerm existing-client focus proof
  - Terminal.app no-client attach-or-create proof
  - Terminal.app existing-client focus proof

## Now True

- `ScriptedTerminalDriver` is gone.
- iTerm and Terminal.app each have their own first-class `TerminalDriver`.
- Host launch no longer returns `true` blindly; it now maps open and command-delivery failures into typed reasons.
- Non-Ghostty activation failures no longer fall back to Ghostty copy in AppState.
- The retained host launch path no longer depends on brittle `System Events` keystrokes.
- Targeted and full automated host-driver coverage are green.
- The manual host-adapter ship gate is satisfied.

## Remains

- None inside the terminal-host-adapters migration.

## Shipping Blockers

- None.

## Exact Next Steps

1. If desired, summarize the shipped follow-up using `docs/plans/terminal-host-adapters/HANDOFF.md` plus `docs/manual-qa/terminal-routing-closeout-2026-03-12.md`.
2. If a release note or changelog needs updating, reference the direct host-launch fix and the final live proof set.
