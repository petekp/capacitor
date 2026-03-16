# Architecture Exploration: iTerm and Terminal.app Integration

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

## Goal

Improve the iTerm and Terminal.app integration so it is as trustworthy, diagnosable, and maintainable as the Ghostty path, without reopening the broader terminal-activation architecture.

## Problem

The current iTerm and Terminal.app path works, but it is still structurally second-class:

- both terminals share one generic `ScriptedTerminalDriver`
- focus and launch are best-effort instead of typed and explicit
- launch currently always reports success
- failure reasons are Ghostty-specific, so host-terminal failures can degrade into no reason or the wrong user-facing message
- automated coverage for iTerm and Terminal.app is much shallower than Ghostty

This creates a mismatch between the UX spec's promise of reliable TTY-based activation and the actual ownership/error model in code.

## Invariants

- Rust remains the owner of runtime inputs and route derivation.
- Swift remains the owner of terminal activation execution.
- The single-client, session-swapping model stays in place.
- iTerm and Terminal.app may continue using TTY-based activation; we are not trying to recreate Ghostty's richer native routing model.
- Ghostty's current adapter boundary stays intact.

## Non-Goals

- Re-architecting the whole terminal activation stack across Rust and Swift.
- Adding new supported terminals.
- Replacing TTY-based activation for iTerm/Terminal with a fundamentally different routing strategy.
- Starting the migration in this document.

## Constraints

- Host-terminal automation depends on AppleScript and `System Events`.
- iTerm and Terminal.app do not currently have a Ghostty-style snapshot adapter in this codebase.
- The project values deterministic tests and visible failure modes over backwards-compatibility shims.
- Manual QA will still matter because AppleScript behavior is partially environment-dependent.

## External Surfaces

- macOS AppleScript / `System Events`
- `open -b <bundle-id>`
- `tmux` CLI for session and pane switching
- activation toasts in the app UI
- project creation / resume launch path
- manual QA and release docs

## Current System

| Area | Current Owner | Inputs | Outputs | Dependencies | Pain |
|------|---------------|--------|---------|--------------|------|
| Preferred terminal selection | `TerminalLauncher.resolvePreferredTerminalApp` | shell state, client TTY, session name, project path | `SupportedTerminalApp` | runtime shell state | good enough, but only chooses app, not capability/failure policy |
| Activation orchestration | `TerminalActivationCoordinator.runActivationFlow` | resolved session, client TTY, focus result | launch / switch / relaunch decisions | tmux, driver result | clean boundary, but relies on drivers to distinguish `failed` vs `relaunchNeeded` |
| iTerm + Terminal focus/launch | `ScriptedTerminalDriver` | app, TTY, command, project path | focus bool, fire-and-forget launch | AppleScript, `System Events`, `open` | one generic driver, inline app switch, no typed failure modes |
| Ghostty focus/launch | `GhosttyTerminalDriver` + `GhosttyAutomationClient` | Ghostty snapshot, route match, launch config | typed success/failure, deterministic focus | Ghostty AppleScript model | stronger ownership and richer failure model than other terminals |
| User-facing failure messaging | `AppState` toast surface | `TerminalActivationFailureReason?` | error toast | activation result | currently Ghostty-biased fallback copy |
| Resume launch | `ProjectCreationCoordinator` via `TerminalScripts.launchWithCommand` | project path, Claude resume command | shell script | selected terminal app | inherits weak host-terminal launch reporting |

## Option 1: Harden the Existing Shared Scripted Driver

### Architecture Shape

Keep `ScriptedTerminalDriver` as the shared iTerm/Terminal implementation, but harden it:

- add terminal-agnostic failure reasons
- make launch and focus return checked results instead of silent success
- extract the iTerm and Terminal AppleScript strings into named builders
- fix the app-level error copy to be terminal-aware
- add focused tests for host-terminal success and failure paths

### Why It Might Work

It addresses the most important correctness and observability gaps without changing the overall architecture shape.

### Tradeoffs

- Simplest migration path
- Keeps concept count low
- Still leaves iTerm and Terminal.app coupled in one owner
- Future app-specific complexity will continue to accumulate in one switch

### Failure Modes

- The shared driver becomes a “misc host terminals” bucket that slowly regresses into Ghostty's old problem: too many concerns in one place
- App-specific quirks keep leaking into shared control flow

### Disqualifiers

- Wrong choice if we expect iTerm and Terminal.app to diverge meaningfully in capability or UX behavior soon

### Cleanup / Migration Implications

- Mostly local edits to the current driver, error model, tests, and toast surface
- Lowest cleanup burden

### Unknowns

- Whether checked AppleScript execution alone is enough to give high-quality failure signals without splitting ownership

## Option 2: Split Into First-Class Per-App Host Adapters

### Architecture Shape

Create separate host-terminal automation owners, for example:

- `ITermAutomationClient` or `ITermDriver`
- `TerminalAppAutomationClient` or `TerminalAppDriver`

Each app owns:

- `focusByTTY`
- `launchCommand`
- app-specific script construction
- app-specific error mapping

`TerminalDriverRegistry` still selects the terminal, and `TerminalActivationCoordinator` still orchestrates the flow.

### Why It Might Work

This gives iTerm and Terminal.app the same ownership clarity Ghostty now has, without forcing a fake common abstraction over very different automation models.

### Tradeoffs

- Slightly more code and types than Option 1
- Much sharper ownership
- Better test seams
- Easier app-specific docs and failure copy
- Moderate migration difficulty, but still bounded to Swift terminal activation

### Failure Modes

- Over-splitting into tiny files without actually improving error handling
- Duplicating too much script boilerplate if shared shell helpers are not kept small

### Disqualifiers

- Wrong choice if the team wants the absolute minimum change and is confident the shared driver will stay simple

### Cleanup / Migration Implications

- Delete or shrink `ScriptedTerminalDriver`
- Move inline iTerm/Terminal script branches into dedicated owners
- Expand tests around each adapter
- Update app messaging and docs once to stop assuming Ghostty in failures

### Unknowns

- Whether a full driver split is needed, or whether dedicated automation clients beneath a shared driver is the better variant

## Option 3: Unify All Terminals Under One Automation-Adapter Layer

### Architecture Shape

Introduce a cross-terminal automation protocol that Ghostty, iTerm, and Terminal.app all implement. The protocol would cover focus, launch, app detection, failure mapping, and possibly app state reads.

### Why It Might Work

This maximizes consistency and makes the terminal layer look symmetrical on paper.

### Tradeoffs

- Strongest boundary story
- Highest migration difficulty
- Highest abstraction risk because Ghostty's snapshot/routing model is fundamentally richer than the TTY-based host drivers
- Most likely to produce leaky “lowest common denominator” APIs

### Failure Modes

- The shared protocol becomes too generic to express Ghostty well, or too complex for iTerm/Terminal to fit naturally
- Migration turns into framework-building instead of reliability improvement

### Disqualifiers

- Wrong choice if the real problem is failure modeling and test depth rather than missing top-level abstraction

### Cleanup / Migration Implications

- Larger refactor with more vestigial cleanup risk
- More docs and tests to rework

### Unknowns

- Whether the protocol can stay deep and useful instead of becoming ceremonial

## Option 4: Do Less

### Architecture Shape

Fix only the obvious correctness issues:

- stop Ghostty-specific fallback messaging for non-Ghostty failures
- add minimal host-terminal failure reasons
- add a few focused tests

Leave the current shared driver architecture in place.

### Why It Might Work

If the system is mostly fine and we only need to remove misleading UX and obvious blind spots, this is the cheapest path.

### Tradeoffs

- Lowest disruption
- Lowest payoff
- Leaves the ownership asymmetry untouched

### Failure Modes

- We paper over symptoms and revisit the same architecture question later

### Disqualifiers

- Wrong choice if we care about long-term maintainability, not just immediate bug reduction

### Cleanup / Migration Implications

- Tiny diff, but poor convergence

### Unknowns

- Whether the team would be satisfied with a patch-level improvement after the Ghostty cleanup raised the quality bar

## Tradeoff Matrix

| Dimension | Option 1 | Option 2 | Option 3 | Option 4 |
|-----------|----------|----------|----------|----------|
| Simplicity | High — minimal shape change | Medium — a few more types, still local | Low — new abstraction layer | Very High — smallest change |
| Boundary Clarity | Medium — still one shared host driver | High — one owner per host app | High on paper, medium in practice if abstraction leaks | Low — asymmetry remains |
| Migration Difficulty | Low | Medium | High | Very Low |
| Cleanup Burden | Low | Medium | High | Low now, likely higher later |
| Operability | Medium — better than today if results become typed | High — app-specific failure mapping and logging | Medium — depends on abstraction quality | Low-Medium |
| Testability | Medium | High | Medium | Low-Medium |
| Long-Term Flexibility | Medium | High | Medium | Low |
| Lock-In Risk | Low | Low | Medium — commits to an abstraction shape | Low |

## Assumptions

| Assumption | Why It Matters | How to Verify | Fastest Disproof |
|------------|----------------|---------------|------------------|
| iTerm and Terminal.app can continue sharing the same high-level TTY strategy | Keeps scope bounded | Review live proofs and current UX spec | A real requirement emerges for tab/window routing beyond TTY targeting |
| Most current pain is in failure modeling and ownership, not in tmux routing | Determines whether we need local refactor or broader redesign | Trace recent issues and logs around activation failures | New evidence shows wrong-client selection is the primary issue |
| AppleScript/`System Events` errors can be surfaced deterministically enough to improve UX | Needed for typed failure handling | Build one checked execution spike | Errors remain too environment-specific to classify usefully |
| Ghostty should remain a special-case adapter, not be forced into the same interface as host drivers | Avoids bad abstraction | Compare Ghostty snapshot needs to iTerm/Terminal needs | A convincing unified protocol emerges with no leaky compromises |

## Risk Register

| Risk | Option(s) Affected | Likelihood | Impact | Mitigation |
|------|--------------------|------------|--------|------------|
| Shared host driver keeps accumulating app-specific branches | 1, 4 | Medium | Medium | Split ownership or at least split script builders |
| Over-abstracting terminal automation obscures real app differences | 3 | High | High | Reject protocol-first design unless a spike proves depth |
| Migration changes error handling but not user-visible messaging | 1, 2, 4 | Medium | Medium | Include AppState/toast surface in scope from day one |
| AppleScript failure handling is still flaky in real environments | 1, 2, 3 | Medium | High | Keep manual QA proof in acceptance criteria |

## Validation Spikes

| Spike | Question Answered | Cost | Success Signal | Failure Signal |
|-------|-------------------|------|----------------|----------------|
| Checked host-driver execution spike | Can iTerm/Terminal focus and launch produce typed success/failure instead of fire-and-forget bools? | Low | A small prototype returns explicit `focused / relaunchNeeded / failed(reason)` with deterministic tests | The AppleScript boundaries remain too opaque to classify cleanly |
| Failure-copy spike | Can we remove Ghostty-biased UX without broader architecture change? | Very Low | iTerm/Terminal failure path shows correct terminal-aware copy under test | UI still has to guess or collapse to generic messaging |
| Per-app adapter skeleton | Is Option 2 structurally lightweight enough? | Low-Medium | Compile-time skeleton with `ITerm...` and `TerminalApp...` owners feels smaller/clearer than the shared driver | The split mostly creates ceremony without clearer boundaries |

## Recommendation

**Recommend Option 2: split iTerm and Terminal.app into first-class host adapters, while keeping the existing activation coordinator and TTY-based strategy.**

It wins because it fixes the real problems without overreaching:

- sharper ownership, matching the direction Ghostty already proved out
- app-specific failure modeling and messaging
- better test seams
- no fake “all terminals are the same” abstraction
- bounded migration scope inside Swift terminal activation

## Runner-Up

**Option 1** is the runner-up. It is a valid low-risk path if we want the smallest possible refactor, but it likely leaves us revisiting the same architecture question once iTerm and Terminal.app need more explicit behavior or failure handling.

## Why The Other Options Lose

- **Option 3** loses because it solves the wrong problem first. The current issue is not lack of abstraction; it is weak ownership and weak error modeling for host terminals.
- **Option 4** loses because it fixes symptoms, not structure. It is acceptable only if we want a bug patch, not a cleaner integration architecture.

## Decision Needed

Choose whether we want:

- a **bounded structural cleanup** now (Option 2), or
- a **smaller hardening pass** that leaves the shared host driver in place (Option 1)

## Handoff to audit-and-migrate

- **Chosen architecture:** Option 2 unless new evidence strongly favors the smaller Option 1 path
- **Decision rationale:** Ghostty already demonstrated the value of per-terminal ownership; iTerm and Terminal.app need the same clarity, but not a cross-terminal abstraction rewrite
- **Invariants:** Swift owns execution; Rust owns routing inputs; TTY-based host activation remains valid; Ghostty adapter stays intact
- **Non-goals:** no new terminal support, no full activation rewrite, no change to tmux session-swapping model
- **Critical workflows:** card click activation, detached-session attach, project creation / resume launch, activation failure UX
- **External surfaces:** AppleScript, `System Events`, `open -b`, tmux CLI, app toasts, manual QA artifacts
- **Known hotspots:** `ScriptedTerminalDriver`, `TerminalActivationFailureReason`, `AppState` toast copy, host-terminal launch/focus tests
- **Leading migration risks:** adapter split without real failure modeling, UI copy not updated, insufficient live QA after refactor
- **Expected deletion zones:** shared iTerm/Terminal switch branches inside `ScriptedTerminalDriver`, Ghostty-biased fallback copy, host-terminal test gaps that get replaced by per-app tests
- **Validation spikes already run:** none beyond architecture inspection
- **What still needs proof:** whether a full per-app split feels materially better than a hardened shared driver after a thin compile/test spike
