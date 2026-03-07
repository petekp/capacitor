#![allow(dead_code)]

pub(crate) mod activation;
mod composition;
pub(crate) mod feedback;
pub(crate) mod ideas;
pub(crate) mod kernel;
pub(crate) mod projects;
pub(crate) mod runtime;
pub(crate) mod setup;

pub(crate) use composition::CleanArchitectureShell;

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, OnceLock};

    use super::CleanArchitectureShell;
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, ProjectSummary, RoutingStatus, RoutingTargetKind,
        RoutingView, SessionState, SessionSummary, ShellSignal,
    };
    use crate::runtime_setup::{DependencyStatus, HookStatus, SetupChecker};
    use crate::runtime_storage::StorageConfig;
    use crate::storage::InMemorySnapshotStorage;
    use tempfile::TempDir;

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    #[test]
    fn bootstrap_creates_all_context_services() {
        let shell = CleanArchitectureShell::bootstrap(
            Arc::new(InMemorySnapshotStorage::default()),
            StorageConfig::default(),
        );

        let _ = (
            &shell.runtime,
            &shell.setup,
            &shell.activation,
            &shell.projects,
            &shell.ideas,
            &shell.feedback,
        );
    }

    #[test]
    fn shell_runtime_snapshot_matches_authoritative_storage() {
        let storage = Arc::new(InMemorySnapshotStorage::default());
        let snapshot = fixture_snapshot();
        crate::storage::SnapshotStorage::save_snapshot(&*storage, &snapshot)
            .expect("save snapshot");

        let shell = CleanArchitectureShell::bootstrap(storage, StorageConfig::default());
        let loaded = shell.app_snapshot().expect("load snapshot from shell");

        assert_eq!(loaded.projects.len(), 1);
        assert_eq!(loaded.sessions.len(), 1);
        assert_eq!(loaded.shells.len(), 1);
        assert_eq!(loaded.projects[0].project_path, "/tmp/shell-project");
        assert_eq!(loaded.sessions[0].session_id, "session-shell");
    }

    #[test]
    fn shell_setup_status_matches_direct_checker() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let storage = StorageConfig::with_roots(
            temp_dir.path().join(".capacitor"),
            temp_dir.path().join(".claude"),
        );
        let shell = CleanArchitectureShell::bootstrap(
            Arc::new(InMemorySnapshotStorage::default()),
            storage.clone(),
        );

        let via_shell = shell.check_setup_status();
        let direct = SetupChecker::new(storage).check_setup_status();

        assert_dependency_statuses_match(&via_shell.dependencies, &direct.dependencies);
        assert_hook_status_matches(&via_shell.hooks, &direct.hooks);
        assert_eq!(via_shell.storage_ready, direct.storage_ready);
        assert_eq!(via_shell.all_ready, direct.all_ready);
        assert_eq!(via_shell.blocking_reason, direct.blocking_reason);
    }

    #[test]
    fn shell_check_dependency_matches_direct_checker() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let storage = StorageConfig::with_roots(
            temp_dir.path().join(".capacitor"),
            temp_dir.path().join(".claude"),
        );
        let shell = CleanArchitectureShell::bootstrap(
            Arc::new(InMemorySnapshotStorage::default()),
            storage.clone(),
        );

        let via_shell = shell.check_dependency("claude");
        let direct = SetupChecker::new(storage).check_dependency("claude");

        assert_eq!(via_shell.name, direct.name);
        assert_eq!(via_shell.required, direct.required);
        assert_eq!(via_shell.found, direct.found);
        assert_eq!(via_shell.path, direct.path);
        assert_eq!(via_shell.install_hint, direct.install_hint);
    }

    #[test]
    fn shell_run_hook_test_prioritizes_missing_heartbeat_message() {
        let _guard = env_lock();
        let temp = setup_hook_test_env();
        let _snapshot_env = EnvVarGuard::set(
            "CAPACITOR_CORE_SNAPSHOT",
            temp.snapshot_path.to_str().expect("snapshot path"),
        );
        let shell = CleanArchitectureShell::bootstrap(
            Arc::new(InMemorySnapshotStorage::default()),
            temp.storage.clone(),
        );

        let result = shell.run_hook_test();

        assert!(!result.success);
        assert!(!result.heartbeat_ok);
        assert!(!result.state_file_ok);
        assert_eq!(
            result.message,
            "No heartbeat detected. Start a Claude session to test hooks."
        );
    }

    #[test]
    fn shell_run_hook_test_reports_runtime_snapshot_failure_after_healthy_heartbeat() {
        let _guard = env_lock();
        let temp = setup_hook_test_env();
        let _snapshot_env = EnvVarGuard::set(
            "CAPACITOR_CORE_SNAPSHOT",
            temp.snapshot_path.to_str().expect("snapshot path"),
        );
        write_heartbeat(&temp.heartbeat_path);
        let shell = CleanArchitectureShell::bootstrap(
            Arc::new(InMemorySnapshotStorage::default()),
            temp.storage.clone(),
        );

        let result = shell.run_hook_test();

        assert!(!result.success);
        assert!(result.heartbeat_ok);
        assert!(!result.state_file_ok);
        assert_eq!(
            result.message,
            "Runtime health check failed. Ensure the runtime snapshot is available."
        );
    }

    fn fixture_snapshot() -> AppSnapshot {
        AppSnapshot {
            projects: vec![ProjectSummary {
                project_path: "/tmp/shell-project".to_string(),
                project_id: "project-shell".to_string(),
                workspace_id: "workspace-shell".to_string(),
                display_name: "shell-project".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-03-06T00:00:00Z".to_string(),
                updated_at: "2026-03-06T00:00:00Z".to_string(),
                representative_session_id: Some("session-shell".to_string()),
                latest_session_id: Some("session-shell".to_string()),
                session_count: 1,
                active_count: 1,
                has_session: true,
            }],
            sessions: vec![SessionSummary {
                session_id: "session-shell".to_string(),
                pid: 42,
                cwd: "/tmp/shell-project".to_string(),
                project_id: "project-shell".to_string(),
                project_path: "/tmp/shell-project".to_string(),
                workspace_id: "workspace-shell".to_string(),
                state: SessionState::Working,
                state_changed_at: "2026-03-06T00:00:00Z".to_string(),
                updated_at: "2026-03-06T00:00:00Z".to_string(),
                last_event: Some("user_prompt_submit".to_string()),
                last_activity_at: Some("2026-03-06T00:00:00Z".to_string()),
                tools_in_flight: 0,
                ready_reason: None,
            }],
            shells: vec![ShellSignal {
                pid: 42,
                cwd: "/tmp/shell-project".to_string(),
                tty: "/dev/ttys042".to_string(),
                parent_app: "Ghostty".to_string(),
                tmux_session: Some("shell".to_string()),
                tmux_client_tty: Some("/dev/ttys043".to_string()),
                updated_at: "2026-03-06T00:00:00Z".to_string(),
            }],
            routing: vec![RoutingView {
                workspace_id: "workspace-shell".to_string(),
                project_path: "/tmp/shell-project".to_string(),
                status: RoutingStatus::Attached,
                target_kind: RoutingTargetKind::TmuxSession,
                target_value: Some("shell".to_string()),
                reason_code: "test".to_string(),
                reason: "fixture".to_string(),
                updated_at: "2026-03-06T00:00:00Z".to_string(),
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
            },
            generated_at: "2026-03-06T00:00:00Z".to_string(),
        }
    }

    fn assert_dependency_statuses_match(
        actual: &[DependencyStatus],
        expected: &[DependencyStatus],
    ) {
        assert_eq!(actual.len(), expected.len());
        for (left, right) in actual.iter().zip(expected.iter()) {
            assert_eq!(left.name, right.name);
            assert_eq!(left.required, right.required);
            assert_eq!(left.found, right.found);
            assert_eq!(left.path, right.path);
            assert_eq!(left.install_hint, right.install_hint);
        }
    }

    fn assert_hook_status_matches(actual: &HookStatus, expected: &HookStatus) {
        match (actual, expected) {
            (HookStatus::NotInstalled, HookStatus::NotInstalled) => {}
            (HookStatus::Installed { version: left }, HookStatus::Installed { version: right }) => {
                assert_eq!(left, right)
            }
            (
                HookStatus::PolicyBlocked { reason: left },
                HookStatus::PolicyBlocked { reason: right },
            ) => assert_eq!(left, right),
            (
                HookStatus::BinaryBroken { reason: left },
                HookStatus::BinaryBroken { reason: right },
            ) => assert_eq!(left, right),
            (
                HookStatus::SymlinkBroken {
                    target: left_target,
                    reason: left_reason,
                },
                HookStatus::SymlinkBroken {
                    target: right_target,
                    reason: right_reason,
                },
            ) => {
                assert_eq!(left_target, right_target);
                assert_eq!(left_reason, right_reason);
            }
            _ => panic!("hook status variants differed"),
        }
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("env lock")
    }

    struct EnvVarGuard {
        key: &'static str,
        prior: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, prior }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.prior {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    struct HookTestEnv {
        _temp: TempDir,
        storage: StorageConfig,
        heartbeat_path: std::path::PathBuf,
        snapshot_path: std::path::PathBuf,
    }

    fn setup_hook_test_env() -> HookTestEnv {
        let temp = tempfile::tempdir().expect("temp dir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));
        let heartbeat_path = storage.root().join("hud-hook-heartbeat");
        std::fs::create_dir_all(storage.root()).expect("create app storage dir");
        let snapshot_path = temp.path().join("missing-runtime-snapshot.json");

        HookTestEnv {
            _temp: temp,
            storage,
            heartbeat_path,
            snapshot_path,
        }
    }

    fn write_heartbeat(path: &std::path::Path) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create heartbeat dir");
        }
        std::fs::write(path, b"beat").expect("write heartbeat");
    }
}
