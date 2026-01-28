# Terminal/Shell State Detection: Test Expansion Plan

**Status:** DONE
**Created:** 2026-01-26
**Completed:** 2026-01-27
**Purpose:** Address gaps identified in the audit and expand test coverage

## Completion Summary

**P1 gaps fixed** in terminal activation hardening (Phase 1-2):
- Tmux client TTY discovery: `display-message -p "#{client_tty}"` in `cwd.rs`
- IDE CLI error handling: `terminationStatus` checks in `TerminalLauncher.swift`
- Tmux switch-client exit codes: proper error propagation

**Manual test matrix** documented: `.claude/docs/terminal-test-matrix.md`

**Deferred:** Additional Rust/Swift unit tests (optional—341 tests + manual matrix provide sufficient coverage)

---

## 1. GAP PRIORITIZATION

### Priority Matrix

| Gap                                       | Risk   | Impact                   | Frequency | Priority |
| ----------------------------------------- | ------ | ------------------------ | --------- | -------- |
| **Tmux client in different terminal app** | Medium | User confusion           | Common    | **P1**   |
| **Multiple tmux clients attached**        | Low    | Wrong terminal activates | Rare      | P3       |
| **IDE CLI not in PATH (silent fail)**     | Medium | No feedback              | Common    | **P1**   |
| **kitty @ returns true unconditionally**  | Low    | Misleading               | Rare      | P3       |
| **IDE terminal after window close**       | Medium | Falls through            | Common    | **P2**   |
| **SSH sessions not detected**             | Low    | No tracking              | Moderate  | P3       |
| **Screen sessions (not tmux)**            | Low    | Not supported            | Rare      | P4       |

### P1 Gaps — Recommend Immediate Fix

#### 1.1 Tmux Client in Different Terminal App

**Scenario:** User has tmux session "work" attached in iTerm, but clicks project in Capacitor while Ghostty is frontmost.

**Current behavior:** `tmux switch-client` succeeds but activates iTerm (where tmux is attached), not Ghostty.

**Expected behavior:** Should activate the terminal app where tmux client is attached.

**Fix location:** `TerminalLauncher.swift:switchToTmuxSessionAndActivate`

**Proposed fix:**

```swift
private func switchToTmuxSessionAndActivate(session: String) {
    if hasTmuxClientAttached() {
        // NEW: Get the TTY of the attached client and activate that terminal
        if let clientTTY = getTmuxClientTTY() {
            activateTerminalByTTYDiscovery(tty: clientTTY)
        }
        runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
    } else {
        launchTerminalWithTmuxSession(session)
    }
}
```

#### 1.2 IDE CLI Not in PATH (Silent Failure)

**Scenario:** User has Cursor but hasn't added CLI to PATH. Clicking project does nothing visible.

**Current behavior:** `try? process.run()` swallows error at `TerminalLauncher.swift:500`

**Fix location:** `TerminalLauncher.swift:activateIDEWindowInternal`

**Proposed fix:** Return success/failure and use fallback strategy.

---

## 2. TEST CASES FOR UNTESTED EDGE CASES

### 2.1 Rust Unit Tests (hud-core)

Add to `core/hud-core/src/state/resolver.rs`:

```rust
#[test]
fn concurrent_sessions_different_states() {
    // Multiple sessions at same path, different states
    // Verify newest active session wins over older ready session
    let temp = tempdir().unwrap();
    let mut store = StateStore::new_in_memory();

    // Create two session-based locks for same path
    create_session_lock(temp.path(), std::process::id(), "/project", "session-1");
    create_session_lock(temp.path(), std::process::id(), "/project", "session-2");

    store.update("session-1", SessionState::Ready, "/project");
    store.update("session-2", SessionState::Working, "/project");

    let resolved = resolve_state_with_details(temp.path(), &store, "/project").unwrap();
    // Should prefer Working over Ready when both have active locks
    assert_eq!(resolved.state, SessionState::Working);
}

#[test]
fn lock_verification_with_pid_reuse() {
    // Verify that proc_started verification detects PID reuse
    let temp = tempdir().unwrap();

    // Create lock with fake proc_started time that doesn't match
    let lock_dir = temp.path().join("fake-session-12345.lock");
    fs::create_dir(&lock_dir).unwrap();
    fs::write(lock_dir.join("pid"), "12345").unwrap();
    fs::write(lock_dir.join("meta.json"), r#"{"pid": 12345, "path": "/project", "proc_started": 1}"#).unwrap();

    // Lock should be considered stale (PID exists but start time doesn't match)
    let info = read_lock_info(&lock_dir);
    // If PID 12345 happens to exist, proc_started verification should fail
    // (unless by astronomical coincidence the process started at timestamp 1)
}

#[test]
fn session_end_releases_only_own_lock() {
    // Verify SessionEnd releases only the specific process's lock
    let temp = tempdir().unwrap();
    let pid1 = std::process::id();
    let pid2 = pid1 + 1; // Simulated different PID

    // Create two locks for same session ID but different PIDs
    // (simulates resumed session in two terminals)
    create_session_lock(temp.path(), pid1, "/project", "shared-session");
    // Can't easily create for pid2 since it might not exist

    // Release only pid1's lock
    release_lock_by_session(temp.path(), "shared-session", pid1);

    // Verify only that specific lock was released
    let lock_path = temp.path().join(format!("shared-session-{}.lock", pid1));
    assert!(!lock_path.exists());
}
```

### 2.2 Integration Test Cases (Manual or Automated)

Create `core/hud-core/tests/terminal_activation_integration.rs`:

```rust
//! Integration tests for terminal activation scenarios.
//!
//! These tests verify the complete flow from project click to terminal activation.
//! Run with: cargo test --test terminal_activation_integration

/// Test: Tmux session exists, client attached in iTerm, user clicks from Ghostty
/// Expected: iTerm window containing tmux should be activated
#[test]
#[ignore] // Manual test - requires specific terminal setup
fn tmux_client_in_different_app() {
    // Setup:
    // 1. Start tmux session "test-session" in iTerm
    // 2. Have Ghostty as frontmost app
    // 3. Run activation for project with tmux pane at that path
    //
    // Verify:
    // - iTerm becomes frontmost (not Ghostty)
    // - tmux switches to correct session
}

/// Test: IDE (Cursor) window closed but terminal still in shell-cwd.json
/// Expected: Should fall through to launch new terminal, not hang
#[test]
#[ignore] // Manual test - requires Cursor
fn ide_window_closed_shell_still_tracked() {
    // Setup:
    // 1. Open Cursor with integrated terminal
    // 2. Navigate to project path in terminal (triggers shell hook)
    // 3. Close Cursor window (but process may still run)
    // 4. Click project in Capacitor
    //
    // Verify:
    // - Does not hang trying to activate closed window
    // - Falls through to launchNewTerminal
}

/// Test: Multiple tmux clients attached to same session
/// Expected: Activates the most recently used client
#[test]
#[ignore] // Manual test - requires multiple terminals
fn multiple_tmux_clients() {
    // Setup:
    // 1. Start tmux session "multi"
    // 2. Attach in iTerm
    // 3. Attach in Terminal.app
    // 4. Use iTerm (make it most recent)
    //
    // Verify:
    // - Clicking project activates iTerm, not Terminal.app
}
```

### 2.3 Swift Unit Tests

Add to `apps/swift/Tests/CapacitorTests/`:

```swift
// TerminalLauncherTests.swift

import XCTest
@testable import Capacitor

final class TerminalLauncherTests: XCTestCase {

    func testFindExistingShellFiltersDeadProcesses() {
        // Create shell state with mix of live and dead PIDs
        let state = ShellCwdState(
            version: 1,
            shells: [
                "1": ShellEntry(cwd: "/project", tty: "/dev/ttys000", parentApp: "iterm2", tmuxSession: nil, tmuxClientTty: nil, updatedAt: Date()),
                "999999": ShellEntry(cwd: "/project", tty: "/dev/ttys001", parentApp: "iterm2", tmuxSession: nil, tmuxClientTty: nil, updatedAt: Date())
            ]
        )

        // PID 1 (launchd) is always alive, 999999 should be dead
        // Verify dead PIDs are filtered out
    }

    func testTmuxShellsPreferredOverNonTmux() {
        // When both tmux and non-tmux shells exist for same project,
        // tmux should be preferred for more reliable activation
    }

    func testExactPathMatchOnly() {
        // Verify that child paths don't match parent projects
        // /project/src should NOT activate terminal for /project
    }
}

// ActiveProjectResolverTests.swift

final class ActiveProjectResolverTests: XCTestCase {

    func testManualOverridePersistsWithoutActiveLock() {
        // User clicks project A
        // Shell navigates to project B (no Claude session)
        // Verify: Override persists, A stays highlighted
    }

    func testManualOverrideClearsWithActiveLock() {
        // User clicks project A
        // Shell navigates to project B (WITH active Claude session)
        // Verify: Override cleared, B becomes highlighted
    }

    func testActiveSessionsPreferredOverReady() {
        // Project A: Ready state, recent timestamp
        // Project B: Working state, older timestamp
        // Verify: B selected (Working > Ready regardless of timestamp)
    }
}
```

---

## 3. RECOMMENDATION: TESTING APPROACH

### Verdict: **Hybrid Approach**

| Test Type              | Coverage       | Rationale                                    |
| ---------------------- | -------------- | -------------------------------------------- |
| **Rust unit tests**    | Core logic     | Lock management, state resolution, staleness |
| **Swift unit tests**   | UI integration | Shell filtering, activation strategies       |
| **Manual test matrix** | End-to-end     | Real terminal apps, tmux interactions        |

### Why Not Full Automation?

1. **Terminal activation requires real apps**: Can't mock `NSWorkspace.shared.runningApplications`
2. **Tmux state is system-global**: Tests would interfere with user's actual tmux
3. **AppleScript interactions**: Can't reliably mock OS-level scripting

### Recommended Test Matrix (Manual)

Maintain a manual test matrix in `.claude/docs/terminal-test-matrix.md` for:

- Terminal app combinations (Ghostty, iTerm, Terminal, Warp, kitty)
- Tmux scenarios (attached, detached, multiple clients)
- IDE terminal scenarios (Cursor, VS Code)

Run before releases.

---

## 4. IMPLEMENTATION CHECKLIST

### Phase 1: Add Rust Tests (1-2 hours)

- [ ] Add `concurrent_sessions_different_states` test
- [ ] Add `session_end_releases_only_own_lock` test
- [ ] Run `cargo test` to verify

### Phase 2: Add Swift Tests (2-3 hours)

- [ ] Create `TerminalLauncherTests.swift`
- [ ] Create `ActiveProjectResolverTests.swift`
- [ ] Run `swift test` to verify

### Phase 3: Fix P1 Gaps (2-3 hours)

- [ ] Fix tmux client TTY discovery in `switchToTmuxSessionAndActivate`
- [ ] Add error handling to `activateIDEWindowInternal`
- [ ] Update strategy fallback behavior

### Phase 4: Document Manual Test Matrix (1 hour)

- [ ] Create `.claude/docs/terminal-test-matrix.md`
- [ ] Document pre-release test procedures

---

## 5. SUCCESS CRITERIA

- [ ] All new Rust tests pass
- [ ] All new Swift tests pass
- [ ] P1 gaps have fixes with tests
- [ ] Manual test matrix documented
- [ ] No regressions in existing functionality
