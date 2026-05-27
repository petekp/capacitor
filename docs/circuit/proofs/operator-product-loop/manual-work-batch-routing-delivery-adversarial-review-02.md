# Manual Work Batch Routing And Delivery Adversarial Review 02

Date: 2026-05-25

## Scope

Second independent pass over the manual Work Batch routing and delivery goal after the first clean review. This pass focused on:

- Whether the live state on disk matches the claimed final app state.
- Whether completed Work Batches remain honest and reusable rather than silently losing their cockpit bindings.
- Whether related versus unrelated classification evidence is visible enough to defend the observed routing.
- Whether the hook cleanup fix created any new setup risk.
- Whether residual legacy state changes the acceptance result for newly added Tasks.

Primary evidence reviewed:

- `docs/circuit/proofs/operator-product-loop/manual-work-batch-routing-delivery-verification-2026-05-25.md`
- `/Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/state.json`
- `/Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/cockpit-bindings.json`
- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `core/capacitor-core/src/runtime/setup/env.rs`
- `core/capacitor-core/src/runtime/setup/settings.rs`

## Findings

No medium, high, or critical findings.

### Low: Pre-existing legacy open Tasks are not backfilled by this slice

- Evidence: the manual proof notes a pre-existing legacy open Task in the old project task list for `arc-design-studio`; the Work Batch state reviewed for this scenario only contains the routed Work Batch Tasks created or adopted by the new delivery path.
- Why it matters: a user who created Tasks before the Work Batch model may still see older task state that is not explained by the new batch routing ledger.
- Why not medium: this goal is about newly added Tasks routing and delivery. The live Work Batch state proves the new Tasks were classified, delivered, claimed, completed, and shown through visible batches. Backfilling older Tasks is a migration/product cleanup, not a failure of the tested path.
- Future fix: add an explicit legacy Task migration or "not yet batched" affordance before relying on Work Batches as the only Task surface.

### Low: Completed Claude cockpits remain bound after Done

- Evidence: `cockpit-bindings.json` keeps `claude_session_id` values for both completed batches while marking their bindings `done`; `state.json` marks both batches `idle` with zero queued Tasks and Done summaries.
- Why it matters: the user may still see Claude sessions available after the work is done, which could feel like lingering activity unless the UI clearly treats them as reusable cockpits rather than active work.
- Why not medium: this is the intended batch-continuity behavior for follow-up Tasks. The visible state is not pretending the work is still running, and retaining the session ID is what allows related work to wake the right cockpit later.
- Future fix: add a lightweight archive/close affordance for old completed batches once the core delivery loop is stable.

### Low: Hook setup status still overloads missing versus repair-needed events

- Evidence: `settings.rs` now tracks `repair_events`, but still returns them through the existing `missing_events` field in `HookSettingsStatus::PartiallyConfigured`.
- Why it matters: setup UI copy could say an event is missing when the actual issue is stale managed hook cleanup.
- Why not medium: the repair behavior is correct, the stale `hud-hook handle` entries were removed from live settings, and the focused Rust setup tests cover both detection and migration.
- Future fix: split setup health into separate missing and repair-needed fields when the UI needs more precise wording.

## Acceptance Check

The observed live state still supports the product acceptance criteria:

- Related new Task joined `Mobile Prototype Polish`.
- Unrelated new Task created `Verification & Routing Docs`.
- Both Work Batches are visible top-level batch records.
- Both tested Tasks reached Done artifacts.
- Both batches are idle with zero queued Tasks.
- Both cockpit bindings retain their Claude session IDs for future follow-up routing.
- No stale retired Capacitor hook commands remain in `~/.claude/settings.json`.

## Checks Reviewed

Passed:

```bash
CARGO_INCREMENTAL=0 cargo test -p capacitor-core runtime::setup -j1
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|CompletionReport|CheckpointExchange|AutoRouter|DeliveryPolicy|TaskSession|State)Tests|AppStateRuntimeSnapshotEffectTests|GhosttyAutomationClientTests|WorkBatchBindingReconcilerTests|WorkBatchClaudeProcessScannerTests|ProjectCardContextLineResolverTests|GhosttyTerminalDriverTests'
swift test --package-path apps/swift
```

Live spot checks reviewed:

```bash
rg -n "hud-hook.*handle|CAPACITOR_HOOK_MARKER" ~/.claude/settings.json
jq '.batches[] | {id, name, status, task_ids, current_activity_summary}' ~/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/state.json
jq '.bindings[] | {batch_id, batch_name, status, claude_session_id}' ~/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fever%2Farc-design-studio/work-batches/cockpit-bindings.json
```

## Verdict

Second consecutive review is clean for medium-or-above risk. The implementation is solid enough to continue building on.
