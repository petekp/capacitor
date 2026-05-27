# Status Projection Process Evidence Hardening

Date: 2026-05-26

## Scenario

Active Claude Code sessions should stay visible as `Ready`, but unrelated Claude-looking processes must not make a Project look alive. This matters because live process evidence is used as a Swift-side fallback when runtime state is idle or missing.

## Product Policy

- A real Claude CLI process with a current working directory inside a known Project can count as live cockpit evidence.
- Claude Desktop helpers, shell command text mentioning `claude`, search commands, missing cwd, and cwd outside the Project must not count.
- This remains a Swift projection concern. Rust keeps durable runtime truth; Swift uses live macOS process evidence only to avoid hiding real operator cockpits.

## Source Changes

- `apps/swift/Tests/CapacitorTests/WorkBatchClaudeProcessScannerTests.swift`
  - Added coverage that Claude Desktop helpers, `zsh -lc claude`, and `rg claude` do not create project process evidence.
  - Added coverage that a Claude CLI process without cwd, or outside the Project root, does not create project process evidence.

No production code changed in this step because the scanner already followed the intended policy.

## Verification

Passed:

```bash
swift test --package-path apps/swift --filter WorkBatchClaudeProcessScannerTests
```

Result:

- 5 `WorkBatchClaudeProcessScannerTests` passed.

## Remaining Risk

- Process evidence still cannot prove whether Claude is idle at a prompt versus actively working. That is acceptable for top-level visibility because it prevents live manual cockpits from being buried as `Idle`, but safe task wakeup still requires runtime-backed `ready` evidence.
