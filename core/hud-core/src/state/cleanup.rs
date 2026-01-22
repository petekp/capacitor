//! Startup cleanup for stale artifacts.
//!
//! Performs housekeeping when the HUD app launches:
//! 1. **Lock cleanup**: Removes locks with dead PIDs
//! 2. **Session cleanup**: Removes records older than 24 hours
//!
//! This runs once per app launch — frequent enough to prevent cruft accumulation,
//! infrequent enough to not impact performance.

use std::fs;
use std::path::Path;

use chrono::{Duration, Utc};

use super::lock::{is_pid_alive, read_lock_info};
use super::store::StateStore;

/// Maximum age for session records (24 hours).
const SESSION_MAX_AGE_HOURS: i64 = 24;

/// Maximum age for tombstones (1 minute).
/// Tombstones only need to survive race conditions, not long-term.
const TOMBSTONE_MAX_AGE_SECS: u64 = 60;

/// Results from a cleanup operation.
#[derive(Debug, Default, Clone, uniffi::Record)]
pub struct CleanupStats {
    /// Number of stale lock directories removed.
    pub locks_removed: u32,
    /// Number of old session records removed.
    pub sessions_removed: u32,
    /// Number of old tombstone files removed.
    pub tombstones_removed: u32,
    /// Errors encountered during cleanup.
    pub errors: Vec<String>,
}

/// Performs startup cleanup on all artifacts.
///
/// This is the main entry point called on app launch.
pub fn run_startup_cleanup(lock_base: &Path, state_file: &Path) -> CleanupStats {
    let mut stats = CleanupStats::default();

    // 1. Clean up stale locks
    let lock_stats = cleanup_stale_locks(lock_base);
    stats.locks_removed = lock_stats.locks_removed;
    stats.errors.extend(lock_stats.errors);

    // 2. Clean up old session records
    let session_stats = cleanup_old_sessions(state_file);
    stats.sessions_removed = session_stats.sessions_removed;
    stats.errors.extend(session_stats.errors);

    // 3. Clean up old tombstones
    // Tombstones dir is sibling to lock_base: ~/.capacitor/ended-sessions/
    if let Some(capacitor_dir) = lock_base.parent() {
        let tombstones_dir = capacitor_dir.join("ended-sessions");
        let tombstone_stats = cleanup_old_tombstones(&tombstones_dir);
        stats.tombstones_removed = tombstone_stats.tombstones_removed;
        stats.errors.extend(tombstone_stats.errors);
    }

    stats
}

/// Removes lock directories with dead PIDs.
///
/// Scans all `.lock` directories in the lock base and removes any where:
/// - The PID no longer exists
/// - The lock metadata is corrupt/unreadable
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

/// Removes session records older than 24 hours.
///
/// Uses `state_changed_at` as the age reference — this is when the session
/// last transitioned states, which is more meaningful than `updated_at`.
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

        // Create a stale lock
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

        assert_eq!(stats.locks_removed, 1);
        assert_eq!(stats.sessions_removed, 1);
        assert!(stats.errors.is_empty());
    }
}
