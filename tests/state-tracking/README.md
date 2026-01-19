# State Tracking Test Suite

Tests for the Claude Code session state tracking system. Run these tests whenever making changes to state tracking code.

## Components Under Test

1. **Hook Script** (`~/.claude/scripts/hud-state-tracker.sh`)
2. **Lock System** (`~/.claude/sessions/*.lock/`)
3. **Rust Core** (`core/hud-core/src/sessions.rs`)

## Running Tests

```bash
# Run all state tracking tests (recommended)
./tests/state-tracking/run-all.sh

# Run specific test suites
./tests/state-tracking/test-hook-events.sh      # Hook event handling (13 tests)
./tests/state-tracking/test-lock-system.sh      # Lock creation/cleanup (8 tests)
cargo test -p hud-core sessions::tests          # Rust unit tests (14 tests)
```

## Test Coverage Matrix

| Scenario | Hook | Lock | Rust |
|----------|------|------|------|
| SessionStart → ready | ✓ | | |
| UserPromptSubmit → working | ✓ | | |
| UserPromptSubmit → thinking=true | ✓ | | |
| Stop → ready | ✓ | | |
| Stop → thinking=false | ✓ | | |
| SessionEnd → idle | ✓ | | |
| PreCompact (auto) → compacting | ✓ | | |
| PreCompact (manual) → no change | ✓ | | |
| PostToolUse from compacting → working | ✓ | | |
| Notification (idle_prompt) → ready | ✓ | | |
| PermissionRequest → no change | ✓ | | |
| Stop with stop_hook_active → ignored | ✓ | | |
| State file corruption recovery | ✓ | | |
| Lock directory created on UserPromptSubmit | | ✓ | |
| Lock contains pid file | | ✓ | |
| Lock contains meta.json | | ✓ | |
| Stale lock detection (dead PID) | | ✓ | ✓ |
| Lock cleanup on process exit | | ✓ | |
| Concurrent lock protection | | ✓ | |
| Hash consistency | | ✓ | ✓ |
| Hash uniqueness | | ✓ | ✓ |
| is_session_active with dead PID | | | ✓ |
| is_session_active with current PID | | | ✓ |
| is_session_active without lock | | | ✓ |
| is_session_active with empty PID | | | ✓ |
| is_session_active with invalid PID | | | ✓ |
| detect_session_state for unknown | | | ✓ |
| get_all_session_states (empty) | | | ✓ |
| get_all_session_states (multiple) | | | ✓ |
| ProjectStatus serialization | | | ✓ |

## Test Isolation

Tests use in-memory backup/restore to avoid corrupting the real `~/.claude/hud-session-states-v2.json`. The original state is captured before tests and restored after, even if tests fail.

## Prerequisites

- `jq` - JSON processor (install with `brew install jq`)
- `cargo` - Rust toolchain
- Hook script installed at `~/.claude/scripts/hud-state-tracker.sh`
