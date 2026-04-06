mod observation_journal;

use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use crate::domain::AppSnapshot;
pub use observation_journal::{InMemoryObservationJournalStore, ObservationJournalStore};

/// Snapshot disk format version (incremented when AppSnapshot serialization changes).
pub(crate) const CURRENT_SNAPSHOT_SCHEMA_VERSION: u32 = 1;

pub trait SnapshotStorage: Send + Sync {
    fn load_snapshot(&self) -> Result<Option<AppSnapshot>, String>;
    fn save_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), String>;
}

#[derive(Default)]
pub(crate) struct InMemorySnapshotStorage {
    snapshot: std::sync::Mutex<Option<AppSnapshot>>,
}

impl SnapshotStorage for InMemorySnapshotStorage {
    fn load_snapshot(&self) -> Result<Option<AppSnapshot>, String> {
        let guard = self
            .snapshot
            .lock()
            .map_err(|_| "snapshot lock poisoned".to_string())?;
        Ok(guard.clone())
    }

    fn save_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), String> {
        let mut guard = self
            .snapshot
            .lock()
            .map_err(|_| "snapshot lock poisoned".to_string())?;
        *guard = Some(snapshot.clone());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Advisory file lock (cross-process) via flock(2)
// ---------------------------------------------------------------------------

/// RAII guard that holds an exclusive advisory lock on a `.lock` sidecar file.
/// The lock is released automatically when the guard is dropped.
struct FileLockGuard {
    file: fs::File,
}

impl FileLockGuard {
    /// Opens (or creates) the lock file at `lock_path` and acquires an
    /// exclusive `flock`. Retries with a 5-second timeout to avoid hanging
    /// the FFI caller if another process holds the lock indefinitely.
    fn acquire(lock_path: &Path) -> Result<Self, String> {
        // Ensure parent directory exists so we can create the lock file.
        if let Some(parent) = lock_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed creating lock file directory: {e}"))?;
        }

        let file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(lock_path)
            .map_err(|e| format!("failed opening lock file {}: {e}", lock_path.display()))?;

        // LOCK_NB = non-blocking attempt; retry with backoff up to 5 seconds.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let ret = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if ret == 0 {
                return Ok(Self { file });
            }
            let err = std::io::Error::last_os_error();
            if err.kind() != std::io::ErrorKind::WouldBlock {
                return Err(format!(
                    "failed acquiring file lock on {}: {err}",
                    lock_path.display()
                ));
            }
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "timed out waiting for file lock on {}",
                    lock_path.display()
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}

impl Drop for FileLockGuard {
    fn drop(&mut self) {
        // Best-effort unlock. The OS also releases the lock when the fd is
        // closed, but explicit unlock lets other waiters proceed immediately.
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

pub(crate) struct JsonFileSnapshotStorage {
    path: PathBuf,
    io_lock: std::sync::Mutex<()>,
}

enum SnapshotFileReadError {
    Missing,
    Io(String),
    Parse(String),
}

impl JsonFileSnapshotStorage {
    pub(crate) fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            io_lock: std::sync::Mutex::new(()),
        }
    }

    /// Returns the path for the advisory `.lock` sidecar file.
    fn lock_path(snapshot_path: &Path) -> PathBuf {
        let file_name = snapshot_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("snapshot.json");
        snapshot_path.with_file_name(format!("{file_name}.lock"))
    }

    /// Builds a unique temp file path that incorporates the current process ID
    /// to prevent collisions when multiple processes race.
    fn temp_path(snapshot_path: &Path) -> PathBuf {
        let file_name = snapshot_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("snapshot.json");
        let pid = std::process::id();
        snapshot_path.with_file_name(format!("{file_name}.tmp.{pid}"))
    }

    fn ensure_parent_dir(path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("failed creating snapshot directory: {error}"))?;
        }
        Ok(())
    }

    fn backup_path(path: &Path) -> PathBuf {
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("snapshot.json");
        path.with_file_name(format!("{file_name}.prev"))
    }

    fn read_snapshot_file(path: &Path) -> Result<AppSnapshot, SnapshotFileReadError> {
        if !path.exists() {
            return Err(SnapshotFileReadError::Missing);
        }

        let payload = fs::read_to_string(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                SnapshotFileReadError::Missing
            } else {
                SnapshotFileReadError::Io(format!("failed reading snapshot file: {error}"))
            }
        })?;
        let snapshot = serde_json::from_str::<AppSnapshot>(&payload)
            .map_err(|error| SnapshotFileReadError::Parse(error.to_string()))?;
        Ok(snapshot)
    }

    fn load_backup_snapshot(&self, reason: &str) -> Option<AppSnapshot> {
        let backup_path = Self::backup_path(&self.path);
        let snapshot = match Self::read_snapshot_file(&backup_path) {
            Ok(snapshot) => snapshot,
            Err(_) => return None,
        };

        eprintln!(
            "[capacitor-core] falling back to snapshot backup after {reason}: {}",
            backup_path.display()
        );

        Some(snapshot)
    }
}

impl SnapshotStorage for JsonFileSnapshotStorage {
    fn load_snapshot(&self) -> Result<Option<AppSnapshot>, String> {
        let _guard = self
            .io_lock
            .lock()
            .map_err(|_| "snapshot lock poisoned".to_string())?;

        // Cross-process advisory lock.
        let _file_lock = FileLockGuard::acquire(&Self::lock_path(&self.path))?;

        match Self::read_snapshot_file(&self.path) {
            Ok(snapshot) => {
                if snapshot.schema_version != CURRENT_SNAPSHOT_SCHEMA_VERSION {
                    let quarantine_path = self.path.with_extension("json.quarantined");
                    if let Err(e) = fs::rename(&self.path, &quarantine_path) {
                        eprintln!("[capacitor-core] failed to quarantine snapshot: {e}");
                    } else {
                        eprintln!(
                            "[capacitor-core] quarantined snapshot with schema version {} (expected {}): {}",
                            snapshot.schema_version, CURRENT_SNAPSHOT_SCHEMA_VERSION, quarantine_path.display()
                        );
                    }
                    Ok(None)
                } else {
                    Ok(Some(snapshot))
                }
            }
            Err(SnapshotFileReadError::Missing) => {
                Ok(self.load_backup_snapshot("primary snapshot missing"))
            }
            Err(SnapshotFileReadError::Parse(error)) => {
                Ok(self.load_backup_snapshot(&format!("primary snapshot parse failure ({error})")))
            }
            Err(SnapshotFileReadError::Io(error)) => Err(error),
        }
    }

    fn save_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), String> {
        let _guard = self
            .io_lock
            .lock()
            .map_err(|_| "snapshot lock poisoned".to_string())?;

        // Cross-process advisory lock.
        let _file_lock = FileLockGuard::acquire(&Self::lock_path(&self.path))?;

        Self::ensure_parent_dir(&self.path)?;

        let mut versioned = snapshot.clone();
        versioned.schema_version = CURRENT_SNAPSHOT_SCHEMA_VERSION;
        let payload = serde_json::to_vec_pretty(&versioned)
            .map_err(|error| format!("failed serializing snapshot: {error}"))?;

        let temp_path = Self::temp_path(&self.path);

        fs::write(&temp_path, &payload)
            .map_err(|error| format!("failed writing snapshot temp file: {error}"))?;

        let temp_file = fs::File::open(&temp_path)
            .map_err(|e| format!("failed opening temp file for sync: {e}"))?;
        temp_file
            .sync_data()
            .map_err(|e| format!("failed syncing temp file: {e}"))?;

        if self.path.exists() {
            let backup = Self::backup_path(&self.path);
            let _ = fs::remove_file(&backup);
            if let Err(e) = fs::hard_link(&self.path, &backup) {
                eprintln!("[capacitor-core] warning: backup hard-link failed (non-fatal): {e}");
            }
        }
        fs::rename(&temp_path, &self.path)
            .map_err(|error| format!("failed replacing snapshot file: {error}"))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::{Arc, Barrier};

    use super::{JsonFileSnapshotStorage, SnapshotStorage};
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, InvolvementLevel, PhaseInstance, PhaseStatus,
        ProjectSummary, RoutingTarget, RoutingView, RunState, RunStatus, SessionState,
        SessionSummary, ShellSignal,
    };

    fn fixture_snapshot(label: &str, run_count: usize) -> AppSnapshot {
        let runs = (0..run_count)
            .map(|index| {
                let timestamp = format!("2026-02-28T00:00:{index:02}Z");
                RunState {
                    id: format!("run-{label}-{index}"),
                    project_path: "/repo".to_string(),
                    method_id: "method.test".to_string(),
                    method_name: format!("Method {label}"),
                    involvement: InvolvementLevel::Supervised,
                    status: RunStatus::Active,
                    phases: vec![PhaseInstance {
                        id: "phase-001".to_string(),
                        template_id: "phase-template".to_string(),
                        name: "Execution".to_string(),
                        status: PhaseStatus::Active,
                        checkpoint_policy: "manual".to_string(),
                        skill_hint: None,
                        started_at: Some(timestamp.clone()),
                        completed_at: None,
                    }],
                    current_phase_index: 0,
                    active_checkpoint: None,
                    session_id: Some("session-1".to_string()),
                    delegation_worker_id: None,
                    status_message: Some(format!("status-{label}-{index}")),
                    idea_id: Some(format!("idea-{label}-{index}")),
                    idea_title: Some(format!("Idea {label} {index}")),
                    idea_description: Some(format!("Description {label} {index}")),
                    created_at: timestamp.clone(),
                    updated_at: timestamp,
                }
            })
            .collect();

        AppSnapshot {
            projects: vec![ProjectSummary {
                project_path: "/repo".to_string(),
                project_id: "/repo/.git".to_string(),
                workspace_id: "workspace".to_string(),
                display_name: "repo".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-02-28T00:00:00Z".to_string(),
                updated_at: "2026-02-28T00:00:00Z".to_string(),
                representative_session_id: Some("session-1".to_string()),
                latest_session_id: Some("session-1".to_string()),
                session_count: 1,
                active_count: 1,
                has_session: true,
            }],
            sessions: vec![SessionSummary {
                session_id: "session-1".to_string(),
                pid: 10,
                cwd: "/repo".to_string(),
                project_id: "/repo/.git".to_string(),
                project_path: "/repo".to_string(),
                workspace_id: "workspace".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-02-28T00:00:00Z".to_string(),
                updated_at: "2026-02-28T00:00:00Z".to_string(),
                last_event: Some("user_prompt_submit".to_string()),
                last_activity_at: Some("2026-02-28T00:00:00Z".to_string()),
                tools_in_flight: 0,
                ready_reason: None,
                is_alive: true,
                gc_reason: None,
            }],
            shells: vec![ShellSignal {
                pid: 10,
                cwd: "/repo".to_string(),
                tty: "/dev/ttys001".to_string(),
                parent_app: "ghostty".to_string(),
                tmux_session: None,
                tmux_client_tty: None,
                tmux_pane: None,
                tmux_panes: vec![],
                updated_at: "2026-02-28T00:00:00Z".to_string(),
            }],
            routing: vec![RoutingView {
                workspace_id: "workspace".to_string(),
                project_path: "/repo".to_string(),
                status: crate::domain::RoutingStatus::Detached,
                target: RoutingTarget {
                    kind: crate::domain::RoutingTargetKind::TerminalApp,
                    terminal_app: Some("ghostty".to_string()),
                    session_name: None,
                    pane_id: None,
                    host_tty: None,
                },
                reason_code: "fallback".to_string(),
                reason: "fallback".to_string(),
                updated_at: "2026-02-28T00:00:00Z".to_string(),
            }],
            diagnostics: DiagnosticsSummary {
                events_ingested: 1,
                sessions_tracked: 1,
                shell_signals_tracked: 1,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
                last_hook_event_at: Some("2026-02-28T00:00:00Z".to_string()),
            },
            delegations: vec![],
            runs,
            generated_at: "2026-02-28T00:00:00Z".to_string(),
            snapshot_version: 0,
            schema_version: 0,
        }
    }

    #[test]
    fn json_file_snapshot_storage_round_trips() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = JsonFileSnapshotStorage::new(&path);
        let snapshot = fixture_snapshot("round-trip", 1);
        storage.save_snapshot(&snapshot).expect("save");

        let loaded = storage
            .load_snapshot()
            .expect("load")
            .expect("snapshot exists");

        assert_eq!(loaded.projects.len(), 1);
        assert_eq!(loaded.sessions.len(), 1);
        assert_eq!(loaded.projects[0].project_path, "/repo");
        assert_eq!(loaded.runs.len(), 1);
        assert_eq!(loaded.runs[0].id, "run-round-trip-0");
    }

    #[test]
    fn test_backup_created_on_save() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let backup_path = temp_dir
            .path()
            .join("snapshot")
            .join("app_snapshot.json.prev");

        let storage = JsonFileSnapshotStorage::new(&path);
        let first_snapshot = fixture_snapshot("first", 1);
        let second_snapshot = fixture_snapshot("second", 2);

        storage.save_snapshot(&first_snapshot).expect("save first");
        storage
            .save_snapshot(&second_snapshot)
            .expect("save second");

        let backup_payload = fs::read_to_string(&backup_path).expect("read backup");
        let backup_snapshot: AppSnapshot =
            serde_json::from_str(&backup_payload).expect("parse backup snapshot");
        let primary_payload = fs::read_to_string(&path).expect("read primary");
        let primary_snapshot: AppSnapshot =
            serde_json::from_str(&primary_payload).expect("parse primary snapshot");

        assert_eq!(backup_snapshot.runs.len(), 1);
        assert_eq!(backup_snapshot.runs[0].id, "run-first-0");
        assert_eq!(primary_snapshot.runs.len(), 2);
        assert_eq!(primary_snapshot.runs[0].id, "run-second-0");
    }

    #[test]
    fn test_fallback_loads_backup_on_corrupt_primary() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let backup_path = temp_dir
            .path()
            .join("snapshot")
            .join("app_snapshot.json.prev");

        JsonFileSnapshotStorage::ensure_parent_dir(&path).expect("create parent dir");
        let backup_snapshot = fixture_snapshot("backup", 1);
        let backup_payload =
            serde_json::to_string_pretty(&backup_snapshot).expect("serialize backup");

        fs::write(&backup_path, backup_payload).expect("write backup");
        fs::write(&path, "{ not valid json").expect("write corrupt primary");

        let storage = JsonFileSnapshotStorage::new(&path);
        let loaded = storage
            .load_snapshot()
            .expect("load should not error")
            .expect("backup snapshot should load");

        assert_eq!(loaded.runs.len(), 1);
        assert_eq!(loaded.runs[0].id, "run-backup-0");
        assert_eq!(loaded.generated_at, backup_snapshot.generated_at);
    }

    #[test]
    fn test_fallback_returns_none_when_both_missing() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = JsonFileSnapshotStorage::new(&path);

        assert!(storage.load_snapshot().expect("load").is_none());
    }

    // -----------------------------------------------------------------------
    // Wave 2: File locking and unique temp file tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_concurrent_saves_produce_valid_snapshot() {
        // Spawn two threads that each save a different snapshot simultaneously.
        // After both finish, the file on disk must be valid JSON matching one
        // of the two payloads — never a corrupted mix.
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = Arc::new(JsonFileSnapshotStorage::new(&path));
        let barrier = Arc::new(Barrier::new(2));

        let snapshot_a = fixture_snapshot("thread-a", 3);
        let snapshot_b = fixture_snapshot("thread-b", 5);

        let s1 = Arc::clone(&storage);
        let b1 = Arc::clone(&barrier);
        let sa = snapshot_a.clone();
        let handle_a = std::thread::spawn(move || {
            b1.wait();
            s1.save_snapshot(&sa).expect("save from thread A");
        });

        let s2 = Arc::clone(&storage);
        let b2 = Arc::clone(&barrier);
        let sb = snapshot_b.clone();
        let handle_b = std::thread::spawn(move || {
            b2.wait();
            s2.save_snapshot(&sb).expect("save from thread B");
        });

        handle_a.join().expect("thread A panicked");
        handle_b.join().expect("thread B panicked");

        // The file must be valid JSON.
        let final_payload = fs::read_to_string(&path).expect("read final snapshot");
        let final_snapshot: AppSnapshot =
            serde_json::from_str(&final_payload).expect("final snapshot must be valid JSON");

        // It must match one of the two payloads exactly.
        let matches_a =
            final_snapshot.runs.len() == 3 && final_snapshot.runs[0].id.starts_with("run-thread-a");
        let matches_b =
            final_snapshot.runs.len() == 5 && final_snapshot.runs[0].id.starts_with("run-thread-b");
        assert!(
            matches_a || matches_b,
            "final snapshot must match thread-a (3 runs) or thread-b (5 runs), got {} runs with first id {:?}",
            final_snapshot.runs.len(),
            final_snapshot.runs.first().map(|r| &r.id),
        );
    }

    #[test]
    fn test_lock_file_lifecycle() {
        use super::FileLockGuard;

        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let lock_path = temp_dir
            .path()
            .join("snapshot")
            .join("app_snapshot.json.lock");

        let storage = JsonFileSnapshotStorage::new(&path);
        let snapshot = fixture_snapshot("lock-lifecycle", 1);
        storage.save_snapshot(&snapshot).expect("save");

        // After save, the lock file should exist on disk.
        assert!(
            lock_path.exists(),
            "lock file must exist after save: {}",
            lock_path.display()
        );

        // Drop the storage so its in-process mutex is gone.
        drop(storage);

        // Another caller should be able to acquire the file lock immediately,
        // proving the previous lock was released.
        let guard = FileLockGuard::acquire(&lock_path);
        assert!(
            guard.is_ok(),
            "should be able to acquire lock after storage is dropped"
        );
        drop(guard);
    }

    #[test]
    fn test_temp_file_includes_pid() {
        let path = PathBuf::from("/tmp/test/app_snapshot.json");
        let temp = JsonFileSnapshotStorage::temp_path(&path);

        let pid = std::process::id();
        let expected_name = format!("app_snapshot.json.tmp.{pid}");

        assert_eq!(
            temp.file_name().and_then(|n| n.to_str()),
            Some(expected_name.as_str()),
            "temp file name must include process ID"
        );
        assert_eq!(
            temp.parent(),
            path.parent(),
            "temp file must be in the same directory as the snapshot"
        );
    }

    use std::path::PathBuf;

    // -----------------------------------------------------------------------
    // Wave 3: Disk-full handling and schema migration tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_save_succeeds_when_backup_hardlink_fails() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let backup_path = temp_dir
            .path()
            .join("snapshot")
            .join("app_snapshot.json.prev");

        let storage = JsonFileSnapshotStorage::new(&path);
        let first = fixture_snapshot("first", 1);
        storage.save_snapshot(&first).expect("save first");

        // Create a directory at the backup path so hard_link will fail
        fs::remove_file(&backup_path).ok();
        fs::create_dir_all(backup_path.join("blocker")).expect("create blocking dir");

        let second = fixture_snapshot("second", 2);
        storage.save_snapshot(&second).expect("save second");

        let loaded = storage
            .load_snapshot()
            .expect("load")
            .expect("snapshot exists");
        assert_eq!(loaded.runs.len(), 2);
        assert_eq!(loaded.runs[0].id, "run-second-0");
    }

    #[test]
    fn test_save_stamps_schema_version_and_syncs() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = JsonFileSnapshotStorage::new(&path);
        let snapshot = fixture_snapshot("sync-test", 1);
        assert_eq!(snapshot.schema_version, 0, "fixture should have version 0");

        storage.save_snapshot(&snapshot).expect("save");

        let raw = fs::read_to_string(&path).expect("read raw file");
        let on_disk: AppSnapshot = serde_json::from_str(&raw).expect("parse");
        assert_eq!(
            on_disk.schema_version,
            super::CURRENT_SNAPSHOT_SCHEMA_VERSION,
            "save should stamp schema_version"
        );
        assert_eq!(on_disk.runs.len(), 1);
        assert_eq!(on_disk.runs[0].id, "run-sync-test-0");
    }

    #[test]
    fn test_load_quarantines_legacy_schema_version() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let quarantine_path = path.with_extension("json.quarantined");

        JsonFileSnapshotStorage::ensure_parent_dir(&path).expect("create parent dir");

        let legacy = fixture_snapshot("legacy", 1);
        assert_eq!(legacy.schema_version, 0);
        let payload = serde_json::to_string_pretty(&legacy).expect("serialize");
        fs::write(&path, payload).expect("write legacy snapshot");

        let storage = JsonFileSnapshotStorage::new(&path);
        let loaded = storage.load_snapshot().expect("load should not error");

        assert!(loaded.is_none(), "legacy snapshot should be quarantined");
        assert!(
            quarantine_path.exists(),
            "quarantine file should exist at {}",
            quarantine_path.display()
        );
        assert!(
            !path.exists(),
            "original file should be moved to quarantine"
        );
    }

    #[test]
    fn test_load_accepts_current_schema_version() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = JsonFileSnapshotStorage::new(&path);
        let snapshot = fixture_snapshot("current", 1);
        storage.save_snapshot(&snapshot).expect("save");

        let loaded = storage
            .load_snapshot()
            .expect("load")
            .expect("current-version snapshot should load");
        assert_eq!(
            loaded.schema_version,
            super::CURRENT_SNAPSHOT_SCHEMA_VERSION
        );
        assert_eq!(loaded.runs.len(), 1);
        assert_eq!(loaded.runs[0].id, "run-current-0");
    }

    #[test]
    fn test_load_quarantines_future_schema_version() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");
        let quarantine_path = path.with_extension("json.quarantined");

        JsonFileSnapshotStorage::ensure_parent_dir(&path).expect("create parent dir");

        let mut future = fixture_snapshot("future", 1);
        future.schema_version = super::CURRENT_SNAPSHOT_SCHEMA_VERSION + 99;
        let payload = serde_json::to_string_pretty(&future).expect("serialize");
        fs::write(&path, payload).expect("write future snapshot");

        let storage = JsonFileSnapshotStorage::new(&path);
        let loaded = storage.load_snapshot().expect("load should not error");

        assert!(
            loaded.is_none(),
            "future-version snapshot should be quarantined"
        );
        assert!(quarantine_path.exists(), "quarantine file should exist");
    }
}
