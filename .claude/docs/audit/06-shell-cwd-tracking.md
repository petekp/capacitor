# Session 6: Shell CWD Tracking Audit

**Date:** 2026-01-26
**Files Analyzed:** `core/hud-hook/src/cwd.rs`, `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift`, `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift`
**Focus:** PID tracking, dead shell cleanup, Rust↔Swift data flow

---

## Executive Summary

The shell CWD tracking system is **well-designed and robust**. Key strengths:
- Atomic file writes prevent corruption
- Graceful error handling with self-healing state
- Correct PID liveness checks using POSIX `kill(pid, 0)`
- Synchronized string representations between Rust and Swift

One **medium-severity race condition** exists but is acceptable in practice due to the self-healing nature of the state.

---

## Architecture Overview

```
┌─────────────────┐      ┌────────────────────┐      ┌─────────────────┐
│  Shell precmd   │─────▶│    hud-hook cwd    │─────▶│ shell-cwd.json  │
│  (bash/zsh)     │      │    (Rust binary)   │      │ ~/.capacitor/   │
└─────────────────┘      └────────────────────┘      └────────┬────────┘
                                                              │
                         ┌────────────────────┐               │ reads
                         │  ShellStateStore   │◀──────────────┘
                         │  (Swift, polling)  │
                         └────────┬───────────┘
                                  │
                         ┌────────▼───────────┐
                         │  TerminalLauncher  │
                         │  (uses ParentApp)  │
                         └────────────────────┘
```

---

## Analysis Checklist Results

### 1. Correctness ✅

The code correctly implements what the documentation promises:
- Updates `~/.capacitor/shell-cwd.json` with shell state on each precmd hook
- Appends to `~/.capacitor/shell-history.jsonl` only when CWD changes
- Cleans up dead PIDs synchronously on each invocation

**Evidence:** `run()` function at `cwd.rs:99-132`

### 2. Atomicity ✅

File writes use the correct atomic pattern:
1. Create temp file in same directory (`NamedTempFile::new_in`)
2. Write content
3. Sync to disk (`sync_all`)
4. Rename atomically (`persist`)

**Evidence:** `write_state_atomic()` at `cwd.rs:174-184`

### 3. Race Conditions ⚠️

**Finding 1: TOCTOU Race in State Updates**

**Severity:** Medium
**Type:** Race condition
**Location:** `cwd.rs:107-118`

**Problem:**
Concurrent `hud-hook cwd` invocations can cause lost updates:

```
Time 0: Shell A reads state {pid1, pid2}
Time 1: Shell B reads state {pid1, pid2}
Time 2: Shell A writes {pid1, pid2, pidA}
Time 3: Shell B writes {pid1, pid2, pidB}  ← pidA lost!
```

**Mitigation:**
This is **acceptable** because:
1. Each shell re-reports its state on the next precmd
2. `cleanup_dead_pids()` eventually removes stale entries
3. The state is self-healing within one shell interaction

**Recommendation:**
Document this limitation in the module docstring. No code change needed.

### 4. Cleanup ✅

Resources are properly released:
- `NamedTempFile` auto-deletes on error (Rust RAII)
- `BufWriter` is explicitly flushed before scope exit
- No leaked file handles

### 5. Error Handling ✅

Failures leave the system in a valid state:
- `load_state()` returns empty state on parse errors (`cwd.rs:168-171`)
- History append errors are logged but don't fail the operation (`cwd.rs:121`)
- History cleanup errors are logged but don't fail (`cwd.rs:237`)

### 6. Documentation Accuracy ✅

All comments match behavior:
- Safety comments for unsafe blocks are accurate
- Module docstring correctly describes functionality
- Target performance (<15ms) is reasonable given the design

### 7. Dead Code ✅

No significant dead code found. The `HistoryEntry` struct is only used for deserialization, which is intentional.

---

## Rust ↔ Swift String Synchronization

### ParentApp Values

The `KNOWN_APPS` array in `cwd.rs:348-366` maps process names to `ParentApp` variants:

| Process Name | Rust Variant | Serde JSON | Swift Init Match |
|--------------|--------------|------------|------------------|
| "Ghostty" | Ghostty | "ghostty" | ✅ "ghostty" |
| "iTerm2" | ITerm | "iterm2" | ✅ "iterm2" |
| "Terminal" | Terminal | "terminal" | ✅ "terminal" |
| "Alacritty" | Alacritty | "alacritty" | ✅ "alacritty" |
| "kitty" | Kitty | "kitty" | ✅ "kitty" |
| "WarpTerminal" | Warp | "warp" | ✅ "warp" |
| "Cursor" | Cursor | "cursor" | ✅ "cursor" |
| "Code" | VSCode | "vscode" | ✅ "vscode" |
| "Code - Insiders" | VSCodeInsiders | "vscode-insiders" | ✅ "vscode-insiders" |
| "Zed" | Zed | "zed" | ✅ "zed" |
| "tmux" | Tmux | "tmux" | ✅ "tmux" |

**Conclusion:** All strings are synchronized. The Rust `#[serde(rename = "...")]` attributes and Swift `init(fromString:)` cases match perfectly.

### Timestamp Handling

**Rust writes:** `Utc::now().to_rfc3339()` → `2026-01-26T10:30:00.123456789+00:00`

**Swift reads:** Custom decoder with `.withFractionalSeconds` option (`ShellStateStore.swift:66`)

**Gotcha documented in CLAUDE.md:** ✅ Already noted.

---

## Performance Considerations

### Dead PID Cleanup Latency

`cleanup_dead_pids()` runs synchronously on every invocation (`cwd.rs:117`), checking each tracked shell with `kill(pid, 0)`.

**Worst case:** 20 shells × 1 syscall = 20 syscalls ≈ <1ms

This is acceptable for the 15ms target.

### Parent App Detection Chain

`detect_parent_app()` walks up to 20 parent processes (`MAX_PARENT_CHAIN_DEPTH`), making 2 syscalls per level.

**Worst case:** 20 levels × 2 syscalls = 40 syscalls ≈ 2-5ms

Most shells are only 3-5 levels from the terminal, so typical case is <1ms.

### History Cleanup Probability

`CLEANUP_PROBABILITY = 0.01` means history cleanup runs ~1% of invocations. This is a good optimization—cleanup is expensive (reads entire file, filters, rewrites) but infrequent.

---

## Swift Side Analysis

### ShellStateStore.swift

**Polling Design:**
Polls `shell-cwd.json` every 500ms (`Constants.pollingIntervalNanoseconds`). This is appropriate—no file system events needed for this update frequency.

**Staleness Threshold:**
Shells not updated within 10 minutes are considered stale (`shellStalenessThresholdSeconds = 600`). This is reasonable for filtering abandoned shell sessions.

**Finding 2: Silent Parse Failures**

**Severity:** Low
**Type:** Design choice (not a bug)
**Location:** `ShellStateStore.swift:76-77`

**Observation:**
JSON decode failures are silently ignored:
```swift
guard let decoded = try? decoder.decode(ShellCwdState.self, from: data) else {
    return  // Silent failure
}
```

This is acceptable because:
1. The Rust side uses atomic writes, so corruption is unlikely
2. Next poll will retry
3. No user-facing impact

### TerminalLauncher.swift

**Double PID Check:**
Both Rust (`cleanup_dead_pids`) and Swift (`isLiveShell`) validate PIDs. This redundancy is correct—Swift should not trust stale JSON state.

**Evidence:** `TerminalLauncher.swift:248-251`

---

## Cross-Reference with CLAUDE.md Gotchas

| Gotcha | Verified in Code |
|--------|------------------|
| "Swift timestamp decoder needs .withFractionalSeconds" | ✅ `ShellStateStore.swift:66` |
| Shell CWD tracking mentioned in State Tracking section | ✅ Documented state file location |

---

## Recommendations

### No Action Required

1. **TOCTOU race** — Self-healing design makes this acceptable
2. **Silent parse failures** — Correct design for this use case
3. **Performance** — Within 15ms target

### Documentation Updates

1. Add race condition note to `cwd.rs` module docstring:
   ```rust
   //! Note: Concurrent writes may briefly lose shell entries, but the state
   //! is self-healing as each shell re-reports on its next precmd.
   ```

### Future Considerations

1. **File locking** — If race conditions become problematic, consider `flock()` on the state file. Not needed currently.
2. **fsnotify instead of polling** — Could reduce Swift CPU usage, but 500ms polling is already lightweight.

---

## Summary

| Checklist Item | Status | Notes |
|----------------|--------|-------|
| Correctness | ✅ Pass | Code matches documentation |
| Atomicity | ✅ Pass | Proper temp file + rename pattern |
| Race Conditions | ⚠️ Acceptable | TOCTOU exists but self-heals |
| Cleanup | ✅ Pass | RAII handles all cases |
| Error Handling | ✅ Pass | Graceful degradation |
| Documentation | ✅ Pass | Comments are accurate |
| Dead Code | ✅ Pass | No unused code paths |

**Overall Assessment:** The shell CWD tracking system is production-ready with no critical issues.
