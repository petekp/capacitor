# Adversarial Review 01

Reviewed artifact:

- `docs/circuit/storyboard-indexed-product-loop-plan.md`

Review stance:

- Treat the plan as wrong until it proves that it can produce the storyboarded loop without drifting into a platform rewrite or leaving product moments as vague prose.

## Findings

### 1. Medium: Return brief depended on "while you were away" but lacked an early last-seen storage step

Evidence:

- The first draft planned a return brief, but the local last-seen primitive was only described generally and appeared late in the build order.

Why it mattered:

- A return brief without explicit app/project/run last-seen state can only show current status. It cannot reliably answer what changed while the user was away, which is the first storyboard moment.

Resolution:

- Added `OperatorViewStateStore` as an explicit primitive.
- Moved app last-opened support to the first build step.
- Added storage rules, tests, and return-brief data signals.

Verification:

- The plan now names `OperatorViewStateStore`, `OperatorViewStateStoreTests`, app last-opened data, and early build order placement.

### 2. Medium: Ordinary intent could lose success criteria after run start

Evidence:

- The first draft projected idea title/body into intent/success text, but did not state where that steering context survives after launch.

Why it mattered:

- Later checkpoint packets need to recover the original intent. If the run loses success criteria, the evidence packet cannot reliably lead with the operator's goal.

Resolution:

- Added a data contract for preserving intent and success criteria in the run-start payload or a narrow local run-start artifact.
- Clarified that runtime fields should be added only if existing run metadata cannot carry the data.

Verification:

- Scene 3 now requires the resulting run/checkpoint surfaces to recover original intent.

### 3. Medium: The loop could remain a frontier/debug proof instead of becoming product

Evidence:

- The first draft said to move beyond the debug menu but lacked explicit feature-flag graduation criteria.

Why it mattered:

- A loop reachable only through `Circuit > Run Claude Receipt Loop` is still a proof path, not a fully working product loop.

Resolution:

- Added `Launch Mode And Feature Flag Graduation`.
- Added receipt-loop graduation acceptance requiring stable config enablement outside unrelated debug commands.
- Added final acceptance that the ordinary product path must be available outside the debug menu once proof criteria pass.

Verification:

- The build order now includes graduation from frontier/debug proof to stable after proof artifacts pass.

## Result

No high or critical findings remained after the fixes above. A second adversarial review should verify that the patched plan is internally consistent and still respects the stated non-goals.
