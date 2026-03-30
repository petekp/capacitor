# Session Forking Guide

How to use Claude Code session forking during Capacitor development.

## When to Fork

Fork a session when you hit a decision point where two or more approaches
are viable and the best way to evaluate them is to try both:

- **Competing repair strategies** — a failing test could be fixed by patching
  the Rust core or adjusting the Swift-side projection. Fork, try each, compare.
- **Review checkpoint divergence** — during a circuit review step, if the reviewer
  suggests a fundamentally different approach, fork to prototype it without
  discarding the original work.
- **Cross-boundary experiments** — when a change could live in Rust or Swift,
  fork to spike each side and measure which is cleaner.
- **Risky refactors** — before a large refactor, fork the session. If the refactor
  goes sideways, the original session still has clean context.

## When NOT to Fork

- **Sequential work** — if steps must happen in order, forking adds overhead
  without parallelism.
- **Trivial decisions** — if the choice is obvious, just pick one and go.
- **Long-running implementation** — use worktrees + separate sessions instead.
  Forks share context but can't write to isolated directories.

## How to Fork

### From inside a session

```
/branch
```

This creates a new session with the full conversation context duplicated.
Both sessions can proceed independently.

### From the CLI (resume + fork)

```bash
claude --resume <session-id> --fork-session
```

Useful when you want to fork a session you're not currently in — e.g., a
long-running worker session that hit a decision point.

### From Desktop

Use the **Fork** button in the session header.

## Capacitor-Specific Patterns

### Pattern 1: Repair Fork

When a bug could be fixed at either the Rust core or Swift UI layer:

```
[main session] → diagnose bug, identify two fix locations
  ├── /branch → [fork A] fix in Rust core (core/capacitor-core/src/)
  └── [main]  → fix in Swift (apps/swift/Sources/Capacitor/)
```

Compare which fix is cleaner, has better test coverage, and doesn't
violate architecture boundaries. Discard the worse approach.

### Pattern 2: Review Divergence Fork

During a circuit:develop ship review (Step 10), if findings suggest a
fundamentally different approach:

```
[main session] → review says "ISSUES FOUND" with alternative approach
  ├── /branch → [fork] implement reviewer's alternative
  └── [main]  → address findings within original approach
```

### Pattern 3: Pre-Refactor Safety Fork

Before touching shared infrastructure (UniFFI boundary, runtime service):

```
[main session] → about to refactor runtime_service/
  ├── /branch → [fork] attempt the refactor
  └── [main]  → preserved clean context if refactor fails
```

If the fork succeeds, continue there. If it fails, the main session still
has full context to try a different approach.

## Integration with Agents

Forking works well with custom agents. You might:

1. Start in a general session
2. Hit a decision about whether a fix belongs in Rust or Swift
3. Fork: one session uses `claude --agent=rust-core`, the other `claude --agent=swift-ui`
4. Compare outcomes

## Rules

1. **Label your forks** — when you fork, immediately state what this fork is
   testing (e.g., "This fork tests the Rust-side fix for the projection bug").
2. **Time-box experiments** — forks for exploration should be short. If you're
   spending more than 30 minutes, you probably need a worktree, not a fork.
3. **Don't fork forks** — one level of forking is enough. If you need more
   parallelism, use worktrees or `/batch`.
4. **Discard cleanly** — when a fork's approach loses, let it go. Don't try
   to merge context back.
