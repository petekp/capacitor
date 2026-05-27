# macOS Preview Work Scenario Ledger Adversarial Review 02

Date: 2026-05-27
Scope: `docs/circuit/preview-work-macos-scenarios.md`
Result: clean; no medium, high, or critical findings.

## Method

- Re-reviewed after Review 01's concurrency wording fix.
- Checked that the ledger covers the requested macOS categories: app identity,
  bundle ids, app names, Launch Services, simultaneous preview builds, Batch
  Worktrees, Xcode/SPM builds, DerivedData, signing, sandboxing, permissions,
  UserDefaults/state isolation, helper processes, menu bar/background apps,
  stale processes, crash/log capture, installed-vs-built ambiguity, and
  wrong-build risks.
- Checked for product drift: Preview Work remains Work Batch-scoped, evidence
  remains internal, and the plan does not introduce a runner, CI system, task
  DAG, new terminal/editor, or SaaS workflow.
- Re-ran `git diff --check` and the trailing-whitespace scan.

## Findings

No medium, high, or critical findings.

## Low-Risk Follow-Ups

- The implementation should turn the first-slice acceptance criteria into
  focused Swift tests before adding UI.
- A real native spike should decide whether Capacitor Preview uses a stable
  preview bundle id only, or supports per-batch ids later.
- The preview session persistence owner should be decided before cross-process
  restart recovery is implemented.

## Conclusion

The macOS scenario ledger is solid enough to drive the next implementation
slice. Its most important guardrail is simple: refuse to say `Ready to inspect`
unless the exact batch-built app identity is proven.
