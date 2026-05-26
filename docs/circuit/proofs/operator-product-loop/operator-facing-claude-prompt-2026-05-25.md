# Operator-Facing Claude Prompt Hardening - 2026-05-25

## Scope

This pass takes the next small product step toward Capacitor as the operator cockpit: Work Batch Claude Code sessions should not expose internal governance instructions as the visible terminal prompt.

The user-facing rule is simple:

- Capacitor can tell Claude how to honor queued Tasks, claims, Done reports, and Checkpoints.
- The human should see short status language like `Assessing tasks...`, not the machinery behind the Work Batch protocol.

This stayed inside the current Claude Code, Ghostty, tmux, Swift/Rust boundary. No old Circuit runtime, runner, flow engine, task DAG, broad memory platform, new terminal/editor, or generalized multi-host abstraction was added.

## Source-Backed Change

- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:234` adds `appendedSystemPromptFile` to `ClaudeCodeTaskSessionLaunchRequest`.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:266` puts the appended system prompt arguments before the visible prompt.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:293` prefers `--append-system-prompt-file` and keeps `--append-system-prompt` as a fallback.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:481` starts new Work Batch Claude sessions with `.capacitor/work-batch-agent-instructions.md` as the hidden instruction file and `Assessing tasks...` as the visible prompt.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:502` resumes stale/existing Work Batch sessions with the same instruction file and `Assessing updated tasks...` as the visible prompt.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:591` wakes already-visible sessions with only `Assessing updated tasks...`.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:647` defines the short operator-facing initial and resume prompts.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:655` keeps the actual Work Batch contract in `agentInstructionsPrompt`.
- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:669` writes `.capacitor/work-batch-agent-instructions.md` into the batch worktree and installs Capacitor metadata ignore rules first.

## CLI Capability Evidence

Local Claude Code help exposes `--append-system-prompt <prompt>`.

Local installed Claude Code implementation and cached CLI metadata also expose `--append-system-prompt-file <file>`, and the help text references `--system-prompt[-file]` and `--append-system-prompt[-file]` in bare-mode behavior.

This is enough evidence to use the file form for local launch/resume requests while keeping the string form as a fallback in the launch request type.

## Test Coverage

- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:46` checks the initial visible prompt is one line, operator-facing, and does not mention the context mirror, Task claims, Done reports, or Checkpoints.
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:59` checks the same property for resume prompts.
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:72` checks the hidden instruction prompt still carries the Work Batch contract.
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:85` checks `--append-system-prompt-file` is placed before the visible prompt.
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:645` checks a new Work Batch launch writes the instruction file, uses `--append-system-prompt-file`, omits `Task claim` from the visible launch script, and includes `Assessing tasks...`.
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:631` checks related queued Tasks wake an existing live binding without launching a new session and use only `Assessing updated tasks...`.
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:1017` checks stale resume launches include the instruction file, hide the Task-claim wording from the visible script, and keep the short visible prompt.

## Verification

Focused and broader Swift verification passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatchTaskSessionTests|WorkBatchAutoRouterTests|WorkBatchDeliveryPolicyTests|TerminalLauncherTests|GhosttyTerminalDriverTests|GhosttyAutomationClientTests'
```

Result:

- 128 tests passed.
- 0 failures.

Full Swift verification passed:

```bash
swift test --package-path apps/swift
```

Result:

- 906 tests executed.
- 1 test skipped.
- 0 failures.

Diff hygiene passed on the touched source/test files:

```bash
git diff --check -- apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift
```

## Manual Verification Status

Live UI verification was not completed in this pass because the desktop was still covered by the macOS lock screen. A screenshot check produced a black/locked display image, so physical clicking would not be honest evidence.

The next live check after unlocking should verify:

1. Add or route a Task into a new Work Batch.
2. Confirm the Claude Code session opens with only `Assessing tasks...` visible, while still reading the Work Batch context and writing claim/Done/Checkpoint artifacts.
3. Add a related Task into an existing live Work Batch.
4. Confirm the existing cockpit receives only `Assessing updated tasks...`, not the internal Work Batch instructions.
5. Confirm no unnecessary new Ghostty or Claude session appears.
