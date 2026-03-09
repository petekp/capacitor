# Terminal Activation Manual QA Report

- Date (UTC):
- Tester:
- Build/Commit:
- Environment: macOS version, terminal app(s), tmux version, Ghostty AX/TCC state
- Canonical UX contract: `.claude/docs/terminal-activation-ux-spec.md`

## Scope

Use this template when the release changes:

- terminal activation behavior
- tmux session switching
- Ghostty AX tab routing
- terminal focus recovery or managed-TTY logic

## Preflight

Run:

```bash
./scripts/dev/agent-observe.sh paths
./scripts/dev/agent-observe.sh snapshot
```

If you need fresh-install or clean-state evidence, also run:

```bash
./scripts/dev/reset-for-testing.sh
```

## Scenario Results

- S1:
- S2:
- S3:
- S4:
- S5:
- S6:
- S7:
- S8:
- S9:
- S10:

## Required Evidence

- App log path:
- Snapshot path:
- Routing snapshot used:
- Terminal app under test:
- Managed TTY before action:
- Managed TTY after action:

## Log Capture

Use a separate terminal while reproducing:

```bash
./scripts/dev/agent-observe.sh tail app
```

Helpful follow-up commands:

```bash
./scripts/dev/agent-observe.sh routing-snapshot <project_path>
cd apps/swift && swift test --filter 'TerminalLauncherTests|GhosttyAXReaderTests'
```

## Expected Behavioral Checks

- No unexpected new terminal windows or tabs in reuse-eligible flows
- Existing detached tmux sessions auto-attach instead of launching fresh surfaces
- Latest click wins under rapid repeated interactions
- Ghostty routing prefers deterministic tab focus when possible
- Fallback routes are explainable from app-log evidence

## Notes / Triage

- Unexpected behavior:
- Reproduction steps:
- Matching log lines:
- Follow-up owner:
- Risk acceptance note:
