# Capacitor Preview Work Batch Integration Spec Adversarial Review 01

Date: 2026-05-27
Target: `docs/circuit/capacitor-preview-work-batch-integration-spec.md`
Reviewer stance: find scope leaks, misleading user states, missing implementation dependencies, and anything that would make the next slice unsafe to build.

## Result

Pass after remediation.

There are no unresolved medium, high, or critical findings.

## Findings

### Medium, resolved: `Ready to inspect` could have been shown when no preview app was running

The first draft allowed `Ready to inspect` as card copy even when the preview proof existed but the preview app was no longer running. That would make the card sound more certain than the live state supports.

Resolution: the spec now says a closed/stale ready proof should show `Preview available`, and only a matching running app gets `Ready to inspect` (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:204`).

### Medium, resolved: card wiring could have depended on Debug-labeled proof code

The first draft left the proof coordinator location as `Debug/` or "moved if needed." That is too ambiguous for product card wiring and risks a future compile/scope mess.

Resolution: the spec now explicitly requires moving the proof coordinator to `apps/swift/Sources/Capacitor/Models/PreviewWork/MacOSPreviewWorkProof.swift` before Work Batch card code depends on it (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:478`), and records the rollback risk (`docs/circuit/capacitor-preview-work-batch-integration-spec.md:582`).

### Low, accepted: preview cleanup/stop is not specified

The spec covers build, open, activate, retry, and conflict handling, but it does not add a `Stop Preview` action. That is acceptable for this slice because the current fixed bundle ID policy already treats conflicting previews as explicit conflicts, and closing the preview app manually is enough for manual validation.

## Scope Check

- Capacitor-only: pass.
- macOS-only: pass.
- Work Batch card integration: pass.
- Swift-owned orchestration/UI: pass.
- Rust boundary preserved: pass.
- Evidence kept internal: pass.
- No old Circuit runtime: pass.
- No runner, flow engine, task DAG, broad provider model, new terminal/editor, or SaaS framing: pass.

## Remaining Risk

The biggest remaining risk is build latency. The spec mitigates this by writing `preview_building` immediately and making manual verification observe the card transition before the build finishes.
