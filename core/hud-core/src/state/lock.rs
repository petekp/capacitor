//! Lock file detection for Claude Code sessions.
//!
//! Lock directories indicate that a Claude Code process is actively running for a project.
//! The hook script creates these when a session starts; the lock holder (a background process)
//! releases them when Claude exits.
//!
//! # Lock Directory Structure
//!
//! Location: `~/.capacitor/sessions/{hash}.lock/` where `{hash}` is MD5 of the project path.
//! (Locks are in our namespace for sidecar purity—we never write to `~/.claude/`)
//!
//! ```text
//! {hash}.lock/
//! ├── pid          # Plain text: the Claude process ID
//! └── meta.json    # { pid, path, proc_started, created }
//! ```
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

use std::cell::RefCell;
use std::fs;
use std::path::Path;
use std::time::Instant;

use super::types::LockInfo;

// Thread-local sysinfo cache. We use per-PID refresh (O(1)) instead of scanning
// all processes (O(n)). This matters because lock checks happen on every UI refresh.
thread_local! {
    static SYSTEM_CACHE: RefCell<Option<(sysinfo::System, Instant)>> = const { RefCell::new(None) };
}

/// Normalize a path for consistent hashing and comparison.
/// Strips trailing slashes except for root "/".
/// Handles edge case where path is all slashes ("//", "///") → "/"
fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        // Path was all slashes → root
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Computes the lock directory name for a project path.
///
/// Lock directories are named `{hash}.lock` where hash is MD5 of the normalized path.
/// This allows O(1) lookup by path.
fn compute_lock_hash(path: &str) -> String {
    let normalized = normalize_path(path);
    format!("{:x}", md5::compute(normalized))
}

pub fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
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
        let (sys, _) = cache.get_or_insert_with(|| (System::new(), Instant::now()));

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

        let (sys, _) = cache.get_or_insert_with(|| (System::new(), Instant::now()));

        // Refresh ONLY this specific PID with cmd info for legacy verification
        let sysinfo_pid = Pid::from(pid as usize);
        sys.refresh_process_specifics(
            sysinfo_pid,
            ProcessRefreshKind::new().with_cmd(UpdateKind::Always),
        );

        if let Some(process) = sys.process(sysinfo_pid) {
            let name = process.name().to_lowercase();

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

    let info = LockInfo {
        pid,
        path,
        proc_started,
        created,
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
pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    // Check for exact lock match at this path
    if check_lock_for_path(lock_base, project_path).is_some() {
        return true;
    }

    // Check if any CHILD path has a lock (child makes parent active)
    find_child_lock(lock_base, project_path).is_some()
}

/// Returns lock metadata for the given path (exact or child match).
///
/// Returns `None` if no active lock exists. Use [`is_session_running`] for a simple
/// yes/no check without the metadata.
pub fn get_lock_info(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    // Check for exact lock match at this path
    if let Some(info) = check_lock_for_path(lock_base, project_path) {
        return Some(info);
    }

    // Check if any CHILD path has a lock
    find_child_lock(lock_base, project_path)
}

/// Scans for locks in child directories of the given path.
///
/// Example: If `project_path` is `/project`, this finds locks at `/project/src`,
/// `/project/apps/swift`, etc.
pub fn find_child_lock(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    let normalized = normalize_path(project_path);
    // Special case for root: children of "/" are paths starting with "/" (not "//")
    let prefix = if normalized == "/" {
        "/".to_string()
    } else {
        format!("{}/", normalized)
    };

    let entries = fs::read_dir(lock_base).ok()?;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                let info_path_normalized = normalize_path(&info.path);

                // For root, match any path except root itself (all paths except "/" are children of "/")
                let is_child = if normalized == "/" {
                    info_path_normalized != "/" && info_path_normalized.starts_with(&prefix)
                } else {
                    info_path_normalized.starts_with(&prefix)
                };

                if is_pid_alive_verified(info.pid, info.proc_started) && is_child {
                    return Some(info);
                }
            }
        }
    }

    None
}

/// Finds the best matching lock for resolver use.
///
/// Checks exact and child matches, optionally filtered by PID or path.
/// When multiple locks match, returns the one with the newest `created` timestamp
/// (tie-broken by path for determinism).
///
/// This is used by the resolver to associate a lock with a state record.
pub fn find_matching_child_lock(
    lock_base: &Path,
    project_path: &str,
    target_pid: Option<u32>,
    target_cwd: Option<&str>,
) -> Option<LockInfo> {
    // Normalize project_path for consistent comparison
    let project_path_normalized = normalize_path(project_path);
    // Special case for root: children of "/" are paths starting with "/" (not "//")
    let prefix = if project_path_normalized == "/" {
        "/".to_string()
    } else {
        format!("{}/", project_path_normalized)
    };

    let entries = fs::read_dir(lock_base).ok()?;

    let mut best_match: Option<LockInfo> = None;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().is_some_and(|e| e == "lock") {
            if let Some(info) = read_lock_info(&path) {
                if is_pid_alive_verified(info.pid, info.proc_started) {
                    let info_path_normalized = normalize_path(&info.path);

                    // Check for exact match or child match
                    let is_exact_match = info_path_normalized == project_path_normalized;
                    let is_child_match = if project_path_normalized == "/" {
                        info_path_normalized != "/" && info_path_normalized.starts_with(&prefix)
                    } else {
                        info_path_normalized.starts_with(&prefix)
                    };
                    let is_match = is_exact_match || is_child_match;

                    if is_match {
                        // Check if this lock matches the target criteria
                        let pid_matches = target_pid.map_or(true, |pid| pid == info.pid);
                        let path_matches = target_cwd.map_or(true, |cwd| cwd == info.path);

                        if pid_matches && path_matches {
                            // Keep the match with the newest 'created' timestamp
                            // With path-based tie-breaking for deterministic ordering
                            match &best_match {
                                None => best_match = Some(info),
                                Some(current) => {
                                    // Compare creation timestamps (not process start time)
                                    // If either is None (legacy), compare as 0
                                    let info_created = info.created.unwrap_or(0);
                                    let current_created = current.created.unwrap_or(0);

                                    if info_created > current_created {
                                        best_match = Some(info);
                                    } else if info_created == current_created {
                                        // Tie-breaker: lexicographic path comparison
                                        if info.path > current.path {
                                            best_match = Some(info);
                                        }
                                    }
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

/// Create a lock directory for a session.
///
/// Returns the path to the created lock directory, or None if creation failed
/// (e.g., another process already holds the lock).
pub fn create_lock(lock_base: &Path, project_path: &str, pid: u32) -> Option<std::path::PathBuf> {
    let hash = compute_lock_hash(project_path);
    let lock_dir = lock_base.join(format!("{}.lock", hash));

    // Ensure the parent lock directory exists
    if !lock_base.exists() {
        if let Err(e) = fs::create_dir_all(lock_base) {
            eprintln!("Warning: Failed to create lock base directory: {}", e);
            return None;
        }
    }

    // Try to create the lock directory atomically
    match fs::create_dir(&lock_dir) {
        Ok(()) => {
            // We created the lock, write metadata
            if write_lock_metadata(&lock_dir, pid, project_path, None).is_ok() {
                Some(lock_dir)
            } else {
                // Clean up on metadata write failure
                let _ = fs::remove_dir_all(&lock_dir);
                None
            }
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Lock already exists - check if it's stale or owned by us
            if let Some(info) = read_lock_info(&lock_dir) {
                if info.pid == pid {
                    // We already own this lock - don't spawn another holder
                    // The existing lock holder is already managing this lock
                    return None;
                }

                // Check if the existing lock holder is still alive
                if is_pid_alive_verified(info.pid, info.proc_started) {
                    // Lock is held by another live process
                    return None;
                }

                // Existing lock is stale, take it over
                let _ = fs::remove_dir_all(&lock_dir);
                if fs::create_dir(&lock_dir).is_ok()
                    && write_lock_metadata(&lock_dir, pid, project_path, None).is_ok()
                {
                    return Some(lock_dir);
                }
            } else {
                // Can't read existing lock, try to take it
                let _ = fs::remove_dir_all(&lock_dir);
                if fs::create_dir(&lock_dir).is_ok()
                    && write_lock_metadata(&lock_dir, pid, project_path, None).is_ok()
                {
                    return Some(lock_dir);
                }
            }
            None
        }
        Err(_) => None,
    }
}

/// Release a lock directory.
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
    write_lock_metadata(lock_dir, new_pid, project_path, handoff_from).is_ok()
}

/// Write lock metadata files (pid and meta.json).
fn write_lock_metadata(
    lock_dir: &Path,
    pid: u32,
    project_path: &str,
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
    });

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

/// Get the lock directory path for a project (without checking if it exists).
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

    /// Creates a valid lock for the current process.
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
                r#"{{"pid": {}, "path": "{}", "proc_started": {}, "created": {}}}"#,
                pid, path, proc_started, created
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
    fn test_parent_query_finds_child_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent/child");
        // Parent SHOULD find child lock (child makes parent active)
        assert!(is_session_running(temp.path(), "/parent"));
    }

    #[test]
    fn test_get_lock_info_finds_child_lock() {
        let temp = tempdir().unwrap();
        create_lock(temp.path(), std::process::id(), "/parent/child");
        let info = get_lock_info(temp.path(), "/parent").unwrap();
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
}
