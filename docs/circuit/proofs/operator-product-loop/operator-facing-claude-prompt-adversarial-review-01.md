# Operator-Facing Claude Prompt Adversarial Review 01 - 2026-05-25

## Scope

Reviewed the prompt-hardening slice in:

- `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `docs/circuit/proofs/operator-product-loop/operator-facing-claude-prompt-2026-05-25.md`

## Findings

No medium, high, or critical findings.

## Low Residual Risks

1. [Low] `--append-system-prompt-file` is less visible in top-level Claude help than `--append-system-prompt`.
   - Evidence: local help exposes `--append-system-prompt`; local installed CLI/cache metadata also exposes `--append-system-prompt-file`.
   - Why low: the current local Claude Code implementation supports the file flag, launch arguments are unit-tested, and the string prompt fallback remains in the request type.
   - Follow-up: live launch verification after unlocking should confirm the local CLI accepts the file flag in the real app path.

2. [Low] Waking an already-running visible session cannot append a new hidden system prompt.
   - Evidence: `wakeExistingSession` injects terminal input into an existing cockpit, so it sends only `Assessing updated tasks...`.
   - Why low: new and resumed sessions launched through Capacitor receive the instruction file. Existing older cockpits may retain older inline instructions, and the visible wake prompt is now short.
   - Follow-up: after old Work Batch cockpits age out, verify all newly-created cockpits carry the hidden instruction file.

3. [Low] Live UI verification is blocked by the locked desktop.
   - Evidence: screenshot checks could not access the active Capacitor/Ghostty windows.
   - Why low for this slice: source and automated tests prove the command construction and generated instruction file behavior. The remaining live check is visual confirmation of the actual terminal wording.

## Checks Reviewed

```bash
swift test --package-path apps/swift --filter 'WorkBatchTaskSessionTests|WorkBatchAutoRouterTests|WorkBatchDeliveryPolicyTests|TerminalLauncherTests|GhosttyTerminalDriverTests|GhosttyAutomationClientTests'
swift test --package-path apps/swift
git diff --check -- apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift
```

Results:

- Broader focused Swift slice: 128 tests passed, 0 failures.
- Full Swift: 906 tests executed, 1 skipped, 0 failures.
- Diff check passed on the touched source/test files.

## Verdict

The slice is sound enough to build on. It improves the operator experience without changing the Work Batch protocol, terminal driver scope, or Swift/Rust ownership boundary.
