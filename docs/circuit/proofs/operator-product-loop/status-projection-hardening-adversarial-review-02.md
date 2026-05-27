# Status Projection Hardening Adversarial Review 02

Date: 2026-05-25

## Scope

Reviewed the resumed execution attempt after `execute`, including:

- Focused Swift test rerun for Work Batch routing, Ready projection, checkpoint opening, Ghostty, and activation coordination.
- Full Swift test rerun.
- `restart-alpha-stable` relaunch evidence.
- Live app logs for Ready projection.
- Structural ownership verification.
- Fresh lock-screen screenshot captured during attempted manual verification.

## Findings

1. [High] Live click verification is still blocked
   - Location: `docs/circuit/proofs/operator-product-loop/status-projection-hardening-2026-05-25.md`
   - Evidence: The resumed attempt captured `docs/circuit/proofs/operator-product-loop/status-projection-hardening-live-blocked-2026-05-25T2342.png`, which shows the macOS lock screen. Computer Use still returns `cgWindowNotFound`, and System Events reports `Capacitor Debug` as visible with `0` windows.
   - Why it matters: The goal explicitly requires live manual checks for project-card, Work Batch row, and checkpoint-row behavior. Automated tests and logs prove the intended code paths and projections, but they do not prove the actual user click path on the unlocked desktop.
   - Recommended fix: Unlock the desktop and rerun the live manual checklist from `docs/circuit/terminal-activation-state-machine.md`.
   - Verification: Capture before/after process evidence, app logs, and screenshots showing the target cockpit or checkpoint surface after each click.

## Clean Findings

- No medium-or-above code defects were found in the resumed automated checks.
- Focused Swift coverage passed: 96 tests, 0 failures.
- Full Swift coverage passed: 904 tests, 1 skipped, 0 failures.
- Structural boundary verification passed with exit code `0`.

## Completion Status

This is not a clean completion review because one High finding remains: live manual verification is still blocked by the locked desktop.
