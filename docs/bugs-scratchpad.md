# Bugs Scratchpad

Tracked bugs observed during development. Paper trail for issues seen in the wild.

---

## Bug 1: arc-design-studio stuck in Ready

- **Observed**: 2026-03-31
- **Symptom**: Project card shows "Ready" instead of "Idle" after all sessions ended
- **Root cause**: Orphaned session `1b7b0f09` (from March 27) never received `SessionEnd`. Its `Working` state (priority 3) beats newer Idle sessions in project reduction. Swift staleness downgrades Working → Ready, but not further to Idle.
- **Why GC didn't fire**: The orphan session GC (`cleanup_orphaned_same_project_sessions`) only triggers on `SessionStart` events. If no new session starts for that project, orphans persist indefinitely.
- **Fix**: Added snapshot-time orphan GC (`gc_stale_sessions_at`) that runs at the start of every `snapshot()` call. Evicts stale non-Idle sessions older than 5 minutes when a surviving session exists for the same project.
- **Status**: FIXED. Verified arc-design-studio shows `idle` with 0 active sessions after rebuild.

## Bug 2: circuitry session evicted by snapshot-time GC during quiet period

- **Observed**: 2026-03-31
- **Symptom**: circuitry project showed `idle` with `session=nil` despite having a legitimate running Codex worker
- **Root cause**: The initial snapshot-time GC (Bug 1 fix, v1) unconditionally evicted any non-Idle session older than 5 minutes. The Codex worker went >5 min between hook events during a long thinking/generation phase, causing the GC to treat it as an orphan and delete it.
- **Evidence**: Debug logs show snapshots 231-241 (03:52:51-03:53:09) with `circuitry state=idle session=nil`, while the session's last update was `03:43:10` (10 min gap).
- **Fix (v2)**: Added a "sole session" guard — snapshot-time GC never evicts when only one session exists for a project. A sole session is never evicted at snapshot time, regardless of age.
- **Status**: FIXED. Rebuild deployed.

## Bug 2a: Adversarial review — GC can still evict legitimate concurrent same-project sessions

- **Observed**: 2026-04-01 (adversarial review finding)
- **Symptom**: If two legitimate Codex workers run on the same project and both go quiet for >5 min, the v2 GC would still evict BOTH (since the project has >1 sessions and both are stale).
- **Root cause**: The v2 `session_count > 1` guard was necessary but not sufficient. It prevented sole-session eviction but didn't check whether any session would survive the eviction pass. With all sessions stale, none survive, dropping the project to 0 sessions.
- **Fix (v3, final)**: Rewrote `gc_stale_sessions_at` to group sessions by project, then for each project group only evict stale non-Idle sessions when at least one session will **survive** (is Idle or fresh enough). If no survivor exists, no sessions are evicted for that project.
- **Regression tests added**: `snapshot_gc_preserves_all_stale_sessions_when_no_survivor`, `snapshot_gc_evicts_stale_when_fresh_session_exists`
- **Status**: FIXED. 863 Rust tests pass.

## Bug 3: Terminal activation trusts foreign tmux session names (CWD-drift)

- **Observed**: 2026-04-01 (adversarial review finding)
- **Symptom**: A shell in tmux session `arc-design-studio` that `cd`s into `/Code/circuit` causes the Rust router to produce a route with `session_name=arc-design-studio` for the `circuit` project. Clicking circuit's card would switch the user into the wrong tmux session.
- **Root cause**: `SessionResolutionPolicy.chooseSessionName` blindly trusted any non-empty routed session name without validating it belonged to the target project. The Rust router derives session names from shell CWD evidence, not from canonical project ownership.
- **Fix**: Added `sessionNameBelongsToProject` validation gate in `SessionResolutionPolicy`. A routed session name is only accepted if it is a generic name (`main`, `dev`, `work`, etc.), or the session name and project slug have a case-insensitive substring relationship. If validation fails, falls back to discovery or the project path's last component.
- **Regression tests added**: 11 new Swift tests covering CWD-drift rejection, same-project acceptance, generic names, substring matching, and fallback discovery.
- **Status**: FIXED. 526 Swift tests pass.

## Bug 4: Same-session resurrection preserved terminal metadata

- **Observed**: 2026-04-16 (review finding)
- **Symptom**: A same-session `SessionEnd -> SessionStart` sequence looked resurrected as `Ready`, but still carried `terminated_at` and `DefinitiveTerminal` provenance. The next prompt within the terminal freshness window could be skipped as lower authority, and liveness still treated the session as dead.
- **Root cause**: `SessionStart` was exempted from the top-level terminal-authority block but `upsert_session` preserved terminal metadata and `state_source`.
- **Fix**: `SessionStart` now clears `terminated_at`, records `SessionStart / DefinitiveTransient`, refreshes `last_authoritative_event_at`, and allows the following prompt to return the same session to `Working`.
- **Regression test added**: `session_start_after_session_end_clears_terminal_metadata_and_accepts_prompt`.
- **Status**: FIXED. Commit `94114b08`.

## Bug 5: Transcript cold-start used raw Claude directory slugs

- **Observed**: 2026-04-16 (review finding)
- **Symptom**: Cold-start transcript reconstruction could create sessions under project keys like `-Users-...` instead of absolute project paths when Claude project directories did not contain `.project_path` sidecars.
- **Root cause**: `observation::transcript::scan_for_sessions()` only honored `.project_path` and otherwise used the raw directory name, while real `~/.claude/projects/` layouts commonly rely on hyphen-encoded project directories.
- **Fix**: Transcript discovery now prefers `.project_path`, then uses the existing Claude slug resolver, and only falls back to the raw directory name if resolution fails. Swift also preserves `transcript_activity` provenance and ignores Idle transcript-only history when selecting the active Claude source.
- **Regression tests added**: `scan_resolves_real_style_claude_project_directory_name`, `testProjectionPreservesTranscriptActivityStateSource`, `testIgnoresIdleSessionsWhenResolvingActiveClaudeSource`.
- **Status**: FIXED. Commit `94114b08`.
