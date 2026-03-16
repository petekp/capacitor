# Architecture Decisions

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

Append-only. Never edit or delete past entries. To reverse a decision, add a new entry that supersedes it.

---

## Decision 1: Choose Option 2 (`Core Facts, Swift Policy`)
- **Date:** 2026-03-13
- **Status:** Active
- **Context:** The seam audit found the dominant problem is shadow ownership and fake/implicit boundaries, not runtime transport correctness. The architecture exploration compared four options and recommended Option 2 as the best fit for coding-agent legibility.
- **Decision:** This migration will pursue Option 2. Rust remains the owner of canonical runtime facts and route evidence. Swift gets one explicit activation-policy owner. Coordinator, router, and drivers remain execution boundaries.
- **Alternatives considered:** Option 1 was rejected because it improves labels without consolidating ownership. Option 3 was rejected as the default because it adds a candidate-engine contract before we have evidence it removes enough Swift reasoning. Option 4 was rejected because it drags desktop-local policy into the core boundary.
- **Consequences:** Every implementation slice must reduce shadow ownership, not just rename it. The migration target is a simple lookup rule: Rust for facts, Swift policy for intent, Swift execution for side effects.
- **Supersedes:** none

## Decision 2: Start with a Swift policy extraction spike
- **Date:** 2026-03-13
- **Status:** Active
- **Context:** The main open risk for Option 2 is whether the current production logic collapses into one narrow Swift policy owner or merely creates another god object with callback plumbing.
- **Decision:** The first implementation slice is a TDD-first validation spike that creates a compile-time `ActivationPolicy` skeleton, captures failing tests for the current decision rules, and proves the policy owner can stay `facts in / intent out`.
- **Alternatives considered:** Jumping directly into code movement without proof was rejected because it would make it harder to distinguish an Option 2 failure from ordinary refactor churn. Reopening Option 3 before the spike was rejected because there is not yet evidence that a candidate engine is necessary.
- **Consequences:** If the spike fails to stay narrow, the migration pauses and the architecture decision is reopened before any larger rewrite continues.
- **Supersedes:** none

## Decision 3: Treat attached host-app identity as an explicit Swift-policy concern for this migration
- **Date:** 2026-03-13
- **Status:** Active
- **Context:** Attached tmux routes can legitimately carry `terminal_app = nil` today because the runtime contract does not always recover host-terminal identity from adapter data. That contract gap is real, but it does not by itself justify a candidate engine.
- **Decision:** Option 2 will accept attached host-app selection as a Swift-policy concern unless a later spike proves that richer runtime facts are cheap, reliable, and materially reduce client reasoning.
- **Alternatives considered:** Blocking the migration on a richer runtime contract was rejected because it would push the project toward Option 3 without first proving the simpler split is inadequate.
- **Consequences:** The Swift policy owner must describe when it is consuming canonical runtime facts versus when it is applying local fallback interpretation. It may not pretend those local inferences are runtime-authored.
- **Supersedes:** none

## Decision 4: Shadow and fake boundary surfaces are migration debt, not long-lived compatibility surfaces
- **Date:** 2026-03-13
- **Status:** Active
- **Context:** `runtime_activation`, `fetchRuntimeConfig`, `fetchCoreRoutingDiagnostics`, and `DebugShellStateCard` each make the system look like it has a different production owner than it really does.
- **Decision:** These surfaces must be retired, renamed, or relocated during this migration. The codebase will not preserve them as compatibility names once the canonical policy surface exists.
- **Alternatives considered:** Keeping them with better comments was rejected because the system already has evidence that labels alone are not enough; agents still follow production-looking symbols.
- **Consequences:** Slices must carry deletion targets and denylist patterns for these surfaces. Tests and docs move in the same PR as the code that replaces them.
- **Supersedes:** none
