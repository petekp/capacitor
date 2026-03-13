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
}

impl SnapshotStorage for JsonFileSnapshotStorage {
    fn load_snapshot(&self) -> Result<Option<AppSnapshot>, String> {
        let _guard = self
            .io_lock
            .lock()
            .map_err(|_| "snapshot lock poisoned".to_string())?;

        if !self.path.exists() {
            return Ok(None);
        }

        let payload = fs::read_to_string(&self.path)
            .map_err(|error| format!("failed reading snapshot file: {error}"))?;
        let snapshot = serde_json::from_str::<AppSnapshot>(&payload)
            .map_err(|error| format!("failed parsing snapshot file: {error}"))?;
        Ok(Some(snapshot))
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
        fs::rename(&temp_path, &self.path)
            .map_err(|error| format!("failed replacing snapshot file: {error}"))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{JsonFileSnapshotStorage, SnapshotStorage};
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, ProjectSummary, RoutingTarget, RoutingView, SessionState,
        SessionSummary, ShellSignal,
    };

    fn fixture_snapshot() -> AppSnapshot {
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
            }],
            shells: vec![ShellSignal {
                pid: 10,
                cwd: "/repo".to_string(),
                tty: "/dev/ttys001".to_string(),
                parent_app: "ghostty".to_string(),
                tmux_session: None,
                tmux_client_tty: None,
                tmux_pane: None,
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
            generated_at: "2026-02-28T00:00:00Z".to_string(),
        }
    }

    #[test]
    fn json_file_snapshot_storage_round_trips() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let path = temp_dir.path().join("snapshot").join("app_snapshot.json");

        let storage = JsonFileSnapshotStorage::new(&path);
        let snapshot = fixture_snapshot();
        storage.save_snapshot(&snapshot).expect("save");

        let loaded = storage
            .load_snapshot()
            .expect("load")
            .expect("snapshot exists");

        assert_eq!(loaded.projects.len(), 1);
        assert_eq!(loaded.sessions.len(), 1);
        assert_eq!(loaded.projects[0].project_path, "/repo");
    }
}
