# Production Hardening Specification

Date: 2026-04-04
Status: Ready for implementation dispatch
Scope: 9 hardening areas, stack-ranked by priority

---

## 1. Executive Summary

A systematic audit of Capacitor's Rust core and Swift app identified nine production-hardening areas spanning file permissions, FFI error handling, persistence safety, network resilience, and operational observability. Each proposed solution was tested against project constraints (UniFFI bridge regeneration, pre-commit hook budget, existing test suite stability). All nine pass crucible constraint testing and are ready for Codex worker dispatch.

This document is the implementation contract. It specifies exact files, exact changes, sequencing dependencies, and verification criteria for each area. Items are stack-ranked by `severity × likelihood × implementation cost`.

---

## 2. Project Constraints

| Constraint | Detail |
|---|---|
| Backwards compatibility | Not required — breaking changes acceptable |
| UniFFI bridge | Auto-generates `capacitor_core.swift` — cannot edit bridge file directly |
| Pre-commit hook budget | `cargo test` + verifier L1 runs in ~30s |
| Implementation model | Codex workers with worktree isolation |
| Test baseline | 924 Rust tests green, 0 clippy warnings |

---

## 3. Stack-Ranked Priority List

### P0 — Ship Immediately (low effort, high impact)

#### 1. Token File Permissions (Area 4)

**Problem:** Token and PID files are written with default umask permissions. Any local user can read bearer tokens and impersonate the runtime service.

**Files:**
- `core/capacitor-core/src/runtime/service/mod.rs` — `write_token_file` at ~L363-391
- `core/hud-hook/src/serve.rs` — PID file write at ~L365-386

**Change:**
- Import `std::os::unix::fs::PermissionsExt`.
- After each `fs_err::write` call, set file mode to `0o600` via `std::fs::set_permissions`.
- Create `~/.capacitor/runtime/` directory with `std::fs::DirBuilder` and mode `0o700`.

**Tests:**
- Add a test that writes a token file to a temp directory and asserts `metadata.permissions().mode() & 0o777 == 0o600`.
- Add a test that creates the runtime directory and asserts `0o700`.

**Effort:** LOW (~10 lines of Rust)

---

### P1 — Critical Path (crash prevention)

#### 2. FFI Bridge Error Handling (Area 1)

**Problem:** Six Rust FFI functions panic on internal errors instead of returning `Result`. A panic across the FFI boundary is undefined behavior and will crash the Swift app with no recovery path.

**Rust functions to change (return `Result<T, CapacitorError>`):**
1. `checkSetupStatus`
2. `getProjectStatus`
3. `validateProject`
4. `getHookStatus`
5. `runHookTest`
6. `getHookDiagnostic`

**Leave as-is:** Truly infallible functions (`capacitorDir`, `claudeDir`, etc.) that only compute paths.

**Change — Rust side:**
- Convert each function signature to return `Result<T, CapacitorError>` where `CapacitorError` implements `std::error::Error` and derives `uniffi::Error`.
- Replace `unwrap()` / `expect()` calls with `?` propagation.
- After Rust change, run UniFFI bindgen — the regenerated `capacitor_core.swift` will emit `throws` signatures automatically.

**Change — Swift side (~10 call sites):**
- Each call site in `apps/swift/Sources/Capacitor/` wraps the now-throwing call in `do { try ... } catch { /* graceful fallback */ }` or `try?` with a sensible default.
- Graceful fallback means: log the error, present a degraded but non-crashed UI state.

**Files:**
- Rust: functions spread across `core/capacitor-core/src/` (runtime/, domain/, lib.rs)
- Swift: call sites in `apps/swift/Sources/Capacitor/Models/` (AppState.swift, HookServerManager.swift, others)

**Effort:** MEDIUM (6 Rust fn changes + ~10 Swift call sites)

---

### P2 — Data Safety

#### 3. Disk-full Handling (Area 6)

**Problem:** The snapshot save path uses `fs::copy` for backup, which doubles disk usage and fails entirely when the filesystem is full. A disk-full error during backup currently prevents the primary write from completing, even though the in-memory state has already been mutated.

**File:** `core/capacitor-core/src/storage/mod.rs` — `save` method at ~L125-150

**Change:**
- Replace `fs::copy` backup with hard-link (`fs::hard_link`) or rename rotation. Hard-link is O(1) and uses no additional disk space.
- Make backup creation non-fatal after a successful temp-file write. If hard-link fails, log a warning and proceed.
- Add `sync_data()` on the temp file before the atomic rename to ensure durability.
- Document the known limitation: in-memory state mutates before persist. Full transactional semantics (rollback on write failure) is high effort and deferred to follow-up.

**Tests:**
- Test that save succeeds when backup hard-link fails (mock or simulate via read-only backup path).
- Test that `sync_data()` is called before rename (verify via instrumentation or by checking the call sequence in a test double).

**Effort:** MEDIUM

**Dependency:** Implement after File Locking (item 5) — both modify `storage/mod.rs`.

---

#### 4. Schema Migration (Area 3)

**Problem:** `AppSnapshot` has no schema version. If the struct shape changes between releases, `serde_json::from_str` will silently drop unknown fields or fail on missing required fields, producing a corrupt or partial in-memory state with no recovery path.

**Files:**
- `core/capacitor-core/src/domain/types.rs` — `AppSnapshot` struct
- `core/capacitor-core/src/storage/mod.rs` — load path
- `core/capacitor-core/src/lib.rs` — `CoreRuntime::from_storage`

**Change:**
- Add `schema_version: u32` field to `AppSnapshot` with `#[serde(default)]`.
- Define `const CURRENT_SCHEMA_VERSION: u32 = 1` in `storage/mod.rs`.
- On load: if `schema_version` is missing (deserialized as `0`) or does not equal `CURRENT_SCHEMA_VERSION`, rename the file to `<path>.quarantined` and boot fresh.
- Log the quarantine event with the old version number and file path.
- On save: always write `schema_version = CURRENT_SCHEMA_VERSION`.

**Tests:**
- Test that loading a snapshot with `schema_version: 0` triggers quarantine and returns a fresh state.
- Test that loading a snapshot with the current version succeeds normally.
- Test that the quarantined file exists at the expected path after migration.

**Effort:** MEDIUM

**Dependency:** Implement after File Locking (item 5) — quarantine benefits from locking.

---

#### 5. File Locking (Area 2)

**Problem:** `JsonFileSnapshotStorage` has no file locking. If two processes (e.g., the runtime service and a CLI diagnostic tool) read and write the snapshot concurrently, partial writes can produce a corrupt JSON file. The fixed `.tmp` suffix for temp files also creates a collision vector.

**File:** `core/capacitor-core/src/storage/mod.rs` — `JsonFileSnapshotStorage`

**Change:**
- Create a `.lock` sidecar file next to the snapshot path.
- Acquire an `fcntl` advisory lock (via `libc::flock` or the `fs2` crate) before load and save critical sections.
- Release the lock after the operation completes (RAII guard pattern).
- Replace fixed `.tmp` temp file names with unique names that include PID or UUID (e.g., `snapshot.json.tmp.<pid>`).

**Tests:**
- Test that two concurrent save operations do not corrupt the snapshot (spawn two threads, both calling save with different payloads; final snapshot must be valid JSON matching one of the two payloads).
- Test that the lock file is created and cleaned up.
- Test that unique temp file names include the process identifier.

**Effort:** MEDIUM

**Dependency:** Must implement BEFORE Disk-full Handling (item 3) and Schema Migration (item 4).

---

### P3 — Network Resilience

#### 6. TcpStream Write Timeout (Area 5)

**Problem:** `RuntimeServiceEndpoint::request_json` uses a raw `TcpStream` with handwritten HTTP framing. There is no write timeout, no proper Content-Length handling, and no HTTP error parsing. A hung runtime service will block the calling thread indefinitely.

**File:** `core/capacitor-core/src/runtime/service/mod.rs` — `request_json` at ~L224-260

**Change:**
- Replace raw `TcpStream` + handwritten HTTP with `ureq` client.
- `ureq` is already a dependency and the pattern exists in `run_status_reporter.rs`.
- Configure read and write timeouts (e.g., 5s each).
- Propagate `ureq::Error` into the existing error type.

**Tests:**
- Test that a request to an unresponsive server times out within the configured window (bind a TCP listener that accepts but never responds).
- Test that a successful request returns the expected JSON payload.

**Effort:** MEDIUM

---

### P4 — Operational Resilience

#### 7. Watchdog Enhancement (Area 8)

**Problem:** `HookServerManager` restarts the runtime service immediately on failure with no backoff. A crash loop will burn CPU and flood logs. There is no crash budget, so the supervisor will restart forever.

**File:** `apps/swift/Sources/Capacitor/Models/HookServerManager.swift`

**Changes:**
1. **Exponential backoff on restart:** 1s, 2s, 4s, 8s, capped at 60s. Reset the backoff to 1s on successful health check.
2. **Reduce health check interval:** From current interval to 3s for faster failure detection.
3. **Crash budget:** After N restarts (e.g., 5) within M minutes (e.g., 10), stop restarting and surface the failure in the UI via a published property that `AppState` observes.
4. **SIGCHLD detection:** Detect when the supervised process exits unexpectedly (for adopted/zombie processes) instead of relying solely on health check failure.

**Tests:**
- Swift unit tests for backoff calculation (given N failures, assert expected delay).
- Swift unit test for crash budget exhaustion (simulate N rapid failures, assert supervisor enters failed state).

**Effort:** MEDIUM

---

#### 8. Observability Metrics (Area 9)

**Problem:** The runtime service has no diagnostic endpoint. When the service misbehaves, the only debugging tool is log archaeology. There is no way to query runtime health metrics programmatically.

**Files:**
- `core/hud-hook/src/serve.rs` — HTTP dispatch table
- `core/hud-hook/src/handlers.rs` — new handler function

**Change:**
- Add `GET /runtime/diagnostics` route to the dispatch table.
- Authenticate with the same bearer token as existing endpoints.
- Return a JSON payload with these metrics:

```json
{
  "last_gc_at": "2026-04-04T12:00:00Z",
  "gc_cycle_count": 42,
  "gc_last_changed": true,
  "poll_waiters_current": 3,
  "poll_waiters_rejected_total": 7,
  "worker_threads_busy": 2,
  "last_snapshot_served_at": "2026-04-04T12:00:01Z",
  "last_snapshot_changed_at": "2026-04-04T11:59:58Z",
  "last_hook_event_at": "2026-04-04T11:59:55Z",
  "last_shell_signal_at": "2026-04-04T11:59:50Z",
  "uptime_seconds": 3600
}
```

- Track metrics in the shared server state struct. Increment/update counters at the appropriate call sites (GC loop, poll handler, snapshot handler, hook handler, shell handler).

**Tests:**
- Integration test that starts the server, triggers some events, and asserts the diagnostics endpoint returns valid JSON with all expected fields.
- Test that unauthenticated requests to `/runtime/diagnostics` return 401.

**Effort:** MEDIUM

---

#### 9. Shell Cleanup Timing (Area 7)

**Problem:** When a shell exits, its PID lingers in `state.shells` until the next GC cycle. During the GC gap, the app shows stale shell entries. The shell hook only fires on `precmd` (command prompt display), so an abrupt `exit` or terminal close produces no cleanup signal.

**Files:**
- `core/hud-hook/src/cwd.rs` — shell hook integration
- `core/capacitor-core/src/reduce/event_handler.rs` — ingest pipeline
- `core/capacitor-core/src/reduce/gc.rs` — GC cleanup

**Change:**
1. **Shell exit trap:** In the shell integration script (the `precmd`/`preexec` hook), add a `trap '...' EXIT` that sends an unregister signal to the runtime service when the shell process exits.
2. **ShellUnregister event:** Add a new `ShellUnregister { pid: u32 }` variant to the ingest event enum.
3. **Handler:** The reducer handles `ShellUnregister` by immediately removing the PID from `state.shells`, bypassing the GC cycle.
4. **GC fallback:** Keep the existing GC-based cleanup as a safety net for shells that crash without triggering the EXIT trap.

**Tests:**
- Test that ingesting a `ShellUnregister` event removes the shell from state immediately.
- Test that the GC still cleans up shells that were not unregistered (trap never fired).
- Integration test for the HTTP endpoint that receives the unregister signal.

**Effort:** MEDIUM

---

## 4. Implementation Dependency Graph

```
P0: Token Permissions (1) ──────────────────────────── independent, ship first
                                                        │
P1: FFI Bridge (2) ─────────────────────────────────── independent, can parallel with P0
                                                        │
P2: File Locking (5) ──┬── Disk-full Handling (3) ──── must sequence: locking before disk-full
                       │                                 (both modify storage/mod.rs)
                       └── Schema Migration (4) ─────── must sequence: locking before migration
                                                        (quarantine benefits from locking)
                                                        │
P3: TcpStream Write Timeout (6) ────────────────────── independent
                                                        │
P4: Watchdog Enhancement (7) ───────────────────────── independent
    Observability Metrics (8) ───────────────────────── independent
    Shell Cleanup Timing (9) ───────────────────────── independent
```

**Recommended dispatch order:**

| Wave | Items | Can parallel |
|------|-------|--------------|
| Wave 1 | Token Permissions (1), FFI Bridge (2), TcpStream Write Timeout (6) | Yes — all independent |
| Wave 2 | File Locking (5) | Solo — must land before items 3 and 4 |
| Wave 3 | Disk-full Handling (3), Schema Migration (4) | Yes — both depend on locking but not on each other |
| Wave 4 | Watchdog Enhancement (7), Observability Metrics (8), Shell Cleanup Timing (9) | Yes — all independent |

---

## 5. Follow-up Opportunities

Areas not covered by the nine items above but worth considering in future iterations:

1. **Rate limiting on runtime service** — No rate limiting on localhost:7474. Low priority for a local-only service, but defense-in-depth for shared-machine environments.

2. **Graceful degradation UI** — When the runtime service is down, the Swift app could show a degraded-state indicator instead of displaying stale data as if it were current.

3. **Snapshot compression** — JSON snapshots grow linearly with sessions. gzip or zstd compression would reduce disk usage and improve write speed for large state files.

4. **Connection pooling / keep-alive** — Each request creates a new TCP connection (or `ureq` request). Connection reuse would reduce overhead for the polling-heavy read path.

5. **Structured error taxonomy** — Unified error types across the FFI boundary for better Swift-side error handling and user-facing messages. Currently errors are stringly-typed.

6. **Snapshot integrity checksums** — CRC32 or SHA-256 in a snapshot header to detect corruption before the JSON parse attempt, rather than relying on serde to fail gracefully.

7. **Telemetry export integration** — Wire `/runtime/diagnostics` into `transparent-ui-server` for real-time dashboard visibility during development.

8. **Memory-disk consistency** — Full transactional mutation semantics where in-memory state only advances after successful persist. High effort; deferred from Area 6 (Disk-full Handling).

9. **Startup self-test** — Runtime service runs a quick self-check on boot (write+read cycle, permission check, connectivity probe) to fail fast on misconfigured environments.

---

## 6. Verification Strategy

Every implemented hardening area must satisfy the following gates before merge:

| Gate | Criteria |
|------|----------|
| Existing tests | All 924 Rust tests remain green |
| New tests | Each hardening change adds targeted tests covering the specific fix |
| Clippy | `cargo clippy -- -D warnings` passes with 0 warnings |
| Verifier L1 | `./scripts/verify/verify.sh --layers 1` passes with 0 violations |
| Formatting | `cargo fmt --check` passes |
| Swift build | For Swift changes: app must build and launch via `./scripts/dev/restart-alpha-stable.sh` |
| Manual smoke | For P1 (FFI Bridge): verify the app does not crash when the runtime service is unavailable |

**Per-area test requirements:**

| Area | Minimum new tests |
|------|-------------------|
| 1. Token Permissions | 2 (file mode, directory mode) |
| 2. FFI Bridge | 6 Rust (one per converted fn) + Swift compilation verification |
| 3. Disk-full Handling | 2 (backup failure tolerance, sync before rename) |
| 4. Schema Migration | 3 (quarantine trigger, normal load, quarantine file exists) |
| 5. File Locking | 3 (concurrent safety, lock lifecycle, unique temp names) |
| 6. TcpStream Write Timeout | 2 (timeout behavior, successful roundtrip) |
| 7. Watchdog Enhancement | 2 Swift (backoff calculation, crash budget) |
| 8. Observability Metrics | 2 (endpoint response shape, auth enforcement) |
| 9. Shell Cleanup Timing | 3 (immediate removal, GC fallback, HTTP endpoint) |
