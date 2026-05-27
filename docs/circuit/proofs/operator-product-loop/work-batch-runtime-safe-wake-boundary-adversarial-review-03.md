# Work Batch Runtime Safe Wake Boundary Adversarial Review 03

Date: 2026-05-26

## Scope

Second clean review after the live `parable-school` task completed. This pass looked for contradictions between the intended UX and the implemented delivery behavior:

- Related Tasks should join the existing visible Work Batch.
- Capacitor should not spawn unnecessary Ghostty, tmux, or Claude sessions.
- Wakeups should happen only at a defensible input boundary.
- Claim and Done artifacts, not prompt delivery, should determine visible Task progress.
- Completed active cockpits should remain visible as Ready rather than disappearing into Idle.

## Findings

No medium, high, or critical findings.

## Evidence

- The real related Task `01KSK2QPJEJVNWY12ATPPEAQ3X` joined `batch-typeface-unification-from-source-parable-01ksfw1`.
- The activation trace recorded `route="claude_wake" action="wake_existing" outcome="delivered"` for session `23bb3c4f-286f-4957-869b-6d33a6c9fd3f`.
- The Work Batch claim artifact exists at `.capacitor/work-batch-claims/01KSK2QPJEJVNWY12ATPPEAQ3X.json`.
- The Work Batch completion artifact exists at `.capacitor/work-batch-completions/01KSK2QPJEJVNWY12ATPPEAQ3X.json`.
- Canonical Work Batch state shows both Tasks done and the batch `ready`.
- `swift test --package-path apps/swift` passed 928 XCTest cases with 1 expected skip and 19 Swift Testing cases.

## Residual Risk

Low: This proves one real Ghostty/Claude session shape, not every macOS activation shape. The broader terminal activation matrix remains part of the active hardening goal.
