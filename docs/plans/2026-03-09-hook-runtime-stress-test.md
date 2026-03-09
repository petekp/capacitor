# Hook Runtime Design Stress Test

Status: Pass 2 hardening of the pre-migration design package  
Date: 2026-03-09

Related plan: [Hook Runtime Pre-Migration Design Package](/Users/petepetrash/Code/capacitor/docs/plans/2026-03-09-hook-runtime-pre-migration-design-package.md)

## Plan Summary

- Introduce a dedicated local runtime service as the application boundary.
- Persist a canonical observation journal with deterministic read models.
- Use a capability-matrix-driven mixed transport model.
- Keep adapters thin and move all lifecycle and attribution semantics into Rust-owned projectors.

## Must-Be-True Assumptions

| Assumption | How to Verify | Fastest Disproof |
|------------|---------------|------------------|
| A long-lived runtime service is operationally acceptable on macOS for this app | Build helper skeleton, validate launch/reconnect/restart behavior | Runtime helper is too brittle under launchd/login-item constraints |
| Reopening the process-boundary question is worth the decision churn it introduces | Compare helper-service benefits against an in-process host using the same domain design | The same architecture works well enough in-process that the helper split adds more complexity than value |
| SQLite is a better canonical store than a mutable JSON snapshot for this workload | Implement journal + replay prototype and compare failure handling | Shadow prototype shows unacceptable complexity or latency |
| Claude's current mixed transport contract will remain stable enough to encode explicitly | Check docs changes over time and add contract tests | Docs change frequently enough that static transport mapping becomes a constant maintenance burden |
| Command hooks can be reduced to forwarding-only adapters | Prototype stdin -> runtime submitter for command-only events | Claude exit-code/decision-control semantics force meaningful business logic into command adapters |
| Runtime continuity independent of UI materially improves product correctness | Simulate UI restart while Claude continues working | No meaningful product benefit over co-hosting runtime in the app |
| Observation replay can become the acceptance oracle for this subsystem | Build replay corpus and compare old/new states deterministically | Some critical behavior cannot be reproduced or explained from persisted observations |

## Pre-Mortem: It's 1 Year Later, This Failed

| Failure Mode | Warning Signal | Prevention |
|--------------|----------------|------------|
| We built a cleaner architecture that lost important Claude signals | Product states feel "mostly right" but occasionally wrong in hard-to-debug ways | Lock the capability matrix first and refuse to simplify by dropping critical signals silently |
| The runtime service became another daemon-era complexity trap | Frequent helper crashes, reconnect edge cases, hard-to-diagnose lifecycle bugs | Keep service responsibilities narrow and avoid putting transport-specific policy into the service shell |
| We replaced a simple snapshot with a complex journal that the team avoids understanding | Replay tooling exists but no one uses it; health still depends on heuristics | Make replay/diff the default verification path from the first migration slice |
| Command forwarding wasn't actually thin because Claude command semantics leaked inward | Adapter layer accumulates special-case exit-code logic and event-specific branches | Define a strict adapter boundary and prove command-only events can still be represented as observations |
| Migration took too long and left us with parallel systems | Shadow mode drifts for weeks, deletion targets stay alive, confidence degrades | Slice aggressively, enforce deletion targets, add explicit kill criteria for stalled shadow mode |
| Setup/repair stayed heuristic-based | The UI keeps saying "connected" when the actual plan is invalid | Make plan-vs-actual diff the only source of integration health |

## Risk Register

| Risk | Likelihood | Impact | Mitigation | Fallback |
|------|------------|--------|------------|----------|
| Runtime helper adds too much operational complexity | M | H | Prototype helper lifecycle before committing full migration | Co-host runtime in app process temporarily while preserving the same ports and journal model |
| The proposal conflicts with the rewrite's current "no daemon core" decision and creates governance thrash | H | M | Make the process model an explicit early decision gate | Adopt the in-process runtime-host variant first |
| SQLite migration complicates the rewrite more than expected | M | H | Keep derived snapshot export during migration and cut over storage behind ports | Retain snapshot export longer while still moving to observation/projector semantics |
| Claude hook contract changes mid-migration | M | H | Version the capability matrix and test it in CI | Pause slice work, update matrix, regenerate installer/health expectations |
| Command-only events are more important than expected for UX correctness | H | H | Mark product-critical events explicitly before simplifying anything | Keep mixed transport as the durable architecture |
| Shadow comparisons produce noisy, unhelpful diffs | M | M | Define normalized comparison outputs and reason-code-level diffing | Restrict shadow mode to a smaller, better-instrumented state surface first |
| The team over-invests in purity and under-invests in migration safety | M | H | Keep replay, smoke, and deletion rules as hard gates | Freeze architecture changes until proof tooling is in place |

## Kill Criteria

- [ ] Stop if we cannot express the required Claude event set cleanly in a versioned capability matrix.
- [ ] Stop if command-only events force substantial business logic back into adapters.
- [ ] Stop if the runtime helper prototype is materially less reliable than the current app-owned lifecycle.
- [ ] Stop if shadow mode cannot produce decision-useful diffs for core lifecycle and routing state.
- [ ] Stop if the migration requires long-lived parallel policy paths across Rust and Swift.

## Experiments to Run

- [ ] Build a capability-matrix artifact and installer validator. Success metric: install and health paths both derive behavior from the same matrix.
- [ ] Build a tiny command-forwarding prototype for one command-only event. Success metric: adapter stays transport-only and preserves Claude's required decision semantics.
- [ ] Build a SQLite-backed observation journal prototype with one projector. Success metric: replay produces deterministic project/session state.
- [ ] Build a runtime helper lifecycle spike. Success metric: helper survives app restart and reconnects cleanly from the UI.
- [ ] Run shadow comparisons on current replay fixtures. Success metric: old and new state can be compared with low-noise diffs and explicit reason codes.
- [ ] Define and run one end-to-end "critical truth" scenario. Success metric: session lifecycle and routing remain correct through start, tool use, wait, ready, and end transitions.
