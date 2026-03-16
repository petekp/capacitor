# Architecture Exploration: Rust-Swift Boundary Legibility

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

## Goal

Make the current Rust + `hud-hook` + Swift system more elegant and legible for coding agents by ensuring that:

- every important activation and routing decision has one obvious production owner
- the runtime contract says only what production actually relies on
- debug, test, and docs paths do not masquerade as authoritative production policy
- a new agent can answer "where does this decision live?" without rediscovering the whole subsystem

## Problem

The redesign substantially improved transport and execution boundaries, but the system is still not maximally legible to coding agents.

The main problems are not correctness bugs first; they are boundary legibility failures:

- Rust still contains a large activation-policy model in `core/capacitor-core/src/runtime_activation/mod.rs`, but it is test-only and not on the production path.
- Swift owns the real project-card activation path, but terminal/session selection policy is spread across `AppState`, `TerminalLauncher`, `SupportedTerminalApp`, and runtime-client diagnostic helpers.
- The runtime route contract is strong for tmux identity, but incomplete for attached host-terminal identity in some real cases, so Swift must infer meaning after consuming runtime facts.
- Config- and diagnostics-looking APIs in Swift imply a runtime-backed boundary that does not actually exist.
- Fallback terminal choice is a real user-visible policy, but it is currently implicit in enum order and helper behavior rather than clearly owned.

This makes the system harder for coding agents to reason about than it needs to be, even though the live execution path itself is much cleaner than before.

## Invariants

- The dedicated local runtime service remains the live runtime boundary.
- Rust remains the owner of ingest, reducer/query truth, and canonical runtime facts.
- Swift remains the owner of macOS side effects and terminal-driver execution.
- Project-card activation remains route-first, pane-aware, and tmux-backed.
- Snapshot-file-first app reads do not return as the primary runtime boundary.
- The system continues to support Ghostty, iTerm, and Terminal.app without introducing compatibility shims for legacy daemon-era architecture.

## Non-Goals

- Implementing the migration in this document
- Adding new supported terminal apps
- Replacing tmux with a different session model
- Removing the runtime service or collapsing back to a single-process app
- Solving every UX issue around activation; this is a legibility/ownership exploration, not a feature roadmap

## Constraints

- macOS-local execution facts such as running apps, AppleScript behavior, and `NSWorkspace` state live naturally in Swift, not Rust.
- `hud-hook` parent-app detection can collapse attached tmux shells to `tmux`, which limits route completeness unless the adapter contract changes.
- The current production path is already Swift-owned for activation, so any option that changes that must earn the migration cost.
- Coding-agent legibility favors low concept count, explicit ownership, honest naming, and minimal shadow logic.
- Recent churn is concentrated in terminal activation and cleanup (`cdca860`, `06cbd33`, `54e14f9`, `e11c7db`), which suggests the boundary is still converging and should not be destabilized casually.

## External Surfaces

- Runtime service endpoints:
  - `GET /health`
  - `GET /runtime/snapshot`
  - `POST /runtime/ingest/hook-event`
  - `POST /runtime/ingest/shell-signal`
- Shell adapter environment and tmux context:
  - `TERM_PROGRAM`
  - `TERM`
  - `TMUX`
- `tmux` CLI
- `NSWorkspace`
- AppleScript / terminal-app automation
- Runtime logs under `~/.capacitor/runtime/`
- Swift debug surfaces and telemetry

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Pain |
|------|---------------|--------|---------|--------------|------|
| Runtime service shell | `core/hud-hook` | Claude hooks, shell CWD signals, auth bootstrap | `/runtime/snapshot`, ingest endpoints | tiny_http, env detection, runtime service bootstrap | Clean transport boundary, but adapter-level parent-app detection affects downstream route completeness |
| Runtime truth and route derivation | Rust reducer/query | shell signals, hook events, persisted/runtime state | sessions, shells, routing views | `capacitor-core` reducer + projection | Good canonical facts, but attached host-terminal identity is not always recoverable from the current contract |
| Swift runtime projection | `RuntimeClient`, `AppState`, `SessionStateManager`, `ShellStateStore`, `RoutingStateStore` | runtime snapshot payload | visible app state and activation inputs | HTTP snapshot client, local freshness guards | Projection is mostly clean, but some confidence/evidence/config semantics are synthesized locally |
| Activation policy surface | `AppState` + `TerminalLauncher` + `SupportedTerminalApp` | route data, shell data, tmux state, local app availability | session choice, terminal app choice, fallback ladder | runtime snapshot + tmux CLI + `NSWorkspace` | Real production owner exists, but policy is distributed and partly implicit |
| Execution path | `TerminalActivationCoordinator`, `TmuxRouter`, terminal drivers | chosen session/app/pane/TTY | tmux switch/launch, app focus/launch | tmux CLI, AppleScript, Ghostty automation | Execution boundaries are much cleaner than policy boundaries |
| Diagnostics and shadow policy | Rust test-only activation module, `RuntimeClient.fetchCoreRoutingDiagnostics`, `DebugShellStateCard` | runtime snapshot + local interpretation | tests, debug UI, derived confidence/evidence | test-only module, debug-only view | These paths look authoritative enough to mislead agents about where production policy lives |

## Option 1: Governance Cleanup Only

### Architecture Shape

Keep the current production architecture and clean up only the misleading surfaces:

- document the real production owner for each decision
- explicitly mark `runtime_activation` as non-authoritative test/spec logic or archive it
- rename fake boundary APIs so they stop sounding runtime-authored
- document fallback ladder and route incompleteness honestly
- leave production policy physically distributed where it is today

### Why It Might Work

It addresses the most dangerous legibility traps without moving logic across the boundary.

### Tradeoffs

- Lowest migration cost
- Improves docs and naming quickly
- Leaves the real policy spread across several Swift surfaces
- Keeps the same amount of production indirection, just better labeled

### Failure Modes

- Agents still have to hop across multiple Swift files to understand one activation decision
- Shadow paths become "documented but still present" instead of actually disappearing

### Disqualifiers

- Wrong choice if the goal is real architectural elegance, not just less misleading documentation

### Cleanup / Migration Implications

- Mostly docs, naming, comments, and explicit labels
- Lowest deletion burden

### Unknowns

- Whether documentation alone is enough to materially improve coding-agent comprehension

## Option 2: Core Facts, Swift Policy

### Architecture Shape

Codify the system around the production reality:

- Rust owns canonical runtime facts and route evidence only
- Swift owns activation policy interpretation, freshness policy, fallback policy, diagnostics interpretation, and all macOS execution
- production activation policy is consolidated into one explicit Swift policy layer, rather than being spread across `AppState`, `TerminalLauncher`, and helper enums
- shadow Rust activation policy is retired or explicitly demoted to non-authoritative fixture/spec territory
- any config- or diagnostics-looking APIs that are actually local synthesis are renamed to reflect that truth

The mental model becomes:

`Rust emits facts -> Swift policy chooses intent -> Swift execution performs side effects`

### Why It Might Work

This matches the actual production path today and minimizes concept count.

It makes coding-agent lookup easy:

- if the question is "what facts exist in the runtime?" look in Rust
- if the question is "why did the click choose this terminal/session/fallback?" look in one Swift policy surface
- if the question is "how does the app actually focus or launch?" look in the coordinator/router/drivers

### Tradeoffs

- Strong alignment with production reality
- Lowest conceptual overhead after cleanup
- Keeps some higher-level decision-making in the client rather than the core
- Requires accepting that host-terminal selection is a client concern, not a runtime concern, unless more facts are added later

### Failure Modes

- The Swift policy owner becomes a new dumping ground if not kept explicit and narrow
- Rust contract gaps may still tempt ad hoc heuristics unless the fact/policy split is documented and enforced rigorously

### Disqualifiers

- Wrong choice if the system is expected to support multiple independent clients that all need the same activation reasoning from the runtime

### Cleanup / Migration Implications

- Expected deletion or demotion zones:
  - test-only Rust activation model as an apparent production architecture
  - fake runtime-config semantics in Swift
  - distributed terminal-selection policy across multiple Swift owners
  - implicit fallback policy hidden in helpers
- Moderate cleanup burden, but mostly convergent cleanup rather than cross-language architecture work

### Unknowns

- Whether the attached host-app identity gap is acceptable as an explicit Swift policy concern, or whether the runtime contract still needs a richer host-app fact

## Option 3: Rust Candidate Engine, Swift Executor

### Architecture Shape

Move from "Rust facts + Swift heuristics" to "Rust candidate reasoning + Swift local overlay":

- Rust emits an explicit activation candidate set or typed activation-intent record
- the candidate set includes freshness/evidence/ranking context, not just route fields
- Swift stops ranking raw shell and route facts directly
- Swift still applies local desktop-only constraints:
  - running apps
  - installed apps
  - user preference
  - actual execution/focus/launch

The mental model becomes:

`Rust proposes ranked activation candidates -> Swift overlays local desktop facts -> Swift executes`

### Why It Might Work

It gives the core one canonical reasoning artifact without forcing Rust to own macOS execution.

This is the best option if we want agents to inspect one structured "why this target?" output coming from the runtime instead of reconstructing the logic in Swift.

### Tradeoffs

- Stronger diagnostic and reasoning contract than Option 2
- Better fit if future clients besides the Swift app may need the same activation reasoning
- Higher concept count: candidates, evidence, local overlay, and executor all become first-class
- More cross-language API design and migration burden

### Failure Modes

- Swift still needs enough local overlay that the apparent ownership is cleaner on paper than in reality
- The candidate contract becomes an abstraction layer that is expensive to maintain but not much simpler to consume

### Disqualifiers

- Wrong choice if no second client is planned and the main goal is to simplify, not to create a richer cross-language reasoning API

### Cleanup / Migration Implications

- Larger contract and docs rewrite
- More vestigial-risk cleanup because both the old route API and the new candidate API would coexist during migration
- Higher burden on tests, debug tooling, and diagnostic surfaces

### Unknowns

- Whether a candidate engine actually removes enough Swift policy to justify the new contract
- Whether attached host-app identity can be captured richly enough for Rust candidates to stay authoritative

## Option 4: Full Core Activation Plan

### Architecture Shape

Rust becomes the owner of the full activation plan, including primary and fallback action:

- Swift passes local capability and preference inputs into a core planning API
- Rust returns a primary/fallback execution plan
- Swift is reduced to executor and UI reporter

The mental model becomes:

`Swift supplies desktop facts -> Rust returns the activation plan -> Swift executes`

### Why It Might Work

It provides the strongest single-owner story on paper.

### Tradeoffs

- Highest apparent boundary clarity
- Highest coupling between runtime/core and desktop-specific policy
- Requires designing a request/response planning API in addition to the runtime snapshot boundary
- Most likely to pull macOS-specific concerns into a place the current architecture is trying to keep platform-neutral

### Failure Modes

- Core planning becomes polluted with desktop capability and preference concerns
- The system gains a more complex boundary that is harder, not easier, for coding agents to reason about

### Disqualifiers

- Wrong choice if the project still wants Rust to own runtime semantics rather than desktop policy

### Cleanup / Migration Implications

- Highest migration difficulty
- Highest rollback complexity
- Highest risk of vestigial overlapping APIs during transition

### Unknowns

- Whether the additional purity is real, or whether it just moves the same ambiguity behind a more expensive boundary

## Tradeoff Matrix

| Dimension | Option 1 | Option 2 | Option 3 | Option 4 |
|-----------|----------|----------|----------|----------|
| Simplicity | High — almost no logic movement | High — one explicit Swift policy owner plus Rust facts | Medium — adds candidate layer | Low — adds planning API and more cross-boundary concepts |
| Boundary Clarity | Medium — better labels, same shape | High — explicit `facts vs policy vs execution` split | High — explicit candidate boundary, but still needs local overlay | Medium — clear on paper, but desktop facts blur the core/client line |
| Migration Difficulty | Very Low | Medium | High | Very High |
| Cleanup Burden | Low now, likely recurring later | Medium — concentrated cleanup with good convergence | High — more contract and tooling cleanup | Very High |
| Operability | Medium — docs get better, runtime behavior unchanged | High — production owner is explicit and diagnosable | High — strongest cross-language reasoning surface | Medium — more moving parts, harder to debug end to end |
| Testability | Medium | High — unit-testable client policy plus existing driver tests | High — strong candidate-engine tests plus executor tests | Medium — request/plan API and executor tests become more complex |
| Coding-Agent Legibility | Medium — less misleading, still scattered | Very High — one obvious lookup rule | High — powerful, but more concepts to carry | Medium — theoretically clean, practically denser |
| Long-Term Flexibility | Medium | High for a single macOS client | Very High if multiple clients emerge | Medium — flexible in theory, but expensive to evolve |
| Lock-In | Low | Low | Medium — commits to a richer cross-language reasoning contract | High — commits core to desktop-plan semantics |

## Assumptions

| Assumption | Why It Matters | How to Verify | Fastest Disproof |
|------------|----------------|---------------|------------------|
| Coding-agent confusion is driven more by split ownership and shadow logic than by raw algorithmic complexity | Determines whether simplification or richer core modeling is the better direction | Ask whether agents mostly get lost on "where does this live?" versus "what does this algorithm do?" | New evidence shows the main problem is not ownership but missing runtime reasoning power |
| Swift can host one narrow activation-policy owner without becoming another oversized god object | Needed for Option 2 to stay elegant | Prototype an `ActivationPolicy` skeleton and see whether the current distributed logic collapses naturally | The skeleton still requires too many ad hoc callbacks and cross-file branches |
| Multiple clients consuming the same activation reasoning are not an immediate product requirement | Favors Option 2 over Option 3 | Check roadmap and actual consumers of activation reasoning | A second client or headless consumer is already imminent |
| Attached host-terminal identity cannot be made universally complete from current adapter data without intentional contract work | Determines whether Rust can realistically be the full authority | Spike richer adapter capture for tmux-attached shells | Host app turns out to be reliably recoverable already, making Option 3 stronger |

## Risk Register

| Risk | Option(s) Affected | Likelihood | Impact | Mitigation |
|------|--------------------|------------|--------|------------|
| Documentation improves but hidden production policy remains scattered | 1 | High | Medium | Reject Option 1 unless the goal is explicitly documentation-only |
| The new Swift policy owner becomes a miscellaneous bucket | 2 | Medium | High | Keep it facts-in / intent-out only; execution stays in coordinator/router/drivers |
| Cross-language candidate contract adds elegance on paper but not in practice | 3 | Medium | High | Run a candidate skeleton spike before committing |
| Core planning absorbs too much desktop-local policy | 4 | High | High | Reject unless a very strong multi-client requirement appears |
| The team keeps both old and new reasoning surfaces during migration | 2, 3, 4 | Medium | High | Plan deletion zones up front and treat overlap as migration debt, not feature safety |

## Validation Spikes

| Spike | Question Answered | Cost | Success Signal | Failure Signal |
|-------|-------------------|------|----------------|----------------|
| Swift policy extraction skeleton | Can the current production decision logic collapse into one narrow Swift owner without behavior change? | Low | A compile-time `ActivationPolicy` or `TerminalSelectionPolicy` skeleton can absorb the current resolver logic from `AppState` and `TerminalLauncher` cleanly | The logic still requires sprawling callbacks and duplicated helper ownership |
| Rust candidate skeleton | Would a candidate engine materially reduce Swift reasoning, or just move the same ambiguity into a new contract? | Low-Medium | A thin `ActivationCandidate` shape eliminates most Swift ranking logic and makes diagnostics clearer | Swift still needs substantial ranking/interpretation, making the new contract mostly ceremonial |
| Attached host-app identity probe | Can the runtime reliably emit host-terminal identity for attached tmux cases? | Low-Medium | A spike shows `hud-hook` + reducer can carry host app for attached tmux shells without fragile heuristics | Host app remains inherently client-local or too unreliable to treat as canonical runtime fact |

## Recommendation

**Recommend Option 2: Core Facts, Swift Policy.**

It is the best fit for the actual system and for coding-agent legibility.

Why it wins:

- It matches the real production path instead of fighting it.
- It gives agents the simplest lookup rule:
  - Rust for runtime facts
  - one Swift policy owner for activation reasoning
  - coordinator/router/drivers for execution
- It removes the most confusing shadow architecture without creating a new cross-language abstraction tax.
- It preserves the dedicated runtime service and the clean terminal-driver execution split that the redesign already established.

## Runner-Up

**Option 3: Rust Candidate Engine, Swift Executor**

This is the strongest alternative if the team expects more than one client to need the same activation reasoning, or if runtime-authored diagnostics become a strategic requirement.

It loses today because it adds a new concept layer and migration burden before we have evidence that the additional cross-language reasoning surface is necessary.

## Why The Other Options Lose

- **Option 1** loses because it improves honesty but not elegance. It reduces surprise, but agents still need to understand the same scattered policy shape.
- **Option 4** loses because it over-corrects. It optimizes for single-owner purity at the cost of dragging desktop-local concerns into the core boundary.

## Decision Needed

Choose whether to optimize the next iteration for:

- **single-client elegance and low concept count**: Option 2
- **future multi-client/shared reasoning power**: Option 3

Based on the current evidence, Option 2 is the better default.

## Handoff to audit-and-migrate

- **Chosen architecture:** Option 2 unless the validation spikes prove a candidate engine is clearly worth the added contract surface
- **Decision rationale:** Align the architecture with the real production path, eliminate shadow ownership, and make the lookup rule obvious for coding agents
- **Invariants:** runtime service stays; Rust owns runtime truth; Swift owns desktop execution; activation remains route-first and pane-aware
- **Non-goals:** no immediate refactor here, no new terminal support, no tmux model change, no runtime-service removal
- **Critical workflows:** project-card activation, attached tmux reuse, detached direct-shell activation, no-client attach-or-create, fallback terminal selection, activation diagnostics
- **External surfaces:** `/runtime/snapshot`, ingest endpoints, `TERM_PROGRAM`, `TMUX`, tmux CLI, `NSWorkspace`, AppleScript, runtime logs and telemetry
- **Known hotspots:** Rust `runtime_activation` shadow model, reducer route completeness for attached tmux, `AppState` resolver injection, `TerminalLauncher.resolveSessionName`, `TerminalLauncher.resolvePreferredTerminalApp`, `RuntimeClient.fetchRuntimeConfig`, `RuntimeClient.fetchCoreRoutingDiagnostics`, `SupportedTerminalApp.detectAvailable`
- **Leading migration risks:** moving too little and leaving shadow logic alive, moving too much and recreating a heavier abstraction layer, failing to delete old reasoning surfaces
- **Expected deletion zones:** shadow Rust activation policy as an apparent production owner, fake runtime-config semantics, distributed Swift selection helpers, implicit fallback-policy hiding places
- **Validation spikes already run:** none for the new architecture yet; only the seam audit and current-state verification are complete
- **What still needs proof:** whether a single Swift policy owner stays narrow in practice, and whether richer attached host-app facts are feasible enough to justify a candidate engine later
