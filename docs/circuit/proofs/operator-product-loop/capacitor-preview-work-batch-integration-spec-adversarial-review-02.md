# Capacitor Preview Work Batch Integration Spec Adversarial Review 02

Date: 2026-05-27
Target: `docs/circuit/capacitor-preview-work-batch-integration-spec.md`
Reviewer stance: second clean-room pass after Review 01 remediation.

## Result

Pass.

There are no unresolved medium, high, or critical findings.

## Checks

- Scope remains Capacitor-only and macOS-only (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:22`).
- The non-goals still block generic preview configuration, web preview, per-batch bundle IDs, multiple simultaneous native previews, automatic preview after every Done report, raw evidence UI, new terminal/editor behavior, and old Circuit runtime behavior (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:591`).
- The card states now keep live preview truth separate from stale proof: `Ready to inspect` requires a matching running app, while a closed ready proof falls back to `Preview available` (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:205`).
- Checkpoints remain the primary interruption and preview is explicit/secondary (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:167`, `docs/circuit/capacitor-preview-work-batch-integration-spec.md:513`).
- The implementation plan preserves Swift ownership of macOS orchestration and avoids Rust/UniFFI work (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:223`, `docs/circuit/capacitor-preview-work-batch-integration-spec.md:442`).
- Product card wiring no longer depends on leaving proof code under `Debug/` (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:478`).
- Proof/log storage is specified under `~/.capacitor`, not repo docs (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:275`, `docs/circuit/capacitor-preview-work-batch-integration-spec.md:566`).

## Findings

No medium, high, or critical findings.

Low accepted risk: The slice still does not include a `Stop Preview` card action. That is acceptable because the fixed bundle ID policy intentionally allows one active preview identity and treats conflicts explicitly.
