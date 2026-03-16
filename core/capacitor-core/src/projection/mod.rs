use crate::domain::AppSnapshot;
use crate::observation::ObservationRecord;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectorDescriptor {
    pub name: &'static str,
    pub version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectionCheckpoint {
    pub projector_name: &'static str,
    pub applied_observation_count: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SnapshotReadModel {
    pub snapshot: AppSnapshot,
    pub applied_observation_count: usize,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SnapshotReadModelProjector;

impl SnapshotReadModelProjector {
    #[must_use]
    pub fn descriptor(&self) -> ProjectorDescriptor {
        ProjectorDescriptor {
            name: "app_snapshot_read_model",
            version: 1,
        }
    }

    #[must_use]
    pub fn project(
        &self,
        snapshot: &AppSnapshot,
        observations: &[ObservationRecord],
    ) -> SnapshotReadModel {
        SnapshotReadModel {
            snapshot: snapshot.clone(),
            applied_observation_count: observations.len(),
        }
    }

    #[must_use]
    pub fn checkpoint(&self, observations: &[ObservationRecord]) -> ProjectionCheckpoint {
        ProjectionCheckpoint {
            projector_name: self.descriptor().name,
            applied_observation_count: observations.len(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SnapshotReadModelProjector;
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, ProjectSummary, RoutingStatus, RoutingTarget,
        RoutingTargetKind, RoutingView, SessionState, SessionSummary, ShellSignal,
    };
    use crate::observation::ObservationRecord;

    fn fixture_snapshot() -> AppSnapshot {
        AppSnapshot {
            projects: vec![ProjectSummary {
                project_path: "/repo".to_string(),
                project_id: "/repo/.git".to_string(),
                workspace_id: "workspace".to_string(),
                display_name: "repo".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-03-09T12:00:00Z".to_string(),
                updated_at: "2026-03-09T12:00:00Z".to_string(),
                representative_session_id: Some("session-1".to_string()),
                latest_session_id: Some("session-1".to_string()),
                session_count: 1,
                active_count: 1,
                has_session: true,
            }],
            sessions: vec![SessionSummary {
                session_id: "session-1".to_string(),
                pid: 42,
                cwd: "/repo".to_string(),
                project_id: "/repo/.git".to_string(),
                project_path: "/repo".to_string(),
                workspace_id: "workspace".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-03-09T12:00:00Z".to_string(),
                updated_at: "2026-03-09T12:00:00Z".to_string(),
                last_event: Some("user_prompt_submit".to_string()),
                last_activity_at: Some("2026-03-09T12:00:00Z".to_string()),
                tools_in_flight: 0,
                ready_reason: None,
            }],
            shells: vec![ShellSignal {
                pid: 42,
                cwd: "/repo".to_string(),
                tty: "/dev/ttys001".to_string(),
                parent_app: "ghostty".to_string(),
                tmux_session: None,
                tmux_client_tty: None,
                tmux_pane: None,
                tmux_panes: vec![],
                updated_at: "2026-03-09T12:00:00Z".to_string(),
            }],
            routing: vec![RoutingView {
                workspace_id: "workspace".to_string(),
                project_path: "/repo".to_string(),
                status: RoutingStatus::Detached,
                target: RoutingTarget {
                    kind: RoutingTargetKind::TerminalApp,
                    terminal_app: Some("ghostty".to_string()),
                    session_name: None,
                    pane_id: None,
                    host_tty: None,
                },
                reason_code: "fallback".to_string(),
                reason: "fallback".to_string(),
                updated_at: "2026-03-09T12:00:00Z".to_string(),
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
                last_hook_event_at: Some("2026-03-09T12:00:00Z".to_string()),
            },
            delegations: vec![],
            generated_at: "2026-03-09T12:00:00Z".to_string(),
        }
    }

    #[test]
    fn snapshot_read_model_projector_reports_descriptor_and_checkpoint() {
        let projector = SnapshotReadModelProjector;
        let checkpoint = projector.checkpoint(&[]);

        assert_eq!(projector.descriptor().name, "app_snapshot_read_model");
        assert_eq!(projector.descriptor().version, 1);
        assert_eq!(checkpoint.projector_name, "app_snapshot_read_model");
        assert_eq!(checkpoint.applied_observation_count, 0);
    }

    #[test]
    fn snapshot_read_model_projector_preserves_snapshot_and_observation_count() {
        let projector = SnapshotReadModelProjector;
        let snapshot = fixture_snapshot();
        let observations = vec![ObservationRecord::from_shell_signal(
            crate::domain::IngestShellSignalCommand {
                pid: 42,
                cwd: "/repo".to_string(),
                tty: "/dev/ttys001".to_string(),
                parent_app: "ghostty".to_string(),
                tmux_session: None,
                tmux_client_tty: None,
                tmux_pane: None,
                tmux_panes: vec![],
                recorded_at: "2026-03-09T12:00:00Z".to_string(),
            },
        )];

        let read_model = projector.project(&snapshot, &observations);

        assert_eq!(read_model.snapshot.projects.len(), 1);
        assert_eq!(read_model.snapshot.sessions.len(), 1);
        assert_eq!(read_model.applied_observation_count, 1);
    }
}
