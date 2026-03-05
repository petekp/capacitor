# Simplicity Audit: Capacitor (Runtime-Snapshot Era)

## Executive Summary
Capacitor's core mission is simple: show project/session state and jump to the right terminal context. The codebase can deliver that with substantially less complexity than it currently carries. The main simplification opportunity is not in ripping out runtime correctness logic, but in shrinking optional feature surface and deleting unexercised architecture layers that do not currently power user-facing behavior.

## Functionality Inventory
| Feature Area | Behaviors | LOC (approx) | Files (approx) | Abstractions / Concepts |
|---|---:|---:|---:|---|
| Runtime ingest + session projection | Ingest hooks/shell signals, reduce to snapshot, project session state in UI | 5,341 | 15 | reducer model, identity normalization, snapshot read model, staleness/hysteresis |
| Terminal activation | Re-focus terminal/tmux context on project click, fallback routing | 4,004 | 5 | tmux client/session resolution, Ghostty AX routing, activation action model |
| Setup + hook lifecycle | install/repair hooks, shell setup, hook server lifecycle, startup gating | 4,569 | 16 | setup checker, hook schema migration, server health/restart loop |
| Main app shell + project cards | app lifecycle, project list rendering, drag/drop, ordering, UI state orchestration | 7,181 | 15 | monolithic app state, layout modes, project grouping/order |
| Idea capture + project creation + workstreams | idea CRUD, sensemaking, workstreams, project bootstrap flow | 3,754 | 9 | optional feature-gated workflows, creation monitors |
| Feedback + telemetry ingest | in-app feedback UX, payload shaping/redaction, optional remote ingest worker | 1,966 | 9 (+ worker) | funnel events, payload privacy policy, ingest allowlist |
| Debug/tuning surfaces | runtime/debug panels and UI tuning controls | 3,942 | 15 | debug cards, tuning panel, diagnostics surfaces |

Notes:
- Swift generated UniFFI bridge (`apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift`, 8,410 LOC) is excluded as generated complexity.
- Swift source total analyzed: ~34.3k LOC.
- Rust core + hud-hook source total analyzed: ~14.3k LOC.

## Findings

### 1) Runtime ingest/reducer complexity is mostly **Essential/Earned**

#### What it does
- Converts hook events and shell signals into deterministic project/session state.
- Preserves consistent state across restarts via snapshot persistence.

#### Assessment
- **Classification:** Essential/Earned.
- This is the irreducible part of the product. Most complexity here maps directly to correctness and determinism constraints.

#### What I verified
- External constraints: runtime-snapshot architecture is explicitly canonical in `docs/ARCHITECTURE.md` and `CLAUDE.md`.
- Safety/quality constraints: `docs/SESSION_STATE_RELEASE_MATRIX.md` enforces reducer/query replay gates.
- Consumer checks: widespread Swift dependence via `RuntimeClient` and session resolution paths.

### 2) Terminal activation has one likely **Legacy/Uncertain** layer

#### What it does
- Swift `TerminalLauncher` executes activation behavior today.
- Rust `runtime_activation` exports a large activation planner surface.

#### Assessment
- **Classification:** 
  - Swift activation path complexity: Earned (many bug-fix commits indicate load-bearing behavior).
  - Rust `runtime_activation` module: Legacy/Uncertain (appears unconsumed by Swift runtime today).
- There is likely duplicated conceptual architecture: a rich Rust activation planner plus independent Swift activation executor.

#### What I verified
- Consumer search:
  - `resolveActivationWithTrace` / `ActivationDecision` appear in generated bindings but no non-generated Swift call sites.
- Git history:
  - `TerminalLauncher.swift` has many recent bug-fix commits.
  - `runtime_activation/mod.rs` appears introduced in one foundational commit with no follow-up integration evidence.
- External constraints:
  - Rewrite decision `D-004` states Rust should own activation planning, but implementation appears incomplete/unused from Swift.

### 3) Frontier-only feature surface is likely **Accidental** for current mission

#### What it does
- Idea capture, project creation, workstreams, window anchoring.

#### Assessment
- **Classification:** Accidental (for current public-alpha core behavior), with medium risk if these are near-term roadmap commitments.
- These features are mostly disabled in stable profile defaults, yet they contribute major complexity across app state, views, and tests.

#### What I verified
- Consumer search: extensive references in `AppState`, views, and tests.
- External constraints:
  - `README.md` core value proposition focuses on session visibility + terminal switching.
  - `AppConfig` stable defaults disable these features (`ideaCapture`, `projectDetails`, `workstreams`, `projectCreation`, `windowAnchoring`).
- Git history: many of these surfaces originate in baseline commit or isolated feature commits; less evidence they are required for core loop.

### 4) App orchestration shape is **Accidental** complexity

#### What it does
- `AppState` coordinates runtime refresh, setup checks, creation flows, feedback, ordering, and feature branching.

#### Assessment
- **Classification:** Accidental.
- The concept count is high because unrelated workflows are centralized, increasing change blast radius.

#### What I verified
- Consumer search: broad call graph from most views into one object.
- LOC concentration: `AppState.swift` alone is 1,706 LOC.
- Historical signal: frequent edits in this file from unrelated concerns (state, setup, feedback, creation).

### 5) Feedback + remote ingest complexity is **Earned but optional**

#### What it does
- Feedback form, telemetry funnel, optional Cloudflare worker ingest path.

#### Assessment
- **Classification:** Earned for alpha feedback loops, optional for core product operation.
- Not required for main job-to-be-done (state + activation), but useful for product iteration and diagnostics.

#### What I verified
- Consumer search: integrated in header/settings, telemetry utilities, tests, and `services/ingest-worker`.
- External constraints: docs explicitly frame remote ingest as optional env-configured behavior.

### 6) Debug/tuning surfaces are **Earned for development**, but bloated in repo scope

#### What it does
- Debug panels, tuning UI, diagnostics views.

#### Assessment
- **Classification:** Earned (developer productivity), but candidates for packaging/separation.
- They help iteration but represent substantial code volume and cognitive overhead in main app tree.

#### What I verified
- Consumer search: debug windows wired under `#if DEBUG` in app menu/windows.
- LOC: ~3.9k across debug views + debug utilities.

## Summary of Proposals

| # | Proposal | Area | Complexity Reduction | Confidence | Effort |
|---|---|---|---|---|---|
| 1 | Commit to a "Core Product Mode" and remove frontier-only features from mainline (ideas, project creation, workstreams, window anchoring) | Product surface | ~5k-8k LOC + concept count reduction | High | Medium |
| 2 | Remove or quarantine unconsumed Rust activation planner until Swift actually uses it (single owner for activation logic) | Activation architecture | ~2.3k LOC + fewer cross-language concepts | Medium-High | Medium |
| 3 | Split `AppState` into narrow services (runtime state, setup/hooks, activation, optional features) and keep a thin composition root | Orchestration | Lower blast radius and easier agent reasoning | High | Medium |
| 4 | Collapse channel/profile/feature-flag matrix to one production profile for now; keep frontier in a separate build target or branch | Config complexity | Fewer runtime permutations and test matrix size | Medium | Low-Medium |
| 5 | Move debug/tuning tooling to a separate debug module/package to keep main app surface lean | Dev tooling | ~3.9k LOC moved out of primary cognitive path | Medium | Low-Medium |
| 6 | Keep runtime reducer/setup complexity largely intact; simplify around it, not through it | Runtime core | Avoids destabilizing essential complexity | High | N/A |

## Open Questions
1. Is "project creation + ideas + workstreams" a near-term product commitment, or exploratory frontier work? If exploratory, removal/defer is the highest-value simplification.
2. Should Rust own activation planning now, or should Swift own it fully for this release cycle? Current state appears split and partially disconnected.
3. Is remote ingest strategic for alpha, or can it be deferred to reduce moving parts during reliability hardening?

## Recommendations (Priority Order)
1. Define the non-negotiable core feature set (session visibility + terminal activation + setup) and freeze everything else.
2. Delete or isolate frontier-only features from mainline runtime paths.
3. Pick one activation owner (Swift or Rust) and remove the other path until needed.
4. Break `AppState` into deterministic service boundaries before major refactor automation.
5. Keep runtime ingest/reducer/setup correctness machinery; it is where complexity is most justified.
