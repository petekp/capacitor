# Hook Runtime Capability Matrix

Status: Proposed  
Date checked against Claude docs: 2026-03-09  
Source: [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)

## How To Read This

This matrix is not the current implementation. It is the proposed decision input for the migration target.

Columns:

1. `Claude transports`: what Claude currently documents as supported.
2. `Product importance`: how damaging it is if Capacitor loses the signal.
3. `Target policy`: how the blank-slate architecture should treat the signal.
4. `Primary source`: what we intend to trust first.
5. `Fallback`: weaker corroborating source if the primary is missing.

## Event Matrix

| Event | Claude transports | Product importance | Why it matters | Target policy | Primary source | Fallback |
|------|-------------------|--------------------|----------------|---------------|----------------|----------|
| `SessionStart` | `command` | High | Establishes early session existence and startup context | Keep | command forwarder | passive reconciliation |
| `InstructionsLoaded` | `command` | Low | Mostly useful as context/config signal, not core lifecycle | Optional in first migration | command forwarder if adopted | none |
| `UserPromptSubmit` | `command`, `http`, `prompt`, `agent` | Critical | Strong working-state signal | Keep | HTTP | command forwarder |
| `PreToolUse` | `command`, `http`, `prompt`, `agent` | Critical | Strong working-state and tool-activity signal | Keep | HTTP | command forwarder |
| `PermissionRequest` | `command`, `http`, `prompt`, `agent` | Critical | Strong waiting-state signal | Keep | HTTP | command forwarder |
| `PostToolUse` | `command`, `http`, `prompt`, `agent` | Critical | Tool completion, file activity, continued working signal | Keep | HTTP | command forwarder |
| `PostToolUseFailure` | `command`, `http`, `prompt`, `agent` | High | Failure activity and continued working signal | Keep | HTTP | command forwarder |
| `Notification` | `command` | Critical | Drives ready/waiting transitions like `idle_prompt`, `permission_prompt`, `elicitation_dialog` | Keep | command forwarder | passive reconciliation |
| `Stop` | `command`, `http` | High | Explicit stop/ready transition and loop guard behavior | Keep | HTTP | command forwarder |
| `SubagentStart` | `command` | Medium | Useful for richer agent graph views, less critical for main routing | Keep as passive/high-fidelity signal | command forwarder | none |
| `SubagentStop` | `command`, `http` | Medium | Needed for accurate subagent accounting and parent isolation | Keep | HTTP | command forwarder |
| `PreCompact` | `command` | Medium | Useful for compacting state and UX confidence | Keep | command forwarder | none |
| `TeammateIdle` | `command` | Low | Nice-to-have visibility into teammates, not core session truth | Defer or ingest as passive-only | command forwarder if adopted | none |
| `TaskCompleted` | `command`, `http` | High | Helpful ready-state signal for main-agent completions | Keep | HTTP | command forwarder |
| `ConfigChange` | `command` | Low | Operational/config awareness, not core dashboard state | Defer or passive-only | command forwarder if adopted | none |
| `SessionEnd` | `command` | Critical | Cleanup and end-of-session correctness | Keep | command forwarder | process liveness + passive reconciliation |
| `WorktreeCreate` | `command` | Medium | Important for worktree-aware product flows | Keep as non-lifecycle observation | command forwarder | passive scan |
| `WorktreeRemove` | `command` | Medium | Important for cleanup and worktree-aware UX | Keep as non-lifecycle observation | command forwarder | passive scan |

## Product Interpretation

### Critical signals

These should be treated as must-have for truthfulness:

1. `UserPromptSubmit`
2. `PreToolUse`
3. `PermissionRequest`
4. `PostToolUse`
5. `Notification`
6. `SessionEnd`

### High-value signals

These materially improve correctness and user confidence:

1. `SessionStart`
2. `PostToolUseFailure`
3. `Stop`
4. `TaskCompleted`

### Lower-priority signals

These are useful, but not worth distorting the architecture around unless they materially support product goals:

1. `InstructionsLoaded`
2. `SubagentStart`
3. `SubagentStop`
4. `PreCompact`
5. `TeammateIdle`
6. `ConfigChange`
7. `WorktreeCreate`
8. `WorktreeRemove`

## Recommended Policy

### Policy 1

Do not force one transport type across all events.

The external contract is mixed. The architecture should reflect that explicitly.

### Policy 2

Use HTTP for the hot path.

The HTTP-capable events are the ones most likely to fire frequently and drive visible state changes. Those should use a warm local service boundary.

### Policy 3

Use command only for coverage gaps.

Command transport should exist to cover command-only events, not as a second place where product logic lives.

### Policy 4

Treat shell context as a parallel observation source, not a fallback transport for Claude hooks.

Shell signals solve routing attribution. Claude hooks solve agent lifecycle. They inform one another but should remain distinct source kinds.

## Capability Matrix Implications

This matrix leads directly to these architecture decisions:

1. We cannot honestly claim "pure HTTP" without reducing event coverage.
2. We cannot honestly claim "one hook path" if that means one transport type for every event.
3. We can still achieve one policy path by normalizing all transports into the same observation model.

## Machine-Checkable Artifact

This matrix now has a checked-in code artifact in:

1. [runtime_contracts/mod.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_contracts/mod.rs)
2. [runtime_contracts/claude_hooks.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_contracts/claude_hooks.rs)

The markdown table remains the human-readable design reference. The Rust artifact is the executable contract.

## What Must Stay Versioned In-Repo

Suggested fields:

1. event name
2. allowed transports
3. required payload fields
4. blocking capability
5. product importance
6. target enabled/disabled policy
7. replay scenario coverage

That artifact should drive:

1. installer generation
2. health validation
3. contract tests
4. migration denylist updates
