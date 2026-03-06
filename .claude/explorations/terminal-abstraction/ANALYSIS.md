# Analysis: Terminal Abstraction Layer

## Updated Criteria

User feedback added two critical constraints:
- **Uniform excellence:** Every supported terminal gets robust, precise activation. No tiers, no degraded experiences.
- **Engineering quality as differentiator:** The abstraction itself should be superlatively well-engineered. This is not just about shipping — it's about the quality of the design.

## Eliminations

### Eliminated: Paradigm 4 (Observation-First)
**Reason:** Fails the "robust support" MUST. Generic `open -a` without tab focus is not excellent UX for any terminal. The user explicitly wants activation quality to be uniform across supported terminals.

### Eliminated: Paradigm 5a (Three Tiers)
**Reason:** Fundamentally at odds with the "no tiers" requirement. A Tier 3 terminal is an unsupported terminal with a facade. Either support it well or don't claim to support it.

### Eliminated: Approach 1a (Full Strategy Protocol)
**Reason:** Over-scoped. Previous Gen 2 (ActivationActionExecutor + 3 adapter protocols) covered the same ground and was removed for ceremony-over-substance. A protocol with 4+ methods covering detect/activate/launch/focusTab tries to unify operations that don't actually vary the same way across terminals.

### Eliminated: Approach 2a (Rust Resolver FFI)
**Reason:** The Rust resolver solves a different problem — *which shell to activate* (ranking candidates by liveness, path specificity, etc.). The terminal abstraction problem is *how to activate a terminal once you know which one*. These are orthogonal. The resolver can be reintegrated independently later. Coupling them now conflates two concerns.

### Eliminated: Approach 2b (Port Rust to Swift)
**Reason:** 2,345 lines of logic duplication with drift risk. Contradicts engineering quality goal.

### Eliminated: Approach 3a (Broadcast TTY Lookup)
**Reason:** O(n) broadcast across terminals is inelegant. Running AppleScript against terminals that aren't relevant wastes cycles and is architecturally sloppy.

### Eliminated: Approach 5b (Registry with Closures)
**Reason:** Closure registries are less discoverable than protocols or concrete types. For a codebase that values engineering quality, the dispatch mechanism should be transparent.

## Tradeoff Matrix

| Criterion | 1b: Minimal Protocol | 3b: TTY + Hint Switch | Hybrid: Protocol + TTY |
|-----------|---------------------|----------------------|----------------------|
| **MUST: Ghostty/iTerm/Terminal.app** | ✅ Each gets own type | ✅ Each gets own function | ✅ Each gets own type |
| **MUST: No Ghostty regression** | ✅ GhosttyActivator wraps existing AX code | ✅ Existing AX code in switch case | ✅ GhosttyActivator wraps existing AX code |
| **MUST: Clean separation** | ✅ Protocol boundary | ⚠️ Functions in TerminalLauncher | ✅ Protocol boundary + shared TTY infra |
| **MUST: Auto-detect terminal** | ✅ Factory from ParentApp | ✅ Switch on ParentApp | ✅ Factory from ParentApp |
| **MUST: < 500 lines new code** | ~250 lines | ~180 lines | ~300 lines |
| **SHOULD: New terminal = one file** | ✅ Add conforming type | ❌ Modify switch + add function | ✅ Add conforming type |
| **SHOULD: Graceful degradation** | ✅ Protocol can define capability levels | ⚠️ Ad hoc per function | ✅ Explicit capability model |
| **SHOULD: Use ParentApp enum** | ✅ Factory maps it | ✅ Switch on it | ✅ Factory maps it |
| **SHOULD: TerminalLauncher unchanged** | ✅ Calls activator | ⚠️ Switch lives inside it | ✅ Calls activator |
| **NICE: Launch support** | ⚠️ Protocol could grow | ❌ Not structured for it | ✅ Composable capabilities |
| **NICE: Terminal preference** | ✅ Ordered list of activators | ⚠️ Hardcoded priority | ✅ Ordered list of activators |
| **NICE: Mockable/testable** | ✅ Protocol conformance | ⚠️ Functions are testable but not injectable | ✅ Protocol conformance |
| **Engineering quality** | Good — clean protocol | Adequate — simple but unstructured | Excellent — principled + pragmatic |

## Finalists

### Finalist 1: Approach 1b — Minimal Activate-Only Protocol

A narrow protocol with one job: bring the right terminal window/tab to front.

**Selected because:** Cleanest separation of concerns. Each terminal is a self-contained type with its own file, tests, and activation logic. The protocol is narrow enough to avoid the ceremony problem that killed Gen 2, but structured enough to be properly extensible. Adding Kitty someday = add `KittyActivator.swift`, done.

**Concern:** Is a single-method protocol over-formal? A closure or function would work too. But for a codebase that values engineering quality, the protocol communicates intent and enables testing.

### Finalist 2: Hybrid — Protocol + Shared TTY Infrastructure

Builds on 1b but adds a shared TTY discovery layer that iTerm2 and Terminal.app both use, while Ghostty takes its own AX path.

**Selected because:** Recognizes that iTerm2 and Terminal.app share a common mechanism (AppleScript TTY matching) while Ghostty is fundamentally different (AX). The shared infrastructure avoids duplicating the "iterate tabs, match TTY" pattern. This is the most architecturally honest design — it models the actual structure of the problem.

```
TerminalActivator (protocol)
├── GhosttyActivator          — AX tab routing (existing GhosttyAXReader)
└── AppleScriptTTYActivator   — Shared base for TTY-matching terminals
    ├── ITermActivator         — iTerm2-specific AppleScript
    └── TerminalAppActivator   — Terminal.app-specific AppleScript
```

**Concern:** The shared base layer adds a level of indirection. Is the commonality between iTerm2 and Terminal.app AppleScript enough to justify a shared type, or should they just be independent implementations?

### Finalist 3: Approach 3b — TTY Dispatch with Terminal Hint (Enhanced)

Refined to meet the quality bar: each terminal function is robust, well-tested, and thorough — but organized as standalone functions dispatched by a switch, not types behind a protocol.

**Selected because:** The simplest architecture that can be excellent. No protocol overhead. Each function is a self-contained expert on its terminal. The dispatch is a transparent switch on `ParentApp`.

**Concern:** As the number of terminals grows, the switch + functions approach becomes a maintenance tax. No formal extensibility story. Functions living where? A grab-bag file, or scattered across files?

## Key Differentiator

The question that separates the finalists: **Does the terminal abstraction need to be a formal extension point (protocol), or is a well-organized collection of functions sufficient?**

If we're going to support 3 terminals and maybe add 1-2 more over the next year, functions are fine. If terminal support is a core extensibility story (community contributions, plugin-like), a protocol is the right investment.

Given the user's emphasis on engineering quality as a differentiator, **Finalist 2 (Hybrid Protocol + TTY)** best satisfies both the quality and pragmatism requirements. It models the problem accurately (two distinct activation mechanisms: AX and AppleScript-TTY), provides clean extensibility, and avoids the over-engineering that killed previous generations.

## Open Risks

1. **AppleScript reliability** — AppleScript can be slow (~100-500ms) and occasionally hangs. Need timeout handling.
2. **AX permission changes** — macOS tightens AX permissions periodically. Ghostty activation already requires the user to grant AX access.
3. **Terminal API drift** — iTerm2's AppleScript dictionary could change across versions. Terminal.app's is stable (Apple controls it).
4. **Swift 6.2 Sendable** — AppleScript execution involves NSAppleScript which isn't Sendable. Need @unchecked Sendable wrappers or actor isolation.
5. **Testing without terminals** — Unit tests need to mock AppleScript execution. Integration tests need actual terminals running. CI can only do unit tests.
