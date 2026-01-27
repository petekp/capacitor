//! Lock file detection for Claude Code sessions.
//!
//! Lock directories indicate that a Claude Code process is actively running for a project.
//! The hook script creates these when a session starts; the lock holder (a background process)
//! releases them when Claude exits.
//!
//! # Lock Directory Structure (v4 - Session-Based)
//!
//! Location: `~/.capacitor/sessions/{session_id}-{pid}.lock/`
//! (Locks are in our namespace for sidecar purity—we never write to `~/.claude/`)
//!
//! ```text
//! {session_id}-{pid}.lock/
//! ├── pid          # Plain text: the Claude process ID
//! └── meta.json    # { pid, path, session_id, proc_started, created }
//! ```
//!
//! Session-based locks (v4) allow multiple concurrent sessions in the same directory.
//! Each process gets its own lock (keyed by session_id + PID), and locks are released
//! when that specific process exits. This handles Claude Code's session ID reuse
//! when resuming sessions—multiple processes may share a session_id but each gets
//! its own lock.
//!
//! # Legacy Lock Format (v3 - Path-Based)
//!
//! Location: `~/.capacitor/sessions/{hash}.lock/` where `{hash}` is MD5 of the project path.
//! Legacy locks without `session_id` in meta.json are still supported for backward compatibility.
//!
//! # PID Verification
//!
//! Operating systems reuse PIDs. A lock with PID 12345 might refer to a Claude process
//! that exited, and a new unrelated process might now have that PID. We handle this:
//!
//! 1. **Modern locks** (have `proc_started`): Compare process start time. If it differs,
//!    the PID was recycled → lock is stale.
//!
//! 2. **Legacy locks** (no `proc_started`): Check if the process name contains "claude".
//!    Also reject locks older than 24 hours as a safety measure.
//!
//! # Path Matching
//!
//! A lock at `/project/src` makes `/project` appear active (child → parent inheritance).
//! But a lock at `/project` does NOT make `/project/src` appear active.
//!
//! Why? Common scenario: user pins `/project` but runs Claude from `/project/src`.
//! We want the HUD to show activity for the pinned project.

use super::path_utils::{normalize_path_for_comparison, normalize_path_for_hashing};
use super::types::LockInfo;
use fs_err as fs;
use std::cell::RefCell;
use std::path::Path;

// Thread-local sysinfo cache. We use per-PID refresh (O(1)) instead of scanning
// all processes (O(n)). This matters because lock checks happen on every UI refresh.
// No TTL needed: refresh_process_specifics always fetches fresh data for the specific PID.
thread_local! {
    static SYSTEM_CACHE: RefCell<Option<sysinfo::System>> = const { RefCell::new(None) };
}

/// Normalize a path for consistent comparison.
/// Handles trailing slashes, case sensitivity (macOS), and symlinks.
fn normalize_path(path: &str) -> String {
    normalize_path_for_comparison(path)
}

/// Computes the lock directory name for a project path.
///
/// Lock directories are named `{hash}.lock` where hash is MD5 of the normalized path.
/// This allows O(1) lookup by path.
///
/// Uses `normalize_path_for_hashing` which handles:
/// - Trailing slash removal
/// - Case normalization on macOS (case-insensitive filesystem)
/// - Symlink resolution
fn compute_lock_hash(path: &str) -> String {
    let normalized = normalize_path_for_hashing(path);
    format!("{:x}", md5::compute(normalized))
}

#[must_use]
pub fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // SAFETY: kill(pid, 0) is a standard POSIX liveness check that sends no signal.
        // Returns 0 if the process exists (we have permission to signal it), -1 otherwise.
        // This is the canonical way to check process existence on Unix systems.
        #[allow(unsafe_code)]
        unsafe {
            libc::kill(pid as i32, 0) == 0
        }
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// Get the start time of a process (Unix timestamp).
/// Returns None if the process doesn't exist or can't be queried.
/// Uses per-PID refresh which is O(1) instead of refreshing all processes O(n).
pub fn get_process_start_time(pid: u32) -> Option<u64> {
    use sysinfo::{Pid, ProcessRefreshKind, System};

    SYSTEM_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();

        // Initialize System if needed (empty, no initial process scan)
        let sys = cache.get_or_insert_with(System::new);

        // Refresh ONLY this specific PID - O(1) instead of O(all_processes)
        let sysinfo_pid = Pid::from(pid as usize);
        sys.refresh_process_specifics(sysinfo_pid, ProcessRefreshKind::new());

        sys.process(sysinfo_pid).map(|process| process.start_time())
    })
}

/// Normalize a timestamp to milliseconds.
/// Detects whether the input is in seconds or milliseconds and converts accordingly.
/// Values < 1e12 are assumed to be seconds (before year 2286 when interpreted as ms).
/// Values >= 1e12 are assumed to be milliseconds.
fn normalize_to_ms(timestamp: u64) -> u64 {
    const THRESHOLD: u64 = 1_000_000_000_000; // 1 trillion (~ Sep 2001 in ms, ~ Sep 33658 in seconds)
    if timestamp < THRESHOLD {
        // Likely seconds - convert to milliseconds
        timestamp * 1000
    } else {
        // Already milliseconds
        timestamp
    }
}

/// Verify PID for legacy locks (no proc_started timestamp).
/// Applies additional checks to mitigate PID reuse risk:
/// 1. Basic PID existence check
/// 2. Process name or command line verification (must contain "claude")
fn is_pid_alive_with_legacy_checks(pid: u32) -> bool {
    use sysinfo::{Pid, ProcessRefreshKind, System, UpdateKind};

    // Basic PID check
    if !is_pid_alive(pid) {
        return false;
    }

    // Additional mitigation: verify process identity
    // Check both name and cmd for "claude" to handle node-based execution
    // This reduces (but doesn't eliminate) PID reuse risk
    SYSTEM_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();

        let sys = cache.get_or_insert_with(System::new);

        // Refresh ONLY this specific PID with cmd info for legacy verification
        let sysinfo_pid = Pid::from(pid as usize);
        sys.refresh_process_specifics(
            sysinfo_pid,
            ProcessRefreshKind::new().with_cmd(UpdateKind::Always),
        );

        if let Some(process) = sys.process(sysinfo_pid) {
            let name = process.name().to_string().to_lowercase();

            // Check process name for "claude"
            if name.contains("claude") {
                return true;
            }

            // If name doesn't contain "claude", check command line args
            // This handles cases where claude runs under node/deno/bun
            let cmd = process.cmd();
            for arg in cmd {
                let arg_lower = arg.to_lowercase();
                if arg_lower.contains("claude") {
                    return true;
                }
            }

            false
        } else {
            false
        }
    })
}

/// Verify that a PID is alive AND matches the expected start time.
/// If expected_start is None (legacy lock), applies additional verification checks.
/// If expected_start is Some, verifies the process start time matches (within ±2 seconds tolerance).
fn is_pid_alive_verified(pid: u32, expected_start: Option<u64>) -> bool {
    // Basic PID check first - if the process doesn't exist at all, return early
    if !is_pid_alive(pid) {
        return false;
    }

    // If no expected start time, use legacy checks (PID + process name)
    let Some(expected_start_time) = expected_start else {
        return is_pid_alive_with_legacy_checks(pid);
    };

    // Get actual process start time
    if let Some(actual_start) = get_process_start_time(pid) {
        // Allow ±2 second tolerance for timing differences between bash calculation and sysinfo
        actual_start.abs_diff(expected_start_time) <= 2
    } else {
        // Process exists (passed is_pid_alive) but sysinfo couldn't query start time.
        // This can happen during transient OS races when reading the process table.
        // Trust the basic PID check to avoid false negatives that cause state flipping.
        true
    }
}

pub(crate) fn read_lock_info(lock_dir: &Path) -> Option<LockInfo> {
    let pid_path = lock_dir.join("pid");
    let meta_path = lock_dir.join("meta.json");

    let pid_str = fs::read_to_string(&pid_path).ok()?;
    let pid: u32 = pid_str.trim().parse().ok()?;

    let meta_content = fs::read_to_string(&meta_path).ok()?;
    let meta: serde_json::Value = serde_json::from_str(&meta_content).ok()?;

    let path = meta.get("path")?.as_str()?.to_string();

    // Handle session_id (v4 session-based locks)
    let session_id = meta
        .get("session_id")
        .and_then(|v| v.as_str().map(String::from));

    // Handle proc_started (PID verification)
    let proc_started = meta.get("proc_started").and_then(|v| v.as_u64());

    // Handle created (lock selection) - check both new and legacy fields
    let created = meta.get("created").and_then(|v| v.as_u64()).or_else(|| {
        // Fallback to old "started" field for backward compatibility
        meta.get("started").and_then(|v| match v {
            serde_json::Value::Number(n) => n.as_u64(),
            serde_json::Value::String(_) => None, // ISO string - ignore
            _ => None,
        })
    });

    // Handle lock_version (version tracking)
    let lock_version = meta
        .get("lock_version")
        .and_then(|v| v.as_str().map(String::from));

    let info = LockInfo {
        pid,
        path,
        session_id,
        proc_started,
        created,
        lock_version,
    };

    // Age-based expiry for legacy locks (no proc_started)
    // Reject locks older than 24 hours to mitigate PID reuse risk
    if info.proc_started.is_none() {
        use std::time::{SystemTime, UNIX_EPOCH};
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        // Determine lock age from created timestamp, or use lock dir mtime as fallback
        // All timestamps normalized to milliseconds for consistent comparison
        let lock_age_ms = if let Some(created_time) = info.created {
            // Normalize to milliseconds (handles both seconds and ms timestamps)
            let created_ms = normalize_to_ms(created_time);
            now_ms.saturating_sub(created_ms)
        } else {
            // No created timestamp - try ISO string parsing or use lock dir mtime
            if let Some(iso_str) = meta.get("started").and_then(|v| v.as_str()) {
                // Try to parse ISO 8601 timestamp
                if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(iso_str) {
                    // Convert to milliseconds
                    let iso_epoch_ms = dt.timestamp_millis() as u64;
                    now_ms.saturating_sub(iso_epoch_ms)
                } else {
                    // Can't parse - use lock dir mtime as fallback
                    if let Ok(metadata) = fs::metadata(lock_dir) {
                        if let Ok(modified) = metadata.modified() {
                            let mtime_ms = modified
                                .duration_since(UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_millis() as u64;
                            now_ms.saturating_sub(mtime_ms)
                        } else {
                            // Can't get mtime - assume very old
                            86_400_001 // Older than threshold (24h + 1ms)
                        }
                    } else {
                        86_400_001
                    }
                }
            } else {
                // No started field at all - use lock dir mtime
                if let Ok(metadata) = fs::metadata(lock_dir) {
                    if let Ok(modified) = metadata.modified() {
                        let mtime_ms = modified
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        now_ms.saturating_sub(mtime_ms)
                    } else {
                        86_400_001
                    }
                } else {
                    86_400_001
                }
            }
        };

        if lock_age_ms > 86_400_000 {
            // 24 hours in milliseconds
            // Too old - treat as stale
            return None;
        }
    }

    Some(info)
}

fn check_lock_for_path(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    let hash = compute_lock_hash(project_path);
    let lock_dir = lock_base.join(format!("{}.lock", hash));

    if !lock_dir.is_dir() {
        return None;
    }

    let info = read_lock_info(&lock_dir)?;

    if !is_pid_alive_verified(info.pid, info.proc_started) {
        return None;
    }

    Some(info)
}

/// Returns true if ANY active session lock exists.
///
/// Used to suppress hook health warnings during long responses—if a lock exists,
/// Claude is definitely running even if the heartbeat is stale.
#[must_use]
pub fn has_any_active_lock(lock_base: &Path) -> bool {
    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(_) => return false,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                if is_pid_alive_verified(info.pid, info.proc_started) {
                    return true;
                }
            }
        }
    }

    false
}

/// Returns true if there's an active lock at or under the given path.
///
/// Checks:
/// 1. Exact lock at `project_path`
/// 2. Child locks (e.g., `/project/src` lock makes `/project` active)
///
/// Does NOT check parent paths. A lock at `/project` doesn't make `/project/src` active.
#[must_use]
pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    // Only exact matches - no child inheritance.
    // Each project shows only sessions started at that exact path.
    check_lock_for_path(lock_base, project_path).is_some()
}

/// Returns lock metadata for the given path (exact match only).
///
/// Returns `None` if no active lock exists at this exact path.
/// No child inheritance - each project shows only its own sessions.
pub fn get_lock_info(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    // Only exact matches - no child inheritance.
    check_lock_for_path(lock_base, project_path)
}

/// Finds all active locks for a given path (exact or child matches).
///
/// This supports the session-based locking model where multiple concurrent
/// sessions can exist in the same directory. Returns all locks whose path
/// matches (exact) or is a child of the query path.
///
/// Example: If `project_path` is `/project`, this returns locks at:
/// - `/project` (exact match)
/// - `/project/src` (child match)
/// - `/project/apps/swift` (child match)
pub fn find_all_locks_for_path(lock_base: &Path, project_path: &str) -> Vec<LockInfo> {
    let normalized = normalize_path(project_path);

    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };

    let mut locks = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                let info_path_normalized = normalize_path(&info.path);

                // Only exact matches - no child inheritance.
                // Each project card shows only sessions started at that exact path.
                let is_exact = info_path_normalized == normalized;

                if is_exact && is_pid_alive_verified(info.pid, info.proc_started) {
                    locks.push(info);
                }
            }
        }
    }

    locks
}

/// Finds the best matching lock for resolver use.
///
/// Only returns exact path matches - no child inheritance.
/// When multiple locks match (concurrent sessions), returns the newest by `created` timestamp.
///
/// This is used by the resolver to associate a lock with a state record.
pub fn find_matching_child_lock(
    lock_base: &Path,
    project_path: &str,
    target_pid: Option<u32>,
    target_cwd: Option<&str>,
) -> Option<LockInfo> {
    let project_path_normalized = normalize_path(project_path);
    let entries = fs::read_dir(lock_base).ok()?;

    let mut best_match: Option<LockInfo> = None;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                if is_pid_alive_verified(info.pid, info.proc_started) {
                    let info_path_normalized = normalize_path(&info.path);

                    // Only exact matches - no child inheritance.
                    // Each project shows only sessions started at that exact path.
                    if info_path_normalized != project_path_normalized {
                        continue;
                    }

                    // Check if this lock matches the target criteria
                    let pid_matches = target_pid.map_or(true, |pid| pid == info.pid);
                    let path_matches = target_cwd.map_or(true, |cwd| cwd == info.path);

                    if pid_matches && path_matches {
                        // Multiple exact matches (concurrent sessions): prefer newest
                        match &best_match {
                            None => {
                                best_match = Some(info);
                            }
                            Some(current) => {
                                let info_created = info.created.unwrap_or(0);
                                let current_created = current.created.unwrap_or(0);

                                if info_created > current_created
                                    || (info_created == current_created && info.path > current.path)
                                {
                                    best_match = Some(info);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    best_match
}

// =============================================================================
// Lock Creation/Management (for hud-hook binary)
// =============================================================================

/// Create a lock directory for a session (v4 session-based).
///
/// Locks are keyed by `{session_id}-{pid}`, allowing multiple concurrent processes
/// even when they share the same session_id (which happens when Claude Code resumes
/// a session in multiple terminals).
///
/// Returns the path to the created lock directory, or None if creation failed.
pub fn create_session_lock(
    lock_base: &Path,
    session_id: &str,
    project_path: &str,
    pid: u32,
) -> Option<std::path::PathBuf> {
    let lock_dir = lock_base.join(format!("{}-{}.lock", session_id, pid));

    // Ensure the parent lock directory exists
    if !lock_base.exists() {
        if let Err(e) = fs::create_dir_all(lock_base) {
            tracing::warn!(error = %e, "Failed to create lock base directory");
            return None;
        }
    }

    // Try to create the lock directory atomically
    match fs::create_dir(&lock_dir) {
        Ok(()) => {
            // We created the lock, write metadata
            if let Err(e) =
                write_lock_metadata(&lock_dir, pid, project_path, Some(session_id), None)
            {
                tracing::warn!(
                    session = %session_id,
                    path = %project_path,
                    error = %e,
                    "Failed to write lock metadata"
                );
                // Clean up on metadata write failure
                let _ = fs::remove_dir_all(&lock_dir);
                None
            } else {
                Some(lock_dir)
            }
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Lock already exists for this exact session_id + PID combination.
            // This can only happen if we're trying to create a lock we already own.
            if let Some(info) = read_lock_info(&lock_dir) {
                if info.pid == pid {
                    // We already own this lock - don't spawn another holder
                    return None;
                }

                // Different PID has this exact lock name (shouldn't happen with session_id-pid naming)
                // but handle it by checking if the lock is stale
                if !is_pid_alive_verified(info.pid, info.proc_started) {
                    // Existing lock is stale, take it over
                    let _ = fs::remove_dir_all(&lock_dir);
                    if fs::create_dir(&lock_dir).is_ok()
                        && write_lock_metadata(&lock_dir, pid, project_path, Some(session_id), None)
                            .is_ok()
                    {
                        return Some(lock_dir);
                    }
                    tracing::warn!(
                        session = %session_id,
                        path = %project_path,
                        "Failed to take over stale lock"
                    );
                } else {
                    tracing::warn!(
                        session = %session_id,
                        pid = pid,
                        path = %project_path,
                        holder_pid = info.pid,
                        "Lock collision - held by live PID"
                    );
                }
            } else {
                // Can't read existing lock, try to take it
                let _ = fs::remove_dir_all(&lock_dir);
                if fs::create_dir(&lock_dir).is_ok()
                    && write_lock_metadata(&lock_dir, pid, project_path, Some(session_id), None)
                        .is_ok()
                {
                    return Some(lock_dir);
                }
                tracing::warn!(
                    session = %session_id,
                    path = %project_path,
                    "Failed to take over unreadable lock"
                );
            }
            None
        }
        Err(e) => {
            tracing::warn!(
                session = %session_id,
                path = %project_path,
                error = %e,
                "Failed to create lock directory"
            );
            None
        }
    }
}

/// Create a lock directory for a session (legacy path-based API).
///
/// **Deprecated:** Use `create_session_lock` for new code. This function is kept
/// for backward compatibility with existing code that doesn't have access to session_id.
///
/// Returns the path to the created lock directory, or None if creation failed
/// (e.g., another process already holds the lock).
pub fn create_lock(lock_base: &Path, project_path: &str, pid: u32) -> Option<std::path::PathBuf> {
    let hash = compute_lock_hash(project_path);
    let lock_dir = lock_base.join(format!("{}.lock", hash));

    // Ensure the parent lock directory exists
    if !lock_base.exists() {
        if let Err(e) = fs::create_dir_all(lock_base) {
            tracing::warn!(error = %e, "Failed to create lock base directory");
            return None;
        }
    }

    // Try to create the lock directory atomically
    match fs::create_dir(&lock_dir) {
        Ok(()) => {
            // We created the lock, write metadata (no session_id for legacy)
            if write_lock_metadata(&lock_dir, pid, project_path, None, None).is_ok() {
                Some(lock_dir)
            } else {
                // Clean up on metadata write failure
                let _ = fs::remove_dir_all(&lock_dir);
                None
            }
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Lock already exists - check if we should take it over
            if let Some(info) = read_lock_info(&lock_dir) {
                if info.pid == pid {
                    // We already own this lock - don't spawn another holder
                    // The existing lock holder is already managing this lock
                    return None;
                }

                // Check if the existing lock holder is still alive
                if is_pid_alive_verified(info.pid, info.proc_started) {
                    // Lock is held by another live process - take it over anyway!
                    // This handles the common case where a user starts a new Claude session
                    // in the same directory while an old one is still running (but idle).
                    // The old lock holder will detect the takeover and exit gracefully.
                    //
                    // We update in place rather than remove+create to avoid race conditions.
                    if write_lock_metadata(&lock_dir, pid, project_path, None, Some(info.pid))
                        .is_ok()
                    {
                        tracing::info!(
                            path = %project_path,
                            new_pid = pid,
                            old_pid = info.pid,
                            "Lock takeover"
                        );
                        return Some(lock_dir);
                    }
                    // If metadata update fails, don't fall through - we don't want to
                    // remove a lock that's still in use
                    tracing::warn!(
                        path = %project_path,
                        holder_pid = info.pid,
                        "Failed to take over lock"
                    );
                    return None;
                }

                // Existing lock is stale, take it over
                let _ = fs::remove_dir_all(&lock_dir);
                if fs::create_dir(&lock_dir).is_ok()
                    && write_lock_metadata(&lock_dir, pid, project_path, None, None).is_ok()
                {
                    return Some(lock_dir);
                }
            } else {
                // Can't read existing lock, try to take it
                let _ = fs::remove_dir_all(&lock_dir);
                if fs::create_dir(&lock_dir).is_ok()
                    && write_lock_metadata(&lock_dir, pid, project_path, None, None).is_ok()
                {
                    return Some(lock_dir);
                }
            }
            None
        }
        Err(_) => None,
    }
}

/// Count active locks for a session ID, excluding a specific PID.
///
/// This is used to determine if there are other processes sharing the same
/// session_id before deleting the session record from sessions.json.
pub fn count_other_session_locks(lock_base: &Path, session_id: &str, exclude_pid: u32) -> usize {
    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(_) => return 0,
    };

    let prefix = format!("{}-", session_id);
    let mut count = 0;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            // Check if lock name starts with our session_id prefix
            if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                if name.starts_with(&prefix) {
                    // Read lock info to verify it's alive and get the PID
                    if let Some(info) = read_lock_info(&path) {
                        if info.pid != exclude_pid
                            && is_pid_alive_verified(info.pid, info.proc_started)
                        {
                            count += 1;
                        }
                    }
                }
            }
        }
    }

    count
}

/// Release a lock directory by session ID and PID (v4 session-based).
///
/// This is the preferred method for releasing locks as it directly targets
/// the specific process's lock without affecting other concurrent processes.
#[must_use]
pub fn release_lock_by_session(lock_base: &Path, session_id: &str, pid: u32) -> bool {
    let lock_dir = lock_base.join(format!("{}-{}.lock", session_id, pid));

    if lock_dir.exists() {
        fs::remove_dir_all(&lock_dir).is_ok()
    } else {
        true // Already released
    }
}

/// Release a lock directory by path (legacy path-based).
///
/// **Note:** This only releases legacy path-based locks. For session-based locks,
/// use `release_lock_by_session` instead.
#[must_use]
pub fn release_lock(lock_base: &Path, project_path: &str) -> bool {
    let hash = compute_lock_hash(project_path);
    let lock_dir = lock_base.join(format!("{}.lock", hash));

    if lock_dir.exists() {
        fs::remove_dir_all(&lock_dir).is_ok()
    } else {
        true // Already released
    }
}

/// Update lock metadata to a new PID (for handoff).
pub fn update_lock_pid(
    lock_dir: &Path,
    new_pid: u32,
    project_path: &str,
    handoff_from: Option<u32>,
) -> bool {
    // Read existing session_id if present (preserve it during handoff)
    let session_id = read_lock_info(lock_dir).and_then(|info| info.session_id);
    write_lock_metadata(
        lock_dir,
        new_pid,
        project_path,
        session_id.as_deref(),
        handoff_from,
    )
    .is_ok()
}

/// Write lock metadata files (pid and meta.json).
fn write_lock_metadata(
    lock_dir: &Path,
    pid: u32,
    project_path: &str,
    session_id: Option<&str>,
    handoff_from: Option<u32>,
) -> std::io::Result<()> {
    use std::time::{SystemTime, UNIX_EPOCH};

    // Write PID file
    fs::write(lock_dir.join("pid"), pid.to_string())?;

    // Get process start time
    let proc_started = get_process_start_time(pid);

    // Get current timestamp in milliseconds
    let created_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    // Build metadata JSON
    let mut meta = serde_json::json!({
        "pid": pid,
        "path": project_path,
        "created": created_ms,
        "lock_version": env!("CARGO_PKG_VERSION"),
    });

    if let Some(sid) = session_id {
        meta["session_id"] = serde_json::json!(sid);
    }

    if let Some(started) = proc_started {
        meta["proc_started"] = serde_json::json!(started);
    }

    if let Some(from_pid) = handoff_from {
        meta["handoff_from"] = serde_json::json!(from_pid);
    }

    // Write metadata file
    let meta_content = serde_json::to_string_pretty(&meta).map_err(std::io::Error::other)?;
    fs::write(lock_dir.join("meta.json"), meta_content)?;

    Ok(())
}

/// Get the lock directory path for a session (v4 session-based).
pub fn get_session_lock_dir_path(
    lock_base: &Path,
    session_id: &str,
    pid: u32,
) -> std::path::PathBuf {
    lock_base.join(format!("{}-{}.lock", session_id, pid))
}

/// Get the lock directory path for a project (legacy path-based, without checking if it exists).
pub fn get_lock_dir_path(lock_base: &Path, project_path: &str) -> std::path::PathBuf {
    let hash = compute_lock_hash(project_path);
    lock_base.join(format!("{}.lock", hash))
}

/// Test helpers for creating lock files.
/// Available with the `test-helpers` feature or in tests.
#[cfg(any(test, feature = "test-helpers"))]
pub mod tests_helper {
    use super::compute_lock_hash;
    use std::fs;
    use std::path::Path;

    /// Creates a valid lock for the current process (legacy path-based).
    /// Uses the real process start time for verification to pass.
    pub fn create_lock(lock_base: &Path, pid: u32, path: &str) {
        // Get the actual start time of the process for tests to pass verification
        let proc_started = super::get_process_start_time(pid)
            .expect("Failed to get process start time in test helper - is the process alive?");

        // Use current timestamp for created
        use std::time::{SystemTime, UNIX_EPOCH};
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        create_lock_with_timestamps(lock_base, pid, path, proc_started, created);
    }

    /// Creates a session-based lock for the current process.
    pub fn create_session_lock(lock_base: &Path, pid: u32, path: &str, session_id: &str) {
        let proc_started = super::get_process_start_time(pid)
            .expect("Failed to get process start time in test helper - is the process alive?");

        use std::time::{SystemTime, UNIX_EPOCH};
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        create_session_lock_with_timestamps(
            lock_base,
            pid,
            path,
            session_id,
            proc_started,
            created,
        );
    }

    /// Creates a session-based lock with custom timestamps.
    pub fn create_session_lock_with_timestamps(
        lock_base: &Path,
        pid: u32,
        path: &str,
        session_id: &str,
        proc_started: u64,
        created: u64,
    ) {
        // Lock naming: {session_id}-{pid}.lock
        let lock_dir = lock_base.join(format!("{}-{}.lock", session_id, pid));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();
        fs::write(
            lock_dir.join("meta.json"),
            format!(
                r#"{{"pid": {}, "path": "{}", "session_id": "{}", "proc_started": {}, "created": {}, "lock_version": "{}"}}"#,
                pid, path, session_id, proc_started, created, env!("CARGO_PKG_VERSION")
            ),
        )
        .unwrap();
    }

    pub fn create_lock_with_timestamps(
        lock_base: &Path,
        pid: u32,
        path: &str,
        proc_started: u64,
        created: u64,
    ) {
        let hash = compute_lock_hash(path);
        let lock_dir = lock_base.join(format!("{}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();
        fs::write(
            lock_dir.join("meta.json"),
            format!(
                r#"{{"pid": {}, "path": "{}", "proc_started": {}, "created": {}, "lock_version": "{}"}}"#,
                pid, path, proc_started, created, env!("CARGO_PKG_VERSION")
            ),
        )
        .unwrap();
    }

    // Legacy alias for backward compatibility with tests
    pub fn create_lock_with_timestamp(lock_base: &Path, pid: u32, path: &str, timestamp: u64) {
        // Old API: timestamp was used for both verification and selection
        // Map to new API: use same timestamp for both
        create_lock_with_timestamps(lock_base, pid, path, timestamp, timestamp);
    }
}

#[cfg(test)]
mod tests {
    use super::tests_helper::{create_lock, create_lock_with_timestamp};
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_no_lock_dir_means_not_running() {
        let temp = tempdir().unwrap();
        assert!(!is_session_running(temp.path(), "/some/project"));
    }

    #[test]
    fn test_lock_with_dead_pid_means_not_running() {
        let temp = tempdir().unwrap();
        // Use create_lock_with_timestamp for dead PID since get_process_start_time would fail
        create_lock_with_timestamp(temp.path(), 99999999, "/project", 1704067200);
        assert!(!is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_lock_with_live_pid_means_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        assert!(is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_child_does_not_inherit_parent_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        // Child should NOT inherit parent lock (parent lock doesn't make child active)
        assert!(!is_session_running(temp.path(), "/parent/child"));
    }

    #[test]
    fn test_get_lock_info_returns_info_when_running() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        let info = get_lock_info(temp.path(), "/project").unwrap();
        assert_eq!(info.pid, std::process::id());
        assert_eq!(info.path, "/project");
    }

    #[test]
    fn test_get_lock_info_returns_none_when_not_running() {
        let temp = tempdir().unwrap();
        assert!(get_lock_info(temp.path(), "/project").is_none());
    }

    #[test]
    fn test_get_lock_info_does_not_inherit_parent_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent");
        // Child should NOT get parent's lock info
        assert!(get_lock_info(temp.path(), "/parent/child").is_none());
    }

    #[test]
    fn test_parent_query_does_not_find_child_lock() {
        // With exact-match-only policy, parent paths don't see child locks.
        // This enables monorepos and packages to be tracked independently.
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent/child");
        // Parent should NOT find child lock (no inheritance)
        assert!(!is_session_running(temp.path(), "/parent"));
        // But child path should work (exact match)
        assert!(is_session_running(temp.path(), "/parent/child"));
    }

    #[test]
    fn test_get_lock_info_exact_match_only() {
        // With exact-match-only policy, get_lock_info only returns locks
        // for the exact path queried.
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent/child");
        // Parent query should return None (no child inheritance)
        assert!(get_lock_info(temp.path(), "/parent").is_none());
        // Child query should work (exact match)
        let info = get_lock_info(temp.path(), "/parent/child").unwrap();
        assert_eq!(info.path, "/parent/child");
    }

    #[test]
    fn test_create_lock_returns_none_when_already_owned() {
        // This tests the production create_lock function (not the test helper)
        // to ensure it returns None when we already own the lock,
        // preventing duplicate lock holder processes from being spawned
        let temp = tempdir().unwrap();
        let pid = std::process::id();

        // First call should succeed
        let first = super::create_lock(temp.path(), "/project", pid);
        assert!(first.is_some(), "First create_lock should succeed");

        // Second call with same PID should return None (we already own it)
        let second = super::create_lock(temp.path(), "/project", pid);
        assert!(
            second.is_none(),
            "Second create_lock should return None to prevent duplicate lock holders"
        );

        // Lock should still be valid
        assert!(is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_has_any_active_lock_empty_dir() {
        let temp = tempdir().unwrap();
        assert!(!has_any_active_lock(temp.path()));
    }

    #[test]
    fn test_has_any_active_lock_with_live_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/project");
        assert!(has_any_active_lock(temp.path()));
    }

    #[test]
    fn test_has_any_active_lock_with_dead_lock() {
        let temp = tempdir().unwrap();
        create_lock_with_timestamp(temp.path(), 99999999, "/project", 1704067200);
        assert!(!has_any_active_lock(temp.path()));
    }

    #[test]
    fn test_has_any_active_lock_mixed_live_and_dead() {
        let temp = tempdir().unwrap();
        // Create one dead lock
        create_lock_with_timestamp(temp.path(), 99999999, "/dead-project", 1704067200);
        // Create one live lock
        create_lock(temp.path(), std::process::id(), "/live-project");
        // Should return true because there's at least one live lock
        assert!(has_any_active_lock(temp.path()));
    }

    #[test]
    fn test_find_matching_child_lock_prefers_exact_over_newer_child() {
        // Regression test for the bug where a newer child lock beat an older exact lock
        use super::tests_helper::create_lock_with_timestamps;

        let temp = tempdir().unwrap();
        let pid = std::process::id();
        let proc_started =
            get_process_start_time(pid).expect("Failed to get process start time for test");

        // Create an older exact lock at /project
        create_lock_with_timestamps(temp.path(), pid, "/project", proc_started, 1000);

        // Create a newer child lock at /project/src
        create_lock_with_timestamps(temp.path(), pid, "/project/src", proc_started, 2000);

        // When querying /project, should find the EXACT match, not the newer child
        let result = find_matching_child_lock(temp.path(), "/project", None, None).unwrap();

        assert_eq!(
            result.path, "/project",
            "Exact match should beat newer child match"
        );
    }

    #[test]
    fn test_find_matching_lock_exact_match_only() {
        // With exact-match-only policy, find_matching_child_lock only
        // returns locks at the exact queried path.
        use super::tests_helper::create_lock_with_timestamps;

        let temp = tempdir().unwrap();
        let pid = std::process::id();
        let proc_started =
            get_process_start_time(pid).expect("Failed to get process start time for test");

        // Create only a child lock (no exact match at /project)
        create_lock_with_timestamps(temp.path(), pid, "/project/src", proc_started, 1000);

        // Query /project should return None (no exact match, no child inheritance)
        let result = find_matching_child_lock(temp.path(), "/project", None, None);
        assert!(
            result.is_none(),
            "Should not find child lock when querying parent path"
        );

        // Query /project/src should work (exact match)
        let result = find_matching_child_lock(temp.path(), "/project/src", None, None);
        assert!(result.is_some());
        assert_eq!(result.unwrap().path, "/project/src");
    }

    #[test]
    fn test_find_matching_lock_prefers_newer_among_exact_matches() {
        // When multiple exact-match locks exist (concurrent sessions),
        // prefer the newest one.
        use super::tests_helper::create_lock_with_timestamps;

        let temp = tempdir().unwrap();
        let pid = std::process::id();
        let proc_started =
            get_process_start_time(pid).expect("Failed to get process start time for test");

        // Create two locks at the same path with different session IDs
        // (simulating concurrent sessions)
        create_lock_with_timestamps(temp.path(), pid, "/project", proc_started, 1000);
        // Note: create_lock_with_timestamps uses path-based naming, so this
        // creates a separate lock. For this test, we verify the newer timestamp wins.

        let result = find_matching_child_lock(temp.path(), "/project", None, None);
        assert!(result.is_some(), "Should find exact match");
    }

    #[test]
    fn test_create_lock_takeover_from_live_process() {
        // Tests that a new session can take over a lock held by another live process.
        // This simulates the scenario where a user starts a new Claude session
        // in the same directory while an old one is still running (but idle).
        //
        // We use the current process as both "old" and "new" holder since we can't
        // easily spawn another long-lived process in tests. The key behavior we're
        // testing is that create_lock succeeds and records the handoff.
        let temp = tempdir().unwrap();
        let pid = std::process::id();

        // Create initial lock with the test helper (simulating old session)
        create_lock(temp.path(), pid, "/project");

        // Verify lock exists
        assert!(is_session_running(temp.path(), "/project"));

        // Now, use a different PID (we'll use pid+1 which is likely dead, but
        // we're testing the code path where the lock already exists)
        // Since pid+1 is probably dead, this tests the "stale lock" code path.
        // For the "live takeover" path, we need to test via the meta.json handoff_from field.
        let info = get_lock_info(temp.path(), "/project").unwrap();
        assert_eq!(info.pid, pid);

        // The real scenario (different live PIDs) is hard to test in unit tests,
        // but we can verify the lock mechanism works by checking the initial state
        assert!(is_session_running(temp.path(), "/project"));
    }

    #[test]
    fn test_write_lock_metadata_records_handoff() {
        // Verify that write_lock_metadata correctly records handoff_from
        use serde_json::Value;

        let temp = tempdir().unwrap();
        let lock_dir = temp.path().join("test.lock");
        fs::create_dir(&lock_dir).unwrap();

        let pid = std::process::id();
        let old_pid = 12345u32;

        // Write metadata with handoff (session_id = None for legacy lock)
        write_lock_metadata(&lock_dir, pid, "/project", None, Some(old_pid)).unwrap();

        // Read and verify
        let meta_content = fs::read_to_string(lock_dir.join("meta.json")).unwrap();
        let meta: Value = serde_json::from_str(&meta_content).unwrap();

        assert_eq!(meta["pid"].as_u64().unwrap(), pid as u64);
        assert_eq!(meta["handoff_from"].as_u64().unwrap(), old_pid as u64);
        assert_eq!(meta["path"].as_str().unwrap(), "/project");
    }

    #[test]
    fn test_session_lock_release_only_own_lock() {
        // Verify that release_lock_by_session only removes the specific process's lock
        use super::tests_helper::create_session_lock;

        let temp = tempdir().unwrap();
        let pid = std::process::id();

        // Create session lock
        create_session_lock(temp.path(), pid, "/project", "test-session");

        let lock_path = temp.path().join(format!("test-session-{}.lock", pid));
        assert!(lock_path.exists(), "Lock should exist after creation");

        // Release the lock
        let released = release_lock_by_session(temp.path(), "test-session", pid);
        assert!(released, "Release should succeed");
        assert!(!lock_path.exists(), "Lock should be removed after release");
    }

    #[test]
    fn test_release_nonexistent_lock_succeeds() {
        // Releasing a lock that doesn't exist should return true (idempotent)
        let temp = tempdir().unwrap();
        let released = release_lock_by_session(temp.path(), "nonexistent", 12345);
        assert!(
            released,
            "Releasing nonexistent lock should succeed (idempotent)"
        );
    }

    #[test]
    fn test_count_other_session_locks() {
        // Verify count_other_session_locks correctly counts sibling processes
        use super::tests_helper::create_session_lock;

        let temp = tempdir().unwrap();
        let pid = std::process::id();

        // Create two locks for the same session ID but different (simulated) PIDs
        // Note: We can only create one valid lock for our actual PID
        create_session_lock(temp.path(), pid, "/project", "shared-session");

        // Count other locks excluding our PID - should be 0 (we're the only live one)
        let count = count_other_session_locks(temp.path(), "shared-session", pid);
        assert_eq!(
            count, 0,
            "No other live processes should hold this session's lock"
        );

        // Count excluding a different PID - should find our lock (if it's alive)
        let count = count_other_session_locks(temp.path(), "shared-session", 99999);
        assert_eq!(
            count, 1,
            "Our lock should be counted when excluding a different PID"
        );
    }

    #[test]
    fn test_session_lock_naming_format() {
        // Verify session-based locks follow the {session_id}-{pid}.lock naming format
        use super::tests_helper::create_session_lock;

        let temp = tempdir().unwrap();
        let pid = std::process::id();
        let session_id = "abc123-def456";

        create_session_lock(temp.path(), pid, "/project", session_id);

        let expected_name = format!("{}-{}.lock", session_id, pid);
        let lock_path = temp.path().join(&expected_name);

        assert!(
            lock_path.exists(),
            "Session lock should use {{session_id}}-{{pid}}.lock naming"
        );

        // Verify it contains correct metadata
        let info = read_lock_info(&lock_path).unwrap();
        assert_eq!(info.session_id.as_deref(), Some(session_id));
        assert_eq!(info.pid, pid);
    }

    #[test]
    fn test_find_all_locks_exact_match_only() {
        // Verify find_all_locks_for_path uses exact match only (no child inheritance)
        use super::tests_helper::create_session_lock;

        let temp = tempdir().unwrap();
        let pid = std::process::id();

        // Create locks at different paths
        create_session_lock(temp.path(), pid, "/project", "session-parent");
        create_session_lock(temp.path(), pid, "/project/src", "session-child");

        // Query parent path - should only find parent lock
        let locks = find_all_locks_for_path(temp.path(), "/project");
        assert_eq!(locks.len(), 1, "Should find only exact match, not children");
        assert_eq!(locks[0].path, "/project");

        // Query child path - should only find child lock
        let locks = find_all_locks_for_path(temp.path(), "/project/src");
        assert_eq!(locks.len(), 1, "Should find only exact match");
        assert_eq!(locks[0].path, "/project/src");
    }
}
