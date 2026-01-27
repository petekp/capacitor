//! Startup cleanup for old and orphaned artifacts.
//!
//! ## Terminology
//!
//! - **Stale**: Record not updated in 5 minutes (may still be valid, just quiet)
//! - **Expired**: Record older than 24 hours (definitely old, should be removed)
//! - **Orphaned**: Lock/process whose monitored PID is dead
//!
//! ## Cleanup Operations
//!
//! Performs housekeeping when the HUD app launches:
//! 1. **Orphaned lock holders**: Kills lock-holder processes monitoring dead PIDs
//! 2. **Orphaned locks**: Removes lock directories with dead PIDs
//! 3. **Orphaned sessions**: Removes stale session records without active locks
//! 4. **Expired sessions**: Removes session records older than 24 hours
//! 5. **Old tombstones**: Removes tombstone files older than 1 minute
//! 6. **Old activity**: Removes file activity entries older than 24 hours
//!
//! This runs once per app launch — frequent enough to prevent cruft accumulation,
//! infrequent enough to not impact performance.

use fs_err as fs;
use std::collections::HashSet;
use std::path::Path;

use chrono::{Duration, Utc};

use super::lock::{is_pid_alive, read_lock_info};
use super::store::StateStore;
use crate::activity::{ActivityStore, CLEANUP_THRESHOLD};

use sysinfo::{ProcessRefreshKind, System, UpdateKind};

/// Maximum age for session records (24 hours).
const SESSION_MAX_AGE_HOURS: i64 = 24;

/// Maximum age for tombstones (1 minute).
/// Tombstones only need to survive race conditions, not long-term.
const TOMBSTONE_MAX_AGE_SECS: u64 = 60;

/// Kills orphaned lock-holder processes whose monitored PID is dead.
///
/// Lock-holder processes (`hud-hook lock-holder --pid <PID>`) monitor Claude processes
/// and release locks when they exit. If the lock-holder itself is killed before it can
/// clean up, or if its monitored PID somehow exited without triggering cleanup, the
/// lock-holder becomes orphaned.
///
/// This function:
/// 1. Enumerates all processes whose command contains "hud-hook" and "lock-holder"
/// 2. Parses the --pid argument to find the monitored PID
/// 3. Sends SIGTERM to lock-holders whose monitored PID is dead
///
/// Safety: Only kills processes where the monitored PID is confirmed dead.
/// This prevents killing active lock-holders that are legitimately monitoring live processes.
pub fn cleanup_orphaned_lock_holders() -> CleanupStats {
    let mut stats = CleanupStats::default();

    // Initialize sysinfo with command line info
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessRefreshKind::new().with_cmd(UpdateKind::Always));

    for (pid, process) in sys.processes() {
        let cmd = process.cmd();

        // Look for lock-holder processes
        // Command format: hud-hook lock-holder --session_id <ID> --cwd <PATH> --pid <PID>
        let is_lock_holder = cmd.iter().any(|arg| arg.contains("hud-hook"))
            && cmd.iter().any(|arg| arg == "lock-holder");

        if !is_lock_holder {
            continue;
        }

        // Parse the --pid argument to find which PID this holder is monitoring
        let monitored_pid = parse_monitored_pid(cmd);

        let Some(monitored) = monitored_pid else {
            // Can't determine which PID is being monitored - skip to be safe
            continue;
        };

        // Check if the monitored PID is still alive
        if is_pid_alive(monitored) {
            // Monitored process is still alive - this is a legitimate lock holder
            continue;
        }

        // Monitored PID is dead - this lock holder is orphaned
        // Send SIGTERM to give it a chance to clean up gracefully
        #[cfg(unix)]
        {
            let holder_pid = pid.as_u32() as i32;
            // SAFETY: libc::kill with SIGTERM is a standard POSIX signal delivery.
            // The holder_pid is obtained from sysinfo enumeration, so it's a valid PID.
            // SIGTERM allows graceful shutdown. If the process already exited, we get ESRCH.
            #[allow(unsafe_code)]
            unsafe {
                if libc::kill(holder_pid, libc::SIGTERM) == 0 {
                    stats.orphaned_processes_killed += 1;
                } else {
                    // Failed to kill - might have already exited
                    let errno = *libc::__error();
                    if errno != libc::ESRCH {
                        // ESRCH = no such process (already dead), not an error
                        stats.errors.push(format!(
                            "Failed to kill orphaned lock-holder PID {}: errno {}",
                            holder_pid, errno
                        ));
                    }
                }
            }
        }
    }

    stats
}

/// Parses the --pid argument from a lock-holder command line.
fn parse_monitored_pid(cmd: &[String]) -> Option<u32> {
    let mut found_pid_flag = false;
    for arg in cmd {
        if found_pid_flag {
            return arg.parse().ok();
        }
        if arg == "--pid" {
            found_pid_flag = true;
        }
    }
    None
}

/// Results from a cleanup operation.
#[derive(Debug, Default, Clone, uniffi::Record)]
pub struct CleanupStats {
    /// Number of orphaned lock directories removed (dead PIDs).
    pub locks_removed: u32,
    /// Number of legacy MD5-hash locks removed (dead PIDs).
    pub legacy_locks_removed: u32,
    /// Number of orphaned lock-holder processes killed (monitoring dead PIDs).
    pub orphaned_processes_killed: u32,
    /// Number of orphaned session records removed (stale + no active lock).
    pub orphaned_sessions_removed: u32,
    /// Number of expired session records removed (> 24 hours old).
    pub sessions_removed: u32,
    /// Number of old tombstone files removed (> 1 minute old).
    pub tombstones_removed: u32,
    /// Number of old file activity entries cleaned up (> 24 hours old).
    pub activity_entries_removed: u32,
    /// Errors encountered during cleanup.
    pub errors: Vec<String>,
}

/// Performs startup cleanup on all artifacts.
///
/// This is the main entry point called on app launch.
///
/// # Race Condition (Accepted)
///
/// This function follows a read-modify-write pattern on `sessions.json` without
/// file locking. If a hook event fires during cleanup, the hook's write could be
/// lost when cleanup saves its modified state. This risk is accepted because:
///
/// 1. Cleanup runs only at app launch (very low frequency)
/// 2. The race window is small (milliseconds)
/// 3. Lost events self-heal on next hook event (state is refreshed)
///
/// Adding file locking would add complexity for marginal benefit.
pub fn run_startup_cleanup(lock_base: &Path, state_file: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    // 0. Kill orphaned lock-holder processes FIRST (before cleaning lock files)
    // This prevents race conditions where we clean a lock file but leave the holder running
    let process_stats = cleanup_orphaned_lock_holders();
    stats.orphaned_processes_killed = process_stats.orphaned_processes_killed;
    stats.errors.extend(process_stats.errors);

    // 1. Clean up legacy MD5-hash locks (dead PIDs only)
    let legacy_stats = cleanup_legacy_locks(lock_base);
    stats.legacy_locks_removed = legacy_stats.legacy_locks_removed;
    stats.errors.extend(legacy_stats.errors);

    // 2. Clean up stale locks (dead PIDs)
    let lock_stats = cleanup_stale_locks(lock_base);
    stats.locks_removed = lock_stats.locks_removed;
    stats.errors.extend(lock_stats.errors);

    // 3. Clean up orphaned session records (no active lock)
    // This is important for v4 session-based locks: when a session ends,
    // its lock is released but the record may linger. Without the stale Ready
    // fallback, these orphaned records should be cleaned up.
    let orphan_stats = cleanup_orphaned_sessions(lock_base, state_file);
    stats.orphaned_sessions_removed = orphan_stats.orphaned_sessions_removed;
    stats.errors.extend(orphan_stats.errors);

    // 4. Clean up old session records (> 24 hours)
    let session_stats = cleanup_old_sessions(state_file);
    stats.sessions_removed = session_stats.sessions_removed;
    stats.errors.extend(session_stats.errors);

    // 5. Clean up old tombstones
    // Tombstones dir is sibling to lock_base: ~/.capacitor/ended-sessions/
    if let Some(capacitor_dir) = lock_base.parent() {
        let tombstones_dir = capacitor_dir.join("ended-sessions");
        let tombstone_stats = cleanup_old_tombstones(&tombstones_dir);
        stats.tombstones_removed = tombstone_stats.tombstones_removed;
        stats.errors.extend(tombstone_stats.errors);
    }

    // 6. Clean up old file activity entries
    // Activity file is sibling to state file: ~/.capacitor/file-activity.json
    let activity_file = state_file.with_file_name("file-activity.json");
    if activity_file.exists() {
        let mut activity_store = ActivityStore::load(&activity_file);
        let entries_before: u32 = activity_store
            .sessions
            .values()
            .map(|s| s.activity.len() as u32)
            .sum();
        activity_store.cleanup_old_entries(CLEANUP_THRESHOLD);
        let entries_after: u32 = activity_store
            .sessions
            .values()
            .map(|s| s.activity.len() as u32)
            .sum();
        stats.activity_entries_removed = entries_before.saturating_sub(entries_after);

        if let Err(e) = activity_store.save(&activity_file) {
            stats
                .errors
                .push(format!("Failed to save activity file: {}", e));
        }
    }

    stats
}

/// Removes orphaned lock directories (dead PIDs or corrupt metadata).
///
/// Scans all `.lock` directories in the lock base and removes any where:
/// - The PID no longer exists (orphaned - the process has exited)
/// - The lock metadata is corrupt/unreadable
///
/// Note: Despite the name, this checks PID liveness, not timestamp staleness.
fn cleanup_stale_locks(lock_base: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(e) => {
            if e.kind() != std::io::ErrorKind::NotFound {
                stats
                    .errors
                    .push(format!("Failed to read lock directory: {}", e));
            }
            return stats;
        }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() || !path.extension().is_some_and(|e| e == "lock") {
            continue;
        }

        let should_remove = match read_lock_info(&path) {
            Some(info) => !is_pid_alive(info.pid),
            None => true, // Corrupt or unreadable lock — remove it
        };

        if should_remove {
            if let Err(e) = fs::remove_dir_all(&path) {
                stats.errors.push(format!(
                    "Failed to remove stale lock {}: {}",
                    path.display(),
                    e
                ));
            } else {
                stats.locks_removed += 1;
            }
        }
    }

    stats
}

/// Removes legacy MD5-hash format locks.
///
/// Legacy locks use the format `{32-hex-chars}.lock` (MD5 hash of path).
/// Modern session-based locks use `{session_id}-{pid}.lock` (contain "-").
///
/// This cleans up locks created by old versions of hud-hook that used
/// path-based locking instead of session-based locking.
fn cleanup_legacy_locks(lock_base: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(e) => {
            if e.kind() != std::io::ErrorKind::NotFound {
                stats
                    .errors
                    .push(format!("Failed to read lock directory: {}", e));
            }
            return stats;
        }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() || !path.extension().is_some_and(|e| e == "lock") {
            continue;
        }

        // Check if this is a legacy MD5-hash lock
        // Legacy: abc123def456...lock (32 hex chars, no "-")
        // v4:     {session_id}-{pid}.lock (contains "-")
        let is_legacy = path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|name| {
                // Legacy locks are exactly 32 hex chars with no hyphen
                name.len() == 32
                    && !name.contains('-')
                    && name.chars().all(|c| c.is_ascii_hexdigit())
            })
            .unwrap_or(false);

        if !is_legacy {
            continue;
        }

        // Read lock info and check if PID is dead
        let should_remove = match read_lock_info(&path) {
            Some(info) => !is_pid_alive(info.pid),
            None => true, // Corrupt or unreadable lock — remove it
        };

        if should_remove {
            if let Err(e) = fs::remove_dir_all(&path) {
                stats.errors.push(format!(
                    "Failed to remove legacy lock {}: {}",
                    path.display(),
                    e
                ));
            } else {
                stats.legacy_locks_removed += 1;
            }
        }
    }

    stats
}

/// Removes session records that don't have an active lock.
///
/// With v4 session-based locks, when a session ends its lock is released
/// by session ID. Session records without active locks are orphaned and
/// should be removed to prevent state pollution.
///
/// Note: This only removes records that are stale (> 5 minutes old) to avoid
/// race conditions where a record exists but the lock hasn't been created yet.
fn cleanup_orphaned_sessions(lock_base: &Path, state_file: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    let mut store = match StateStore::load(state_file) {
        Ok(s) => s,
        Err(e) => {
            stats
                .errors
                .push(format!("Failed to load state file: {}", e));
            return stats;
        }
    };

    // Collect all active session IDs from locks
    let active_session_ids: HashSet<String> = collect_active_session_ids(lock_base);

    // Find orphaned session records (stale records with no active lock)
    let orphaned_session_ids: Vec<String> = store
        .sessions()
        .filter(|r| {
            // Only consider stale records to avoid race conditions
            if !r.is_stale() {
                return false;
            }

            // Check if this session has an active lock
            // For session-based locks (v4), we look for {session_id}.lock
            // For legacy path-based locks (v3), we'd need path matching
            !active_session_ids.contains(&r.session_id)
        })
        .map(|r| r.session_id.clone())
        .collect();

    if orphaned_session_ids.is_empty() {
        return stats;
    }

    for session_id in &orphaned_session_ids {
        store.remove(session_id);
        stats.orphaned_sessions_removed += 1;
    }

    if let Err(e) = store.save() {
        stats
            .errors
            .push(format!("Failed to save cleaned state file: {}", e));
    }

    stats
}

/// Collects all session IDs from active locks.
fn collect_active_session_ids(lock_base: &Path) -> HashSet<String> {
    let mut session_ids = HashSet::new();

    let entries = match fs::read_dir(lock_base) {
        Ok(e) => e,
        Err(_) => return session_ids,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() || !path.extension().is_some_and(|e| e == "lock") {
            continue;
        }

        if let Some(info) = read_lock_info(&path) {
            // Only consider alive locks
            if is_pid_alive(info.pid) {
                // For session-based locks, session_id is in meta.json
                if let Some(sid) = info.session_id {
                    session_ids.insert(sid);
                }
                // For legacy path-based locks, we can extract from lock dir name
                // but those don't have session_id, so we skip them
            }
        }
    }

    session_ids
}

/// Removes tombstone files older than 1 minute.
///
/// Tombstones are used to prevent race conditions where events arrive after
/// SessionEnd. They only need to live long enough to block stray events.
fn cleanup_old_tombstones(tombstones_dir: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    let entries = match fs::read_dir(tombstones_dir) {
        Ok(e) => e,
        Err(e) => {
            if e.kind() != std::io::ErrorKind::NotFound {
                stats
                    .errors
                    .push(format!("Failed to read tombstones directory: {}", e));
            }
            return stats;
        }
    };

    let now = std::time::SystemTime::now();

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let should_remove = match path.metadata().and_then(|m| m.modified()) {
            Ok(modified) => now
                .duration_since(modified)
                .map(|d| d.as_secs() > TOMBSTONE_MAX_AGE_SECS)
                .unwrap_or(true),
            Err(_) => true, // Can't read metadata — remove it
        };

        if should_remove {
            if let Err(e) = fs::remove_file(&path) {
                stats.errors.push(format!(
                    "Failed to remove tombstone {}: {}",
                    path.display(),
                    e
                ));
            } else {
                stats.tombstones_removed += 1;
            }
        }
    }

    stats
}

/// Removes expired session records (older than 24 hours).
///
/// Uses `state_changed_at` as the age reference — this is when the session
/// last transitioned states, which is more meaningful than `updated_at`.
///
/// "Expired" means beyond the 24-hour retention threshold, regardless of
/// whether the session has an active lock or recent updates.
fn cleanup_old_sessions(state_file: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    let mut store = match StateStore::load(state_file) {
        Ok(s) => s,
        Err(e) => {
            stats
                .errors
                .push(format!("Failed to load state file: {}", e));
            return stats;
        }
    };

    let cutoff = Utc::now() - Duration::hours(SESSION_MAX_AGE_HOURS);

    let old_session_ids: Vec<String> = store
        .sessions()
        .filter(|r| r.state_changed_at < cutoff)
        .map(|r| r.session_id.clone())
        .collect();

    if old_session_ids.is_empty() {
        return stats;
    }

    for session_id in &old_session_ids {
        store.remove(session_id);
        stats.sessions_removed += 1;
    }

    if let Err(e) = store.save() {
        stats
            .errors
            .push(format!("Failed to save cleaned state file: {}", e));
    }

    stats
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn create_lock_with_pid(lock_base: &Path, path: &str, pid: u32) {
        let hash = format!("{:x}", md5::compute(path));
        let lock_dir = lock_base.join(format!("{}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("pid"), pid.to_string()).unwrap();
        fs::write(
            lock_dir.join("meta.json"),
            format!(r#"{{"pid": {}, "path": "{}"}}"#, pid, path),
        )
        .unwrap();
    }

    #[test]
    fn cleanup_removes_stale_locks_with_dead_pids() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("sessions");
        fs::create_dir_all(&lock_base).unwrap();

        // Create a lock with a dead PID (99999999 is unlikely to exist)
        create_lock_with_pid(&lock_base, "/dead/project", 99999999);

        // Create a lock with our live PID
        create_lock_with_pid(&lock_base, "/live/project", std::process::id());

        let stats = cleanup_stale_locks(&lock_base);

        assert_eq!(stats.locks_removed, 1, "Should remove 1 stale lock");
        assert!(stats.errors.is_empty(), "Should have no errors");

        // Verify dead lock is gone
        let dead_hash = format!("{:x}", md5::compute("/dead/project"));
        assert!(
            !lock_base.join(format!("{}.lock", dead_hash)).exists(),
            "Dead lock should be removed"
        );

        // Verify live lock remains
        let live_hash = format!("{:x}", md5::compute("/live/project"));
        assert!(
            lock_base.join(format!("{}.lock", live_hash)).exists(),
            "Live lock should remain"
        );
    }

    #[test]
    fn cleanup_removes_corrupt_locks() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("sessions");
        fs::create_dir_all(&lock_base).unwrap();

        // Create a corrupt lock (missing pid file)
        let hash = format!("{:x}", md5::compute("/corrupt/project"));
        let lock_dir = lock_base.join(format!("{}.lock", hash));
        fs::create_dir_all(&lock_dir).unwrap();
        fs::write(lock_dir.join("meta.json"), "{}").unwrap(); // No pid field

        let stats = cleanup_stale_locks(&lock_base);

        assert_eq!(stats.locks_removed, 1, "Should remove corrupt lock");
        assert!(!lock_dir.exists(), "Corrupt lock should be removed");
    }

    #[test]
    fn cleanup_handles_missing_lock_directory() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("nonexistent");

        let stats = cleanup_stale_locks(&lock_base);

        assert_eq!(stats.locks_removed, 0);
        assert!(stats.errors.is_empty(), "Missing dir is not an error");
    }

    #[test]
    fn cleanup_removes_old_sessions() {
        let temp = tempdir().unwrap();
        let state_file = temp.path().join("sessions.json");

        // Create state file with an old session
        let old_time = Utc::now() - Duration::hours(25);
        let content = serde_json::json!({
            "version": 3,
            "sessions": {
                "old-session": {
                    "session_id": "old-session",
                    "state": "ready",
                    "cwd": "/old/project",
                    "updated_at": old_time.to_rfc3339(),
                    "state_changed_at": old_time.to_rfc3339()
                },
                "new-session": {
                    "session_id": "new-session",
                    "state": "ready",
                    "cwd": "/new/project",
                    "updated_at": Utc::now().to_rfc3339(),
                    "state_changed_at": Utc::now().to_rfc3339()
                }
            }
        });
        fs::write(&state_file, serde_json::to_string_pretty(&content).unwrap()).unwrap();

        let stats = cleanup_old_sessions(&state_file);

        assert_eq!(stats.sessions_removed, 1, "Should remove 1 old session");
        assert!(stats.errors.is_empty(), "Should have no errors");

        // Verify the state file was updated
        let store = StateStore::load(&state_file).unwrap();
        assert!(
            store.get_by_session_id("old-session").is_none(),
            "Old session should be gone"
        );
        assert!(
            store.get_by_session_id("new-session").is_some(),
            "New session should remain"
        );
    }

    #[test]
    fn cleanup_handles_missing_state_file() {
        let temp = tempdir().unwrap();
        let state_file = temp.path().join("nonexistent.json");

        let stats = cleanup_old_sessions(&state_file);

        assert_eq!(stats.sessions_removed, 0);
        assert!(stats.errors.is_empty(), "Missing file is not an error");
    }

    #[test]
    fn run_startup_cleanup_combines_all_cleanups() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("sessions");
        let state_file = temp.path().join("sessions.json");
        fs::create_dir_all(&lock_base).unwrap();

        // Create a stale lock (legacy format - 32 hex char hash)
        create_lock_with_pid(&lock_base, "/stale/project", 99999999);

        // Create state file with an old session
        let old_time = Utc::now() - Duration::hours(25);
        let content = serde_json::json!({
            "version": 3,
            "sessions": {
                "old-session": {
                    "session_id": "old-session",
                    "state": "ready",
                    "cwd": "/old/project",
                    "updated_at": old_time.to_rfc3339(),
                    "state_changed_at": old_time.to_rfc3339()
                }
            }
        });
        fs::write(&state_file, serde_json::to_string_pretty(&content).unwrap()).unwrap();

        let stats = run_startup_cleanup(&lock_base, &state_file);

        // The stale lock is a legacy MD5-hash lock (create_lock_with_pid uses legacy format),
        // so it's cleaned by legacy_locks cleanup. Modern session-based locks would be
        // counted in locks_removed.
        let total_locks_removed = stats.locks_removed + stats.legacy_locks_removed;
        assert_eq!(
            total_locks_removed, 1,
            "Should remove 1 stale lock (either modern or legacy)"
        );
        // v4: The old session is first cleaned up by orphaned session cleanup
        // (stale record without a lock), so sessions_removed may be 0
        // The total removed should be 1 (either as orphaned or old)
        let total_sessions_removed = stats.orphaned_sessions_removed + stats.sessions_removed;
        assert_eq!(total_sessions_removed, 1, "Old session should be removed");
        assert!(stats.errors.is_empty());
    }

    #[test]
    fn cleanup_orphaned_sessions_removes_stale_records_without_locks() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("sessions");
        let state_file = temp.path().join("sessions.json");
        fs::create_dir_all(&lock_base).unwrap();

        // Create state file with a stale session that has no lock
        let stale_time = Utc::now() - Duration::minutes(10);
        let content = serde_json::json!({
            "version": 3,
            "sessions": {
                "orphaned-session": {
                    "session_id": "orphaned-session",
                    "state": "ready",
                    "cwd": "/orphaned/project",
                    "updated_at": stale_time.to_rfc3339(),
                    "state_changed_at": stale_time.to_rfc3339()
                }
            }
        });
        fs::write(&state_file, serde_json::to_string_pretty(&content).unwrap()).unwrap();

        let stats = cleanup_orphaned_sessions(&lock_base, &state_file);

        assert_eq!(
            stats.orphaned_sessions_removed, 1,
            "Should remove orphaned session"
        );
        assert!(stats.errors.is_empty());

        // Verify the session was removed
        let store = StateStore::load(&state_file).unwrap();
        assert!(store.get_by_session_id("orphaned-session").is_none());
    }

    #[test]
    fn cleanup_orphaned_sessions_keeps_fresh_records() {
        let temp = tempdir().unwrap();
        let lock_base = temp.path().join("sessions");
        let state_file = temp.path().join("sessions.json");
        fs::create_dir_all(&lock_base).unwrap();

        // Create state file with a fresh session (no lock, but not stale)
        let content = serde_json::json!({
            "version": 3,
            "sessions": {
                "fresh-session": {
                    "session_id": "fresh-session",
                    "state": "working",
                    "cwd": "/fresh/project",
                    "updated_at": Utc::now().to_rfc3339(),
                    "state_changed_at": Utc::now().to_rfc3339()
                }
            }
        });
        fs::write(&state_file, serde_json::to_string_pretty(&content).unwrap()).unwrap();

        let stats = cleanup_orphaned_sessions(&lock_base, &state_file);

        assert_eq!(
            stats.orphaned_sessions_removed, 0,
            "Should not remove fresh records"
        );

        // Verify the session still exists
        let store = StateStore::load(&state_file).unwrap();
        assert!(store.get_by_session_id("fresh-session").is_some());
    }
}
