use std::cell::RefCell;
use std::fs;
use std::path::Path;
use std::time::Instant;

use super::types::LockInfo;

// Thread-local cache for sysinfo System with last refresh timestamp
// Avoids repeated process list refreshes which are expensive (~250ms each)
thread_local! {
    static SYSTEM_CACHE: RefCell<Option<(sysinfo::System, Instant)>> = RefCell::new(None);
}

// Minimum interval between process list refreshes (in milliseconds)
const REFRESH_INTERVAL_MS: u64 = 500;

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
/// Uses thread-local cache with staleness-based refresh to avoid expensive
/// repeated process list refreshes (which take ~250ms each).
pub fn get_process_start_time(pid: u32) -> Option<u64> {
    use sysinfo::{Pid, ProcessRefreshKind, RefreshKind, System};
    use std::time::Duration;

    SYSTEM_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();

        let needs_refresh = match &*cache {
            None => true,
            Some((_, last_refresh)) => last_refresh.elapsed() > Duration::from_millis(REFRESH_INTERVAL_MS),
        };

        if needs_refresh {
            let sys = cache.get_or_insert_with(|| {
                (System::new_with_specifics(
                    RefreshKind::new().with_processes(ProcessRefreshKind::new()),
                ), Instant::now())
            });
            sys.0.refresh_processes_specifics(ProcessRefreshKind::new());
            sys.1 = Instant::now();
        }

        cache.as_ref()
            .and_then(|(sys, _)| sys.process(Pid::from(pid as usize)))
            .map(|process| process.start_time())
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
    use sysinfo::{Pid, ProcessRefreshKind, RefreshKind, System};
    use std::time::Duration;

    // Basic PID check
    if !is_pid_alive(pid) {
        return false;
    }

    // Additional mitigation: verify process identity
    // Check both name and cmd for "claude" to handle node-based execution
    // This reduces (but doesn't eliminate) PID reuse risk
    SYSTEM_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();

        let needs_refresh = match &*cache {
            None => true,
            Some((_, last_refresh)) => last_refresh.elapsed() > Duration::from_millis(REFRESH_INTERVAL_MS),
        };

        if needs_refresh {
            let sys = cache.get_or_insert_with(|| {
                (System::new_with_specifics(
                    RefreshKind::new().with_processes(ProcessRefreshKind::new()),
                ), Instant::now())
            });
            sys.0.refresh_processes_specifics(ProcessRefreshKind::new());
            sys.1 = Instant::now();
        }

        let Some((sys, _)) = cache.as_ref() else {
            return false;
        };

        if let Some(process) = sys.process(Pid::from(pid as usize)) {
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
    // If no expected start time, use legacy checks (PID + process name)
    let Some(expected_start_time) = expected_start else {
        return is_pid_alive_with_legacy_checks(pid);
    };

    // Get actual process start time
    if let Some(actual_start) = get_process_start_time(pid) {
        // Allow ±2 second tolerance for timing differences between bash calculation and sysinfo
        let diff = if actual_start > expected_start_time {
            actual_start - expected_start_time
        } else {
            expected_start_time - actual_start
        };

        diff <= 2
    } else {
        // Process doesn't exist or can't be queried
        false
    }
}

fn read_lock_info(lock_dir: &Path) -> Option<LockInfo> {
    let pid_path = lock_dir.join("pid");
    let meta_path = lock_dir.join("meta.json");

    let pid_str = fs::read_to_string(&pid_path).ok()?;
    let pid: u32 = pid_str.trim().parse().ok()?;

    let meta_content = fs::read_to_string(&meta_path).ok()?;
    let meta: serde_json::Value = serde_json::from_str(&meta_content).ok()?;

    let path = meta.get("path")?.as_str()?.to_string();

    // Handle proc_started (PID verification)
    let proc_started = meta.get("proc_started")
        .and_then(|v| v.as_u64());

    // Handle created (lock selection) - check both new and legacy fields
    let created = meta.get("created")
        .and_then(|v| v.as_u64())
        .or_else(|| {
            // Fallback to old "started" field for backward compatibility
            meta.get("started").and_then(|v| match v {
                serde_json::Value::Number(n) => n.as_u64(),
                serde_json::Value::String(_) => None, // ISO string - ignore
                _ => None,
            })
        });

    let info = LockInfo { pid, path, proc_started, created };

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
                            let mtime_ms = modified.duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
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
                        let mtime_ms = modified.duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
                        now_ms.saturating_sub(mtime_ms)
                    } else {
                        86_400_001
                    }
                } else {
                    86_400_001
                }
            }
        };

        if lock_age_ms > 86_400_000 { // 24 hours in milliseconds
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

pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    // Check for exact lock match at this path
    if check_lock_for_path(lock_base, project_path).is_some() {
        return true;
    }

    // Check if any CHILD path has a lock (child makes parent active)
    // Do NOT check parent paths (parent lock should not make child active)
    find_child_lock(lock_base, project_path).is_some()
}

pub fn get_lock_info(lock_base: &Path, project_path: &str) -> Option<LockInfo> {
    // Check for exact lock match at this path
    if let Some(info) = check_lock_for_path(lock_base, project_path) {
        return Some(info);
    }

    // Check if any CHILD path has a lock
    find_child_lock(lock_base, project_path)
}

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

/// Find a lock that matches the given PID and/or path
/// Checks both exact matches and child locks
/// When multiple locks match, returns the one with the newest 'started' timestamp
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

#[cfg(test)]
pub mod tests_helper {
    use super::compute_lock_hash;
    use std::fs;
    use std::path::Path;

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

    pub fn create_lock_with_timestamps(lock_base: &Path, pid: u32, path: &str, proc_started: u64, created: u64) {
        let hash = compute_lock_hash(path);
        let lock_dir = lock_base.join(format!("{}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();
        fs::write(
            lock_dir.join("meta.json"),
            format!(r#"{{"pid": {}, "path": "{}", "proc_started": {}, "created": {}}}"#, pid, path, proc_started, created),
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
}
