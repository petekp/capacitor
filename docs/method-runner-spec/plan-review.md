# Plan Review

## Plan Strengths
- The live governing contract is now aligned on the biggest previous blocker. [`artifacts/amended-spec.md:582`](../../../artifacts/amended-spec.md:582) and [`artifacts/amended-spec.md:601`](../../../artifacts/amended-spec.md:601) both treat `rejected` gate outcomes as `blocked`, and the active Slice 9/12 text follows the same rule.
- The slice seams are materially cleaner now. Slice 1 owns normalization and freeze write-side, Slice 2 owns state machines plus locked event schemas plus `DefinitionLoader`, and Slice 3 owns the single-writer persistence boundary with the PID-reuse stale-lock test. That keeps domain contracts ahead of storage and adapter code instead of retrofitting invariants later.
- The v1 pipeline boundary is finally honest. [`artifacts/execution-packet.md:316`](../../../artifacts/execution-packet.md:316) through [`artifacts/execution-packet.md:325`](../../../artifacts/execution-packet.md:325) and the active Slice 6/9/10/12 text all say the same thing: normalize in v1, block clearly at runtime, and keep `pipeline_child_*` events typed but un-emitted until v2.
- The action surface is no longer dispatch-only. Slices 6, 7, and 8 now give dispatch, interactive, and synthesis attempts comparable provenance artifacts, and Slice 10 reconciles orphan windows across all three action families rather than handoff-only recovery.
- Across all 12 slices, I do not see a remaining forward reference that forces a later slice to redefine an earlier contract. The dependency chain now reads like a real use-case stack: definition -> state/events -> persistence -> binding/ingest -> action execution -> gates -> resume -> parallelism -> taxonomy/telemetry.

## Blocking Gaps
- None. I do not see a remaining execution-packet obligation with no owning slice, nor a live contradiction across `amended-spec.md`, `execution-packet.md`, and the active slice text that would force incompatible code.

## Sequence Risks
- The historical appendix in [`artifacts/implementation-plan.md:739`](../../../artifacts/implementation-plan.md:739), [`artifacts/implementation-plan.md:747`](../../../artifacts/implementation-plan.md:747), and [`artifacts/implementation-plan.md:756`](../../../artifacts/implementation-plan.md:756) still contains superseded `pipeline_clean` language from pre-deferral rounds. The active slices are correct, but a skimmer could still absorb the old reattach/poll story from the changelog instead of the current v1 boundary.
- `artifacts/outputs/<name>.json` sits on an architectural seam. Slice 4 presents it as the canonical bound-output artifact writer in [`artifacts/implementation-plan.md:148`](../../../artifacts/implementation-plan.md:148) through [`artifacts/implementation-plan.md:176`](../../../artifacts/implementation-plan.md:176), while Slice 8 says synthesis writes directly into `artifacts/outputs/` in [`artifacts/implementation-plan.md:335`](../../../artifacts/implementation-plan.md:335) through [`artifacts/implementation-plan.md:360`](../../../artifacts/implementation-plan.md:360). That is implementable, but only if one schema/writer path stays canonical and Slice 8 uses it rather than inventing a second output-file contract.
- The test-count headline still drifts from the enumerated table. The per-slice minima listed in [`artifacts/implementation-plan.md:658`](../../../artifacts/implementation-plan.md:658) through [`artifacts/implementation-plan.md:669`](../../../artifacts/implementation-plan.md:669) sum to at least `120+` unit tests and `35` integration tests, while the total row at [`artifacts/implementation-plan.md:670`](../../../artifacts/implementation-plan.md:670) says `123+` / `36+`. That is probably harmless bookkeeping, but it is exactly the kind of drift that later causes review churn.

## Missing Verification
- Add one explicit `C8` namespace test: two different steps can both declare `outputs.doc` without collision, and only `method.outputs[].from` globalizes one of them. The current locator tests exercise resolution mechanics, but they do not directly prove the namespace rule in [`artifacts/execution-packet.md:308`](../../../artifacts/execution-packet.md:308) through [`artifacts/execution-packet.md:314`](../../../artifacts/execution-packet.md:314).
- Add one small synthetic test or annotation for `timed_out`. After deferring `pipeline_clean`, no active v1 gate type actually exercises that outcome, so either prove the `timed_out -> blocked` transition directly in Slice 9/12 or note that it is type-system completeness for now.
- When Slice 8 is implemented, verify that synthesis uses the same output-record schema as Slice 4 and does not become an independent writer of a subtly different `artifacts/outputs/<name>.json` format.

## Approval Conditions
- No reopen is required for readiness.
- Before implementation starts, treat the active slice text and [`artifacts/execution-packet.md:316`](../../../artifacts/execution-packet.md:316) through [`artifacts/execution-packet.md:325`](../../../artifacts/execution-packet.md:325) as canonical, not the older changelog appendix.
- Fold the non-blocking hardening items above into the next doc edit if you want the plan to be maximally self-proving.

## Verdict: READY
