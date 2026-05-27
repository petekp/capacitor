# Terminal Session Resolution Hardening - Adversarial Review 02

Date: 2026-05-25

## Scope

Second clean review after resolving Review 01's duplicate-open finding.

Reviewed:

- `TerminalActivationCoordinator.TerminalFocusResult.alreadySelected`
- Ghostty selected-tab/front-window distinction
- Work Batch row no-checkpoint tap path
- checkpoint-row controls
- debug bundle identity
- final automated and live manual evidence

## Findings

No medium, high, or critical findings.

## Evidence

- Direct focus can return `.alreadySelected` only for a front Ghostty CWD match.
- Background selected-tab CWD matches call `focusTerminal`, covered by `testDirectFocusFocusesSelectedCwdMatchInBackgroundWindow`.
- If a tmux client exists, direct `.alreadySelected` does not skip tmux switching, covered by `testActivationFlowStillSwitchesWhenAlreadySelectedDirectMatchHasTmuxClient`.
- No-checkpoint Work Batch rows now have one row-level open path. The summary is not also a button in that state, avoiding duplicate opens.
- Checkpoint rows preserve separate summary/checkpoint/cockpit controls.
- Final live check: Work Batch row changed Ghostty front window from `Mobile Prototype Polish` to `Typeface unification from source parable`, made Ghostty frontmost, and left counts unchanged at 4 Ghostty windows and 12 Claude processes.
- Final focused verification passed with 110 tests and 0 failures.

## Residual Risk

Low: ordinary project-card left-click still deserves a human smoke test because automation exercised the project-card context action more reliably than the raw click gesture. The source path and resolver tests cover the intended behavior, and Work Batch row re-entry now manually verifies cleanly.

## Verdict

Clean.
