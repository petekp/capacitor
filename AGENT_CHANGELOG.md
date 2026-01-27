# Agent Changelog

> This file helps coding agents understand project evolution, key decisions,
> and deprecated patterns. Updated: 2026-01-27 (Session 3)

## Current State Summary

Capacitor is a native macOS SwiftUI app (Apple Silicon, macOS 14+) that acts as a sidecar dashboard for Claude Code. The architecture uses a Rust core (`hud-core`) with UniFFI bindings to Swift. State tracking relies on Claude Code hooks that write to `~/.capacitor/`, with session-based locks (`{session_id}-{pid}.lock`) as the authoritative signal for active sessions. Shell integration provides ambient project awareness via precmd hooks. Hooks run asynchronously to avoid blocking Claude Code execution. All file I/O uses `fs_err` for enriched error messages, and structured logging via `tracing` writes to `~/.capacitor/hud-hook-debug.{date}.log`. **Bulletproof Hooks complete:** Phase 4 Test Hooks button added for manual verification. **Audit complete:** A comprehensive 12-session side-effects analysis validated all major subsystems.

## Stale Information Detected

None currently. Last audit: 2026-01-27 (fixed v3→v4 documentation in state modules, hud-hook audit remediation).

## Timeline

### 2026-01-27 — Test Hooks Button (Bulletproof Hooks Phase 4)

**What changed:**
1. Added `HookTestResult` struct to Rust types with UniFFI export
2. Added `run_hook_test()` method to HudEngine (FFI-exported)
3. Added "Test Hooks" button to SetupStatusCard UI
4. Button verifies hooks via heartbeat + state file I/O verification

**Test approach:**
- Heartbeat check: Is the heartbeat file recent (< 60s)?
- State file I/O: Can we write/read/delete a test record in sessions.json?

**Why:** Gives users confidence that the hook system is working. No subprocess spawn needed—tests what actually matters (file I/O, not binary execution).

**Agent impact:**
- `run_hook_test()` in engine.rs returns `HookTestResult` (success, heartbeat_ok, state_file_ok, message)
- SetupStatusCard now has callback pattern: `onTest: () -> HookTestResult`
- Test result auto-clears after 5 seconds
- Use PID + timestamp for unique test IDs (no rand crate needed)

**Files changed:** `types.rs`, `engine.rs`, `SetupStatusCard.swift`, `AppState.swift`, `ProjectsView.swift`

**Commit:** `5c58b17`

**Plan doc:** `.claude/plans/ACTIVE-bulletproof-hooks.md` (Phase 4 complete)

---

### 2026-01-27 — CLAUDE.md Optimization

**What changed:**
1. Reduced CLAUDE.md from 107 lines to 95 lines
2. Moved 16+ detailed gotchas to `.claude/docs/gotchas.md`
3. Kept only 4 most common gotchas in CLAUDE.md
4. Added gotchas.md to documentation table

**Why:** Following claude-md-author principles—keep CLAUDE.md lean with high-frequency essentials, use `.claude/docs/` for deeper reference material.

**Agent impact:**
- Common gotchas (cargo fmt, dylib copy, hook symlink, UniFFI Task) remain in CLAUDE.md
- Detailed gotchas (session locks, state resolution, testing hooks, etc.) moved to `.claude/docs/gotchas.md`
- Progressive disclosure: Claude/developers get detailed reference when they need it

**Files changed:** `CLAUDE.md`, `.claude/docs/gotchas.md` (new)

---

### 2026-01-27 — Dead Code Cleanup: Swift Terminal System

**What changed:**

1. **Fixed `activateKittyRemote` fallback chain** — Now returns actual `activateAppByName()` result instead of unconditional `true`. Enables fallback strategies when kitty isn't running.

2. **Simplified `launchNewTerminalForContext`** — Added `launchNewTerminal(forPath:name:)` overload. No longer reconstructs a fake 11-field `Project` object just to extract path and name.

3. **Updated `TerminalScripts.launch` signature** — Now accepts `projectPath` and `projectName` directly instead of a `Project` object.

4. **Made `normalize_path_simple` test-only** — Changed to `#[cfg(test)]` since only used in tests. Removed from public exports in `mod.rs`.

5. **Fixed UniFFI `Task` type shadowing** — Discovered and fixed pre-existing build failure where UniFFI-generated `Task` type shadows Swift's `_Concurrency.Task`. All async code now uses `_Concurrency.Task` explicitly.

**Why:**
- Strategy pattern methods must return actual success/failure for fallback chains to work correctly
- Creating fake objects to extract 2 fields is a code smell
- Test-only functions should be `#[cfg(test)]` not `pub`
- UniFFI type shadowing causes confusing "cannot specialize non-generic type 'Task'" errors

**Agent impact:**
- When implementing strategy pattern methods, always return actual success status
- Use `_Concurrency.Task` (not `Task`) in Swift files that import UniFFI bindings
- Prefer direct parameters over object reconstruction when only a few fields are needed
- Use `#[cfg(test)]` for Rust functions only used in tests

**New CLAUDE.md gotchas:**
- UniFFI `Task` shadows Swift concurrency `Task`
- Activation strategy methods must return actual success

**Files changed:** `TerminalLauncher.swift`, `ShellStateStore.swift`, `path_utils.rs`, `state/mod.rs`

**Plan doc:** `.claude/plans/ACTIVE-dead-code-cleanup.md` (updated status)

---

### 2026-01-27 — hud-hook Audit Remediation

**What changed:** Fixed 2 of 3 findings from Session 12 (hud-hook system audit):

1. **Lock dir read errors now use fail-safe sentinel** — `count_other_session_locks()` returns `usize::MAX` (not 0) when `read_dir` fails for non-ENOENT errors. Callers treat any non-zero count as "preserve session record." This prevents transient FS errors from tombstoning active sessions.

2. **Logging guard properly held, not forgotten** — `logging::init()` now returns `Option<WorkerGuard>` which is held in `main()` scope. The guard's `Drop` implementation flushes buffered logs. Previously `std::mem::forget()` prevented final log entries from being written.

**Finding skipped:** Activity format duplication between `hud-hook` and `hud-core` (Finding 1) was intentionally skipped as a design decision—the conversion overhead is acceptable.

**Why:**
- Lock dir errors could incorrectly tombstone active sessions during transient FS issues
- `std::mem::forget()` on `WorkerGuard` contradicts the Rust ownership model—`Drop` has important side effects (flushing)

**Agent impact:**
- Error handling in `count_other_session_locks()` demonstrates fail-safe sentinel pattern—return `usize::MAX` when uncertain
- When `Drop` has side effects, hold values in scope rather than `forget()`ing them
- New CLAUDE.md gotchas document both patterns

**Files changed:** `core/hud-core/src/state/lock.rs`, `core/hud-hook/src/logging.rs`, `core/hud-hook/src/main.rs`

**Tests added:** `test_count_other_session_locks_nonexistent_dir`, `test_count_other_session_locks_unreadable_dir`

**Audit doc:** `.claude/docs/audit/12-hud-hook-system.md`

---

### 2026-01-27 — Side Effects Analysis Audit Complete

**What changed:** Completed comprehensive 11-session audit of all side-effect subsystems across Rust and Swift codebases.

**Scope:**
- **Phase 1 (State Detection Core):** Lock System, Lock Holder, Session Store, Cleanup, Tombstone
- **Phase 2 (Shell Integration):** Shell CWD Tracking, Shell State Store, Terminal Launcher
- **Phase 3 (Supporting Systems):** Activity Files, Hook Configuration, Project Resolution

**Why:** Systematic verification that code matches documentation, with focus on atomicity, race conditions, cleanup, error handling, and dead code detection.

**Key findings:**
1. **All 11 subsystems passed** — No critical bugs or design flaws found
2. **1 doc fix applied** — `lock.rs` exact-match-only documentation (commit `3d78b1b`)
3. **1 low-priority item** — Vestigial function name `find_matching_child_lock` (optional rename)
4. **All 6 CLAUDE.md gotchas verified accurate** — Session-based locks, exact-match-only, hud-hook symlink, async hooks, Swift timestamp decoder, focus override
5. **Shell vs Lock path matching is intentionally different:**
   - Locks: exact-match-only (Claude sessions are specific to launch directory)
   - Shell: child-path matching (shell in `/project/src` matches project `/project`)

**Agent impact:**
- Audit artifacts in `.claude/docs/audit/01-*.md` through `11-*.md`
- Design decisions documented and validated—don't second-guess these patterns
- `ActiveProjectResolver` focus override mechanism is intentionally implicit (no clearManualOverride method)
- Active sessions (Working/Waiting/Compacting) always beat passive sessions (Ready) in priority

**Plan doc:** `.claude/plans/COMPLETE-side-effects-analysis.md`

---

### 2026-01-27 — Lock Holder Timeout Fix and Dead Code Removal

**What changed:**
1. Fixed critical bug: lock holder 24h timeout no longer releases locks when PID is still alive
2. Removed ~650 lines of dead code: `is_session_active()`, `find_by_cwd()`, redundant `normalize_path`
3. Updated stale v3→v4 documentation across state modules

**Why:**
- **Timeout bug**: Sessions running >24h would incorrectly have their locks released, causing state tracking to fail. The lock holder's safety timeout was unconditionally releasing locks instead of only when PID actually exited.
- **Dead code**: The codebase evolved from child→parent path inheritance (v3) to exact-match-only (v4), leaving orphaned functions and tests that no longer applied.
- **Stale docs**: Module docstrings still described v3 behavior (path inheritance, read-only store, hash-based locks).

**Agent impact:**
- Lock holder now tracks exit reason: only releases lock if `pid_exited == true`
- Functions removed: `is_session_active()`, `is_session_active_with_storage()`, `find_by_cwd()`, `boundaries::normalize_path()`
- Documentation in `store.rs`, `mod.rs`, `lock.rs`, `resolver.rs` now accurately describes v4 behavior
- Path matching is exact-match-only—don't implement child→parent inheritance

**Files changed:** `lock_holder.rs`, `sessions.rs`, `store.rs`, `boundaries.rs`, `lock.rs`, `mod.rs`, `resolver.rs`, `claude.rs`

**Commit:** `3d78b1b`

---

### 2026-01-26 — fs_err and tracing for Improved Debugging

**What changed:**
1. Replaced `std::fs` with `fs_err` in all production code (20 files)
2. Added `tracing` infrastructure with daily log rotation (7 days retention)
3. Migrated custom `log()` functions to structured `tracing` macros
4. Replaced `eprintln!` with `tracing::warn!/error!` throughout
5. Consolidated duplicate `is_pid_alive` into single export from `hud_core::state`
6. Added graceful stderr fallback if file appender creation fails

**Why:** Debugging hooks was difficult—errors like "Permission denied" lacked file path context. Custom `log()` functions were scattered and inconsistent. The `fs_err` crate enriches error messages with the file path, and `tracing` provides structured, configurable logging with automatic rotation.

**Agent impact:**
- Logs written to `~/.capacitor/hud-hook-debug.{date}.log` (daily rotation, 7 days)
- Log level configurable via `RUST_LOG` env var (default: `hud_hook=debug,hud_core=warn`)
- Use `fs_err as fs` import pattern in all new Rust files (see existing files for examples)
- `is_pid_alive` is now exported from `hud_core::state` — don't duplicate it
- Use structured fields with tracing: `tracing::debug!(session = %id, "message")`

**Files changed:** 23 files across `hud-core` and `hud-hook`, new `logging.rs` module

**Commit:** `f1ce260`

---

### 2026-01-26 — Rust Best Practices Audit

**What changed:**
1. Added `#[must_use]` to 18 boolean query functions to prevent ignored return values
2. Fixed `needless_collect` lint (use `count()` directly instead of collecting to Vec)
3. Removed unused `Instant` from thread-local sysinfo cache
4. Extracted helper functions in `handle.rs` for clearer event processing
5. Fixed ignored return value in `lock_holder.rs` (now logs success/failure)

**Why:** Code review identified patterns that could lead to bugs (ignored boolean returns) and unnecessary allocations (collecting iterators just to count).

**Agent impact:**
- Functions like `is_session_running()`, `has_any_active_lock()` are marked `#[must_use]`—compiler warns if return value is ignored
- When counting matches, use `.filter().count()` not `.filter().collect::<Vec<_>>().len()`
- Helper functions `is_active_state()`, `extract_file_activity()`, `tool_use_action()` in `handle.rs` encapsulate event processing logic

**Commit:** `35dfc56`

---

### 2026-01-26 — Security Audit: Unsafe Code and Error Recovery

**What changed:**
1. Added SAFETY comments to all `unsafe` blocks documenting invariants
2. `RwLock` poisoning in session cache now recovers gracefully instead of panicking
3. Added `#![allow(clippy::unwrap_used)]` to `patterns.rs` for static regex (documented)
4. Documented intentional regex capture group expects in `ideas.rs`

**Why:** Unsafe code needs clear documentation of safety invariants. Lock poisoning shouldn't crash the app—it should recover and continue.

**Agent impact:**
- All `unsafe` blocks must have `// SAFETY:` comments explaining why the operation is safe
- Use `unwrap_or_else(|_| cache.write().unwrap_or_else(...))` pattern for RwLock recovery
- Static regex compilation can use `expect()` with `#![allow(clippy::unwrap_used)]` at module level
- See `cwd.rs`, `lock_holder.rs`, `handle.rs` for canonical `// SAFETY:` comment format

**Commit:** `a28eee5`

---

### 2026-01-26 — Self-Healing Lock Management

**What changed:** Added multi-layered cleanup to prevent accumulation of stale lock artifacts:
1. `cleanup_orphaned_lock_holders()` kills lock-holder processes whose monitored PID is dead
2. `cleanup_legacy_locks()` removes MD5-hash format locks from older versions
3. Lock-holders have 24-hour safety timeout (`MAX_LIFETIME_SECS`)
4. Locks now include `lock_version` field for debugging

**Why:** Users accumulate stale artifacts when Claude crashes without SessionEnd, terminal force-quits, or app updates. The system relied on "happy path" cleanup—processes exiting gracefully—but real-world usage is messier.

**Agent impact:**
- `CleanupStats` now has `orphaned_processes_killed` and `legacy_locks_removed` fields
- Lock metadata includes `lock_version` (currently `CARGO_PKG_VERSION`)
- `run_startup_cleanup()` runs process cleanup **first** (before file cleanup) to prevent races
- Lock-holder processes self-terminate after 24 hours regardless of PID monitoring state

**Files changed:** `cleanup.rs` (process/legacy cleanup), `lock_holder.rs` (timeout), `lock.rs` (version), `types.rs` (LockInfo)

---

### 2026-01-26 — Session-Based Locks (v4) and Exact-Match-Only Resolution

**What changed:**
1. Locks keyed by `{session_id}-{pid}` instead of path hash (MD5)
2. Path matching uses exact comparison only—no child→parent inheritance
3. Sticky focus: manual override persists until user clicks different project
4. Path normalization handles macOS case-insensitivity and symlinks

**Why:**
- **Concurrent sessions**: Old path-hash locks created 1:1 path↔lock, so two sessions in same directory competed
- **Monorepo independence**: Child paths shouldn't inherit parent's state; packages track independently
- **Sticky focus**: Prevents jarring auto-switching between multiple active sessions

**Agent impact:**
- Lock files: `~/.capacitor/sessions/{session_id}-{pid}.lock/` (v4) vs `{md5-hash}.lock/` (legacy)
- `find_all_locks_for_path()` returns multiple locks (concurrent sessions)
- `release_lock_by_session()` releases specific session's lock
- Resolver's stale Ready fallback removed—lock existence is authoritative
- Legacy MD5-hash locks are stale and should be deleted

**Deprecated:** Path-based locks (`{hash}.lock`), child→parent inheritance, stale Ready fallback.

**Commits:** `97ddc3a`, `3e63150`

**Plan doc:** `.claude/plans/DONE-session-based-locking.md`

---

### 2026-01-26 — Bulletproof Hook System

**What changed:** Hook binary management now uses symlinks instead of copies, with auto-repair on failure.

**Why:** Copying adhoc-signed Rust binaries triggered macOS Gatekeeper SIGKILL (exit 137). Symlinks work reliably.

**Agent impact:**
- `~/.local/bin/hud-hook` must be a **symlink** to `target/release/hud-hook`
- Never copy the binary—always symlink
- See `scripts/sync-hooks.sh` for the canonical approach

**Commits:** `ec63003`

---

### 2026-01-25 — Status Chips Replace Prose Summaries

**What changed:** Replaced three-tier prose summary system (`workingOn` → `lastKnownSummary` → `latestSummary`) with compact status chips showing session state and recency.

**Why:** Prose summaries required reading and parsing. For rapid context-switching between projects, users need **scannable signals**, not narratives. A chip showing "🟡 Waiting · 2h ago" is instantly parseable.

**Agent impact:**
- Don't implement prose summary features—the pattern is deprecated
- Status chips are the canonical way to show project context
- Stats now refresh every 30 seconds to keep recency accurate
- Summary caching logic removed from project cards

**Deprecated:** Three-tier summary fallback, `workingOn` field, prose-based project context display.

**Commits:** `e1b8ed5`, `cca2c28`

---

### 2026-01-25 — Async Hooks and IDE Terminal Activation

**What changed:**
1. Hooks now use Claude Code's `async: true` feature to run in background
2. Setup card detects missing async configuration and prompts to fix
3. Clicking projects with shells in Cursor/VS Code activates the correct IDE window

**Why:**
- Async hooks eliminate latency impact on Claude Code (sidecar philosophy: observe without interfering)
- IDE support handles growing use case of integrated terminals vs standalone terminal apps

**Agent impact:**
- Hook config now includes `async: true` and `timeout: 30` for most events
- `SessionEnd` stays synchronous to ensure cleanup completes
- New `IDEApp` enum in `TerminalLauncher.swift` handles Cursor, VS Code, VS Code Insiders
- Setup card validation checks async config, not just hook existence

**Commits:** `24622a4`, `225a0d7`, `8c8debc`

---

### 2026-01-24 — Terminal Window Reuse and Tmux Support

**What changed:** Clicking a project reuses existing terminal windows instead of always launching new ones. Added tmux session switching and TTY-based tab selection.

**Why:** Avoid terminal window proliferation. Users typically want to switch to existing sessions, not create new ones.

**Agent impact:**
- `TerminalLauncher` now searches `shell-cwd.json` for matching shells before launching new terminals
- Supports iTerm, Terminal.app tab selection via AppleScript
- Supports kitty remote control for window focus
- Tmux sessions are switched via `tmux switch-client -t <session>`

**Commits:** `5c58d3d`, `bcfc5f9`

---

### 2026-01-24 — Shell Integration Performance Optimization

**What changed:** Rewrote shell hook to use native macOS `libproc` APIs instead of subprocess calls for process tree walking.

**Why:** Target <15ms execution time for shell precmd hooks. Subprocess calls (`ps`, `pgrep`) were too slow.

**Agent impact:** The `hud-hook cwd` command is now the canonical way to track shell CWD. Shell history stored in `~/.capacitor/shell-history.jsonl` with 30-day retention.

**Commits:** `146f2b4`, `a02c54d`, `a1d371b`

---

### 2026-01-23 — Plan File Audit and Compaction

**What changed:** Archived completed plans with `DONE-` prefix, compacted to summaries. Removed stale documentation.

**Why:** Keep `.claude/plans/` focused on actionable implementation plans.

**Agent impact:** When looking for implementation history, check `DONE-*.md` files for context. Git history preserves original detailed versions.

**Commit:** `052cecb`

---

### 2026-01-21 — Binary-Only Hook Architecture

**What changed:** Removed bash wrapper script for hooks, now uses pure Rust binary at `~/.local/bin/hud-hook`.

**Why:** Eliminate shell parsing overhead, improve reliability, reduce dependencies.

**Agent impact:** Hooks are installed via `./scripts/sync-hooks.sh`. The hook binary handles all Claude Code events directly.

**Deprecated:** Wrapper scripts, bash-based hook handlers.

**Commits:** `13ef958`, `6321e4d`

---

### 2026-01-20 — Bash to Rust Hook Migration

**What changed:** Migrated hook handler from bash script to compiled Rust binary (`hud-hook`).

**Why:** Performance (bash was too slow), reliability, better error handling.

**Agent impact:** Hook logic lives in `core/hud-hook/src/`. The binary is installed to `~/.local/bin/hud-hook`.

**Commit:** `c94c56b`

---

### 2026-01-19 — V3 State Detection Architecture

**What changed:** Adopted new state detection that uses lock file existence as authoritative signal. Removed conflicting state overrides.

**Why:** Lock existence + live PID is more reliable than timestamp freshness. Handles tool-free text generation where no hook events fire.

**Agent impact:** When debugging state detection, check `~/.capacitor/sessions/` for lock files. Lock existence = session active.

**Deprecated:** Previous state detection approaches that relied on timestamp freshness.

**Commits:** `92305f5`, `6dfa930`

---

### 2026-01-17 — Agent SDK Integration Removed

**What changed:** Removed experimental Agent SDK integration.

**Why:** Discarded direction—Capacitor is a sidecar, not an AI agent host.

**Agent impact:** Do not attempt to add Agent SDK or similar integrations. The app observes Claude Code, doesn't run AI directly.

**Commit:** `1fd6464`

---

### 2026-01-16 — Storage Namespace Migration

**What changed:** Migrated from `~/.claude/` to `~/.capacitor/` namespace for Capacitor-owned state.

**Why:** Respect sidecar architecture—read from Claude's namespace, write to our own.

**Agent impact:** All Capacitor state files are in `~/.capacitor/`. Claude Code config remains in `~/.claude/`.

**Key paths:**
- `~/.capacitor/sessions.json` — Session state
- `~/.capacitor/sessions/` — Lock directory
- `~/.capacitor/shell-cwd.json` — Active shell sessions
- `~/.capacitor/hud-hook-debug.{date}.log` — Debug logs (NEW)

**Commits:** `1d6c4ae`, `1edae7d`

---

### 2026-01-15 — Thinking State Removed

**What changed:** Removed deprecated "thinking" state from session tracking.

**Why:** Claude Code no longer uses extended thinking in a way that needs separate UI state.

**Agent impact:** Session states are: `Working`, `Ready`, `Idle`, `Compacting`, `Waiting`. No "Thinking" state.

**Commit:** `500ae3f`

---

### 2026-01-14 — Caustic Underglow Feature Removed

**What changed:** Removed experimental visual effect (underglow/glow).

**Why:** Design decision—cleaner UI without the effect.

**Agent impact:** Do not add back underglow or similar effects. The app uses subtle visual styling.

**Commit:** `f3826d5`

---

### 2026-01-13 — Daemon Architecture Removed

**What changed:** Removed background daemon process architecture.

**Why:** Simplified to foreground app with file-based state.

**Agent impact:** The app runs as a standard macOS app, not a daemon. State persistence is file-based.

**Deprecated:** Any daemon/background service patterns.

**Commit:** `1884e78`

---

### 2026-01-12 — Artifacts Feature Removed

**What changed:** Removed Artifacts feature, replaced with floating header with progressive blur.

**Why:** Artifacts was over-scoped. Simpler floating header serves the use case.

**Agent impact:** Do not add "artifacts" or similar content management features. The app focuses on session state and project switching.

**Commit:** `84504b3`

---

### 2026-01-10 — Relay Experiment Removed

**What changed:** Removed relay/proxy experiment.

**Why:** Discarded direction.

**Agent impact:** The app communicates directly with Claude Code via filesystem, not through relays.

**Commit:** `9231c39`

---

### 2026-01-07 — Tauri Client Removed, SwiftUI Focus

**What changed:** Removed Tauri/web client, focused entirely on native macOS SwiftUI app.

**Why:** Native performance, ProMotion 120Hz support, better macOS integration.

**Agent impact:** This is a SwiftUI-only project. No web technologies, no Tauri, no Electron.

**Commit:** `2b938e9`

---

### 2026-01-06 — Project Created

**What changed:** Initial commit, Rust + Swift architecture established.

**Why:** Build a native macOS dashboard for Claude Code power users.

**Agent impact:** Core architecture: Rust business logic + UniFFI + Swift UI.

---

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Use `Task` in Swift files with UniFFI imports | Use `_Concurrency.Task` to avoid shadowing | 2026-01-27 |
| Return `true` unconditionally from strategy methods | Return actual success status for fallback chains | 2026-01-27 |
| Create fake objects to extract few fields | Add overloads that accept the needed fields directly | 2026-01-27 |
| Return 0 from query functions on read errors | Return fail-safe sentinel (`usize::MAX`) to preserve state | 2026-01-27 |
| Use `std::mem::forget()` on guards with important `Drop` | Hold guard in scope, let it drop naturally | 2026-01-27 |
| Use `is_session_active()` or path-based session checks | Use lock existence via `find_all_locks_for_path()` | 2026-01-27 |
| Use `find_by_cwd()` for path→session lookup | Use `get_by_session_id()` with exact session ID | 2026-01-27 |
| Use `boundaries::normalize_path()` | Use `normalize_path_for_hashing()` or `normalize_path_for_comparison()` | 2026-01-27 |
| Use `std::fs` directly | Use `fs_err as fs` import | 2026-01-26 |
| Duplicate `is_pid_alive` function | Import from `hud_core::state` | 2026-01-26 |
| Use custom `log()` functions | Use `tracing::debug!/info!/warn!/error!` | 2026-01-26 |
| Use `eprintln!` for errors | Use `tracing::warn!` or `tracing::error!` | 2026-01-26 |
| Write to `~/.claude/` | Write to `~/.capacitor/` | 2026-01-16 |
| Use bash for hook handling | Use Rust `hud-hook` binary | 2026-01-20 |
| Use wrapper scripts for hooks | Use binary-only architecture | 2026-01-21 |
| Track "Thinking" state | Use: Working, Ready, Idle, Compacting, Waiting | 2026-01-15 |
| Add daemon/background service | Use foreground app with file-based state | 2026-01-13 |
| Use Tauri or web technologies | Use SwiftUI only | 2026-01-07 |
| Run AI directly in app | Call Claude Code CLI instead | 2026-01-17 |
| Check timestamp freshness for session liveness | Check lock file existence + PID validity | 2026-01-19 |
| Use `Bundle.module` directly | Use `ResourceBundle.url(forResource:)` | 2026-01-23 |
| Implement prose summaries | Use status chips for project context | 2026-01-25 |
| Use path-hash locks (`{md5}.lock`) | Use session-based locks (`{session_id}-{pid}.lock`) | 2026-01-26 |
| Inherit child lock state to parent path | Use exact-match-only path comparison | 2026-01-26 |
| Copy hook binary to `~/.local/bin/` | Symlink to `target/release/hud-hook` | 2026-01-26 |
| Rely on stale Ready record fallback | Trust lock existence as authoritative | 2026-01-26 |
| Ignore `#[must_use]` function return values | Always handle return values from query functions | 2026-01-26 |
| Use `.collect().len()` for counting | Use `.count()` directly on iterator | 2026-01-26 |
| Write unsafe code without SAFETY comments | Document safety invariants with `// SAFETY:` | 2026-01-26 |

## Trajectory

The project is moving toward:

1. **Parallel workstreams** — One-click git worktree creation for isolated parallel work
   - Architecture decisions locked: worktrees at `{repo}/.capacitor/worktrees/{name}/`
   - Identity model: workstreams are child entities under parent project (not top-level projects)
   - Source of truth: `git worktree list --porcelain`
   - Ready for implementation planning

2. **Project context signals** — ✅ Implemented as status chips (2026-01-25)

3. **Multi-agent CLI support** — Starship-style adapters for Claude, Codex, Aider, Amp (plan completed)

4. **Idea capture with LLM sensemaking** — Fast capture flow with AI-powered expansion (plan completed)

5. **Self-healing lock management** — ✅ Implemented (2026-01-26)
   - Orphaned process cleanup, legacy lock cleanup, 24h safety timeout, version tracking

6. **Improved debugging** — ✅ Implemented (2026-01-26)
   - `fs_err` for file path context in errors
   - `tracing` for structured logging with daily rotation
   - Consolidated shared utilities (e.g., `is_pid_alive`)

7. **Codebase cleanup** — ✅ Nearly Complete (2026-01-27)
   - Removed ~650 lines of dead code from v3→v4 evolution (Rust)
   - Fixed lock holder 24h timeout bug (no longer releases active sessions)
   - Updated stale documentation across state modules
   - Swift cleanup: simplified `TerminalLauncher`, fixed `activateKittyRemote` fallback, `#[cfg(test)]` for test-only Rust functions
   - Fixed UniFFI `Task` type shadowing in Swift
   - Remaining: vestigial type system inconsistencies (low priority)

8. **Side effects analysis** — ✅ Complete (2026-01-27)
   - 12-session comprehensive audit of all side-effect subsystems
   - Session 12 (hud-hook) identified 3 findings; 2 fixed, 1 skipped (intentional design)
   - Design decisions validated and documented in `.claude/docs/audit/`
   - Confirmed: shell child-path matching differs from lock exact-match by design

9. **hud-hook audit remediation** — ✅ Complete (2026-01-27)
   - Fixed lock dir read errors (fail-safe sentinel pattern)
   - Fixed logging guard leak (proper ownership, not `forget()`)
   - Activity format duplication kept as intentional design

10. **Bulletproof Hooks** — ✅ Complete (2026-01-27)
    - Phase 1-3: Symlink-based installation, auto-repair, observability (2026-01-26)
    - Phase 4: Test Hooks button for manual round-trip verification (2026-01-27)
    - Plan doc: `.claude/plans/ACTIVE-bulletproof-hooks.md`

11. **Documentation optimization** — ✅ Complete (2026-01-27)
    - CLAUDE.md optimized (107→95 lines)
    - Detailed gotchas moved to `.claude/docs/gotchas.md`
    - Progressive disclosure pattern for reference material

The core sidecar architecture is stable and validated. The 12-session side-effects audit confirmed all major subsystems work correctly; the few issues found have been remediated. Focus areas: lock reliability (session-based, self-healing, fail-safe error handling), exact-match path resolution for monorepos, terminal integration, and codebase hygiene (dead code removal, documentation accuracy).
