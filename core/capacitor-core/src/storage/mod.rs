mod observation_journal;

use std::fs;
use std::path::{Path, PathBuf};

use crate::domain::AppSnapshot;
pub use observation_journal::{InMemoryObservationJournalStore, ObservationJournalStore};

pub trait SnapshotStorage: Send + Sync {
    fn load_snapshot(&self) -> Result<Option<AppSnapshot>, String>;
    fn save_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), String>;
}

#[derive(Default)]
pub struct InMemorySnapshotStorage {
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

pub struct JsonFileSnapshotStorage {
    path: PathBuf,
    io_lock: std::sync::Mutex<()>,
}

enum SnapshotFileReadError {
    Missing,
    Io(String),
    Parse(String),
}

impl JsonFileSnapshotStorage {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            io_lock: std::sync::Mutex::new(()),
        }
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

        match Self::read_snapshot_file(&self.path) {
            Ok(snapshot) => Ok(Some(snapshot)),
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

        Self::ensure_parent_dir(&self.path)?;

        let payload = serde_json::to_vec_pretty(snapshot)
            .map_err(|error| format!("failed serializing snapshot: {error}"))?;

        let file_name = self
            .path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("snapshot.json");
        let temp_path = self.path.with_file_name(format!("{file_name}.tmp"));

        fs::write(&temp_path, payload)
            .map_err(|error| format!("failed writing snapshot temp file: {error}"))?;
        if self.path.exists() {
            fs::copy(&self.path, Self::backup_path(&self.path))
                .map_err(|error| format!("failed creating snapshot backup: {error}"))?;
        }
        fs::rename(&temp_path, &self.path)
            .map_err(|error| format!("failed replacing snapshot file: {error}"))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

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
}
