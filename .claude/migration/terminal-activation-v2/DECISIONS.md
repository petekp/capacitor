# Terminal Activation v2 Decisions

Append-only. Reversals are new entries that reference the superseded decision.

---

## D-001: Unified Swift-side flow over Rust-driven dispatch

**Date:** 2026-03-01
**Context:** The v1 model had Rust resolve an ActivationActionKind, then Swift dispatch to separate handlers (switchTmuxSession, ensureTmuxSession, launchNewTerminal). This caused mismatches — Rust would say "switch" but Swift had no matching tab for the target session.
**Decision:** One unified Swift flow: resolve client → ensure session + switch → focus. Rust resolver retained for telemetry only.
**Rationale:** Swift has the real-time state (managed TTY, Ghostty AX tree). Letting Swift drive the decision tree eliminates the mismatch between Rust's snapshot-based decision and runtime reality.

## D-002: Managed-TTY affinity as stored state

**Date:** 2026-03-01
**Context:** TTY values were transient locals passed through method parameters. No persistence across card clicks.
**Decision:** Add `managedClientTty: String?` as a stored property on TerminalLauncher. Cleared when stale, updated when adopting a new client.
**Rationale:** The spec (B6) requires remembering which TTY Capacitor uses. Without persistence, every card click re-resolves from scratch, which can adopt wrong clients.

## D-003: Session-swap not tab-spawn

**Date:** 2026-03-01
**Context:** Old code opened new Ghostty tabs for new projects. User confirmed: one tab, swap sessions within it.
**Decision:** Card clicks always use `tmux switch-client -c <tty> -t <session>`. New tabs only created when zero tmux clients exist.
**Rationale:** Multiple tabs per project creates cognitive overhead and window clutter. Session swapping is tmux's native multi-project model.

## D-004: Keep ActivationActionExecutor during migration, delete in final slice

**Date:** 2026-03-01
**Context:** ActivationActionExecutor has dedicated tests and is referenced from TerminalLauncher.
**Decision:** Don't delete ActivationActionExecutor until the unified flow is fully wired and tested. Final slice removes it.
**Rationale:** Incremental migration — keep old paths working until new paths are proven, then delete atomically.
