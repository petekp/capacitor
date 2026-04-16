use super::{CoreRuntime, VersionNotifier};
use crate::domain::{
    default_workspace_id, AppSnapshot, DelegationMutationKind, DiagnosticsSummary, HookEventType,
    IdeaMutationKind, IngestHookEventCommand, IngestShellSignalCommand, MutateDelegationCommand,
    MutateIdeaCommand, MutateProjectCommand, MutateRunCommand, MutateWorktreeCommand,
    ProjectMutationKind, ProjectSummary, RunMutationKind, SessionState, SessionSummary,
    ShellUnregisterCommand, WorktreeMutationKind,
};
use crate::runtime::service::{RUNTIME_SERVICE_PORT_ENV, RUNTIME_SERVICE_TOKEN_ENV};
use crate::runtime::state::snapshot::test_support::{
    env_lock as shared_env_lock, MockRuntimeService, MockRuntimeServiceRoute,
};
use crate::runtime::state::snapshot::{RuntimeSessionRecord, RuntimeSessionsSnapshot};
use crate::runtime::storage::StorageConfig;
use crate::runtime::types::{HookHealthStatus, HookIssue};
use crate::storage::{InMemorySnapshotStorage, SnapshotStorage};
use chrono::{Duration, Utc};
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration as StdDuration, Instant};
use tempfile::TempDir;

const IGNORED_SNAPSHOT_ENV_NAME: &str = concat!("CAPACITOR_", "CORE_", "SNAPSHOT");

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

fn env_lock() -> std::sync::MutexGuard<'static, ()> {
    shared_env_lock()
}

#[test]
fn runtime_tracks_project_and_session_in_snapshot() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .mutate_project(MutateProjectCommand {
            kind: ProjectMutationKind::Add,
            project_path: "/repo".to_string(),
            display_name: Some("repo".to_string()),
        })
        .expect("add project");

    runtime
        .ingest_hook_event(IngestHookEventCommand {
            event_id: "evt-1".to_string(),
            recorded_at: "2099-02-28T00:00:00Z".to_string(),
            event_type: HookEventType::UserPromptSubmit,
            session_id: "session-1".to_string(),
            pid: Some(42),
            project_path: "/repo".to_string(),
            cwd: Some("/repo".to_string()),
            file_path: None,
            workspace_id: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            agent_id: None,
            teammate_name: None,
        })
        .expect("ingest event");

    let snapshot = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snapshot.projects.len(), 1);
    assert_eq!(snapshot.sessions.len(), 1);
    assert_eq!(snapshot.sessions[0].project_path, "/repo");
    assert_eq!(snapshot.projects[0].session_count, 1);
}

#[test]
fn test_snapshot_version_increments_on_mutation() {
    let runtime = CoreRuntime::new().expect("runtime");

    let initial = runtime.app_snapshot().expect("initial snapshot");
    assert_eq!(initial.snapshot_version, 0);

    runtime
        .ingest_hook_event(IngestHookEventCommand {
            event_id: "evt-1".to_string(),
            recorded_at: "2099-04-01T12:00:00Z".to_string(),
            event_type: HookEventType::UserPromptSubmit,
            session_id: "session-1".to_string(),
            pid: Some(42),
            project_path: "/repo".to_string(),
            cwd: Some("/repo".to_string()),
            file_path: None,
            workspace_id: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            agent_id: None,
            teammate_name: None,
        })
        .expect("ingest hook event");

    let updated = runtime.app_snapshot().expect("updated snapshot");
    assert!(
        updated.snapshot_version > initial.snapshot_version,
        "expected mutation to advance snapshot version, got {} -> {}",
        initial.snapshot_version,
        updated.snapshot_version
    );
}

#[test]
fn test_snapshot_version_stable_on_read() {
    let runtime = CoreRuntime::new().expect("runtime");

    let first = runtime.app_snapshot().expect("first snapshot");
    let second = runtime.app_snapshot().expect("second snapshot");

    assert_eq!(first.snapshot_version, second.snapshot_version);
}

#[test]
fn test_snapshot_idempotent_without_gc() {
    let storage = Arc::new(InMemorySnapshotStorage::default());
    storage
        .save_snapshot(&stale_dead_snapshot_for_gc_read_test())
        .expect("save fixture snapshot");
    let runtime = CoreRuntime::from_storage(storage, StorageConfig::default()).expect("runtime");

    let first = runtime.app_snapshot().expect("first snapshot");
    let second = runtime.app_snapshot().expect("second snapshot");

    assert_eq!(first.snapshot_version, 0);
    assert_eq!(second.snapshot_version, 0);
    assert_eq!(first.sessions, second.sessions);
    assert_eq!(first.sessions.len(), 1);
    assert_eq!(first.sessions[0].state, SessionState::Waiting);

    let mut normalized_first = first.clone();
    normalized_first.generated_at = second.generated_at.clone();
    assert_eq!(normalized_first, second);
}

#[test]
fn test_version_notifier_immediate_return() {
    let notifier = VersionNotifier::new();
    let version = AtomicU64::new(5);

    let start = Instant::now();
    let changed = notifier.wait_for_change(&version, 3, StdDuration::from_secs(1));

    assert_eq!(changed, Some(5));
    assert!(
        start.elapsed() < StdDuration::from_millis(50),
        "immediate version mismatch should not block",
    );
}

#[test]
fn test_version_notifier_wait_and_wake() {
    let runtime = CoreRuntime::new().expect("runtime");
    let since_version = current_version(runtime.as_ref());
    let worker_runtime = Arc::clone(&runtime);

    let worker = thread::spawn(move || {
        thread::sleep(StdDuration::from_millis(100));
        worker_runtime
            .ingest_hook_event(make_hook_event_command("evt-wake", "session-wake", "/repo"))
            .expect("ingest hook event");
    });

    let start = Instant::now();
    let changed = runtime.wait_for_version_change(since_version, StdDuration::from_secs(5));
    let elapsed = start.elapsed();

    worker.join().expect("worker thread");

    assert_eq!(changed, Some(since_version + 1));
    assert!(
        elapsed < StdDuration::from_millis(500),
        "wait should wake promptly after the mutation, elapsed={elapsed:?}",
    );
}

#[test]
fn test_version_notifier_timeout() {
    let runtime = CoreRuntime::new().expect("runtime");
    let since_version = current_version(runtime.as_ref());

    let start = Instant::now();
    let changed = runtime.wait_for_version_change(since_version, StdDuration::from_millis(200));
    let elapsed = start.elapsed();

    assert_eq!(changed, None);
    assert!(
        elapsed >= StdDuration::from_millis(150),
        "timeout path should block for roughly the requested interval, elapsed={elapsed:?}",
    );
}

#[test]
fn test_version_notifier_spurious_safe() {
    let notifier = VersionNotifier::new();
    let version = AtomicU64::new(7);

    notifier.notify();
    let changed = notifier.wait_for_change(&version, 7, StdDuration::from_millis(100));

    assert_eq!(changed, None);
}

#[test]
fn test_all_mutation_paths_notify() {
    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .ingest_hook_event(make_hook_event_command(
                "evt-all-hook",
                "session-hook",
                "/repo/hook",
            ))
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .ingest_shell_signal(make_shell_signal_command(1001, "/repo/shell"))
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .mutate_project(MutateProjectCommand {
                kind: ProjectMutationKind::Add,
                project_path: "/repo/project".to_string(),
                display_name: Some("project".to_string()),
            })
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .mutate_idea(MutateIdeaCommand {
                kind: IdeaMutationKind::Add,
                project_path: "/repo/idea".to_string(),
                idea_id: "idea-001".to_string(),
                title: Some("Version notifier".to_string()),
                description: Some("prove wakeups".to_string()),
                status: Some("new".to_string()),
            })
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .mutate_worktree(MutateWorktreeCommand {
                kind: WorktreeMutationKind::Create,
                repo_path: "/repo/worktree".to_string(),
                worktree_name: "notifier-proof".to_string(),
                force: false,
            })
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .mutate_delegation(make_delegation_start_command(
                "/repo/delegation",
                "worker-001",
            ))
            .map(|_| ())
    });

    assert_mutation_advances_version_and_wakes(CoreRuntime::new().expect("runtime"), |runtime| {
        runtime
            .mutate_run(make_run_create_command("run-001", "/repo/run"))
            .map(|_| ())
    });

    let storage = Arc::new(InMemorySnapshotStorage::default());
    storage
        .save_snapshot(&stale_dead_snapshot_for_gc_notify_test())
        .expect("save stale snapshot");
    let gc_runtime =
        CoreRuntime::from_storage(storage, StorageConfig::default()).expect("gc runtime");
    assert_mutation_advances_version_and_wakes(gc_runtime, |runtime| runtime.run_gc().map(|_| ()));
}

#[test]
fn run_gc_at_uses_explicit_reference_time() {
    let now = Utc::now();
    let stale_ts = (now - Duration::minutes(11)).to_rfc3339();
    let idle_ts = (now - Duration::minutes(1)).to_rfc3339();
    let adjusted_now = now - Duration::minutes(8);

    let snapshot = AppSnapshot {
        projects: vec![],
        sessions: vec![
            SessionSummary {
                session_id: "stale-worker".to_string(),
                pid: 0,
                cwd: "/repo/gc".to_string(),
                project_id: "/repo/gc".to_string(),
                project_path: "/repo/gc".to_string(),
                workspace_id: default_workspace_id("/repo/gc"),
                state: SessionState::Working,
                state_changed_at: stale_ts.clone(),
                updated_at: stale_ts.clone(),
                last_event: Some("notification".to_string()),
                last_activity_at: Some(stale_ts),
                terminated_at: None,
                tools_in_flight: 0,
                state_source: None,
                last_authoritative_event_at: None,
                is_alive: false,
                gc_reason: None,
            },
            SessionSummary {
                session_id: "idle-survivor".to_string(),
                pid: 0,
                cwd: "/repo/gc".to_string(),
                project_id: "/repo/gc".to_string(),
                project_path: "/repo/gc".to_string(),
                workspace_id: default_workspace_id("/repo/gc"),
                state: SessionState::Idle,
                state_changed_at: idle_ts.clone(),
                updated_at: idle_ts.clone(),
                last_event: None,
                last_activity_at: None,
                terminated_at: None,
                tools_in_flight: 0,
                state_source: None,
                last_authoritative_event_at: None,
                is_alive: false,
                gc_reason: None,
            },
        ],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 2,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    };

    let real_time_storage = Arc::new(InMemorySnapshotStorage::default());
    real_time_storage
        .save_snapshot(&snapshot.clone())
        .expect("save real-time snapshot");
    let real_time_runtime = CoreRuntime::from_storage(real_time_storage, StorageConfig::default())
        .expect("real-time runtime");

    let changed = real_time_runtime.run_gc().expect("run gc at current time");
    assert!(changed, "real-time gc should transition the stale session");
    let real_time_snapshot = real_time_runtime
        .app_snapshot()
        .expect("real-time snapshot");
    let stale_session = real_time_snapshot
        .sessions
        .iter()
        .find(|session| session.session_id == "stale-worker")
        .expect("stale session should be preserved as Idle, not removed");
    assert_eq!(
        stale_session.state,
        SessionState::Idle,
        "run_gc() should transition the stale session to Idle at wall-clock time"
    );

    let adjusted_storage = Arc::new(InMemorySnapshotStorage::default());
    adjusted_storage
        .save_snapshot(&snapshot)
        .expect("save adjusted snapshot");
    let adjusted_runtime = CoreRuntime::from_storage(adjusted_storage, StorageConfig::default())
        .expect("adjusted runtime");

    let changed = adjusted_runtime
        .run_gc_at(adjusted_now)
        .expect("run gc at adjusted time");
    assert!(
        !changed,
        "adjusted gc time should keep the stale sibling within the 10-minute grace window"
    );
    let adjusted_snapshot = adjusted_runtime.app_snapshot().expect("adjusted snapshot");
    let adjusted_stale = adjusted_snapshot
        .sessions
        .iter()
        .find(|session| session.session_id == "stale-worker")
        .expect("stale session should survive at adjusted time");
    assert_eq!(
        adjusted_stale.state,
        SessionState::Working,
        "run_gc_at(adjusted_now) should preserve the stale sibling in Working state"
    );
    assert!(
        adjusted_snapshot
            .sessions
            .iter()
            .any(|session| session.session_id == "idle-survivor"),
        "the survivor must remain present"
    );
}

#[test]
fn active_runtime_session_requires_recent_active_state() {
    let now = Utc::now();
    let snapshot = RuntimeSessionsSnapshot::from_sessions(vec![
        make_runtime_session_record(
            "ready-recent",
            "ready",
            now - Duration::seconds(30),
            Some(now - Duration::seconds(30)),
            Some(true),
        ),
        make_runtime_session_record(
            "working-stale",
            "working",
            now - Duration::seconds(601),
            Some(now - Duration::seconds(601)),
            Some(true),
        ),
    ]);

    assert!(
        !super::has_active_runtime_session(Some(&snapshot), 300),
        "ready and stale sessions must not extend heartbeat grace",
    );
}

#[test]
fn active_runtime_session_respects_recent_alive_work() {
    let now = Utc::now();
    let snapshot = RuntimeSessionsSnapshot::from_sessions(vec![make_runtime_session_record(
        "working-recent",
        "working",
        now - Duration::seconds(45),
        Some(now - Duration::seconds(45)),
        Some(true),
    )]);

    assert!(super::has_active_runtime_session(Some(&snapshot), 300));
}

#[test]
fn active_runtime_session_respects_explicit_dead_flag() {
    let now = Utc::now();
    let snapshot = RuntimeSessionsSnapshot::from_sessions(vec![make_runtime_session_record(
        "working-dead",
        "working",
        now - Duration::seconds(30),
        Some(now - Duration::seconds(30)),
        Some(false),
    )]);

    assert!(
        !super::has_active_runtime_session(Some(&snapshot), 300),
        "explicit dead sessions must not extend heartbeat grace",
    );
}

#[test]
fn check_hook_health_uses_recent_service_hook_activity_without_filesystem_heartbeat() {
    let _guard = env_lock();
    let temp = setup_hook_health_env();
    let runtime_service = mock_runtime_snapshot_service_with_hook_activity(
        "hook-health-healthy",
        vec![make_snapshot_session("waiting", 45, Some(true))],
        Some((Utc::now() - Duration::seconds(45)).to_rfc3339()),
    );
    let _ignored_snapshot = EnvVarGuard::set(
        IGNORED_SNAPSHOT_ENV_NAME,
        temp.snapshot_path.to_str().expect("snapshot path"),
    );
    let _service_port = EnvVarGuard::set(
        RUNTIME_SERVICE_PORT_ENV,
        &runtime_service.port().to_string(),
    );
    let _service_token = EnvVarGuard::set(RUNTIME_SERVICE_TOKEN_ENV, "hook-health-healthy");

    let runtime = make_runtime_with_storage(&temp);
    let report = runtime.check_hook_health();

    assert!(matches!(report.status, HookHealthStatus::Healthy));
    assert!(report.last_hook_event_age_secs.is_some_and(|age| age <= 60));
    runtime_service.finish();
}

#[test]
fn check_hook_health_reports_stale_service_hook_activity_without_filesystem_heartbeat() {
    let _guard = env_lock();
    let temp = setup_hook_health_env();
    let runtime_service = mock_runtime_snapshot_service_with_hook_activity(
        "hook-health-stale",
        vec![make_snapshot_session("ready", 30, Some(true))],
        Some((Utc::now() - Duration::seconds(120)).to_rfc3339()),
    );
    let _ignored_snapshot = EnvVarGuard::set(
        IGNORED_SNAPSHOT_ENV_NAME,
        temp.snapshot_path.to_str().expect("snapshot path"),
    );
    let _service_port = EnvVarGuard::set(
        RUNTIME_SERVICE_PORT_ENV,
        &runtime_service.port().to_string(),
    );
    let _service_token = EnvVarGuard::set(RUNTIME_SERVICE_TOKEN_ENV, "hook-health-stale");

    let runtime = make_runtime_with_storage(&temp);
    let report = runtime.check_hook_health();

    assert!(
        matches!(
            report.status,
            HookHealthStatus::Stale { last_seen_secs } if last_seen_secs >= 120
        ),
        "report was {report:?}"
    );
    assert!(report
        .last_hook_event_age_secs
        .is_some_and(|age| age >= 120));
    runtime_service.finish();
}

#[test]
fn run_hook_test_succeeds_with_recent_service_hook_activity_and_runtime_service_health() {
    let _guard = env_lock();
    let temp = setup_hook_health_env();
    let runtime_service = mock_runtime_health_and_snapshot_service(
        "hook-test-healthy",
        vec![make_snapshot_session("working", 30, Some(true))],
        Some((Utc::now() - Duration::seconds(30)).to_rfc3339()),
    );
    let _ignored_snapshot = EnvVarGuard::set(
        IGNORED_SNAPSHOT_ENV_NAME,
        temp.snapshot_path.to_str().expect("snapshot path"),
    );
    let _service_port = EnvVarGuard::set(
        RUNTIME_SERVICE_PORT_ENV,
        &runtime_service.port().to_string(),
    );
    let _service_token = EnvVarGuard::set(RUNTIME_SERVICE_TOKEN_ENV, "hook-test-healthy");

    let runtime = make_runtime_with_storage(&temp);
    let result = runtime.run_hook_test().unwrap();

    assert!(result.success, "result was {result:?}");
    assert!(result.hook_activity_ok, "result was {result:?}");
    assert!(result.runtime_service_ok, "result was {result:?}");
    runtime_service.finish();
}

#[test]
fn test_is_first_run_true_when_no_setup_marker() {
    let _guard = env_lock();
    let runtime = make_runtime_with_storage(&setup_hook_health_env());

    let report = runtime.get_hook_diagnostic().unwrap();

    assert!(report.is_first_run, "report was {report:?}");
}

#[test]
fn test_is_first_run_false_when_setup_marker_exists() {
    let _guard = env_lock();
    let env = setup_hook_health_env();
    fs::write(env.storage.setup_marker_path(), "complete").expect("write setup marker");
    let runtime = make_runtime_with_storage(&env);

    let report = runtime.get_hook_diagnostic().unwrap();

    assert!(!report.is_first_run, "report was {report:?}");
}

#[test]
fn test_is_first_run_false_even_with_unknown_hook_health() {
    let _guard = env_lock();
    let env = setup_hook_health_env();
    let _home_guard = EnvVarGuard::set("HOME", env._temp.path().to_str().expect("temp home path"));
    fs::write(env.storage.setup_marker_path(), "complete").expect("write setup marker");
    let runtime = make_runtime_with_storage(&env);

    let health = runtime.check_hook_health();
    assert!(matches!(health.status, HookHealthStatus::Unknown));

    let report = runtime.get_hook_diagnostic().unwrap();

    assert!(!report.is_first_run, "report was {report:?}");
}

#[cfg(unix)]
#[test]
fn test_settings_unreadable_hook_diagnostic_is_not_auto_fixable() {
    use std::os::unix::fs::PermissionsExt;

    let _guard = env_lock();
    let env = setup_hook_health_env();
    let _home_guard = EnvVarGuard::set("HOME", env._temp.path().to_str().expect("temp home path"));

    let bin_dir = env._temp.path().join(".local/bin");
    fs::create_dir_all(&bin_dir).expect("create bin dir");
    let binary_path = bin_dir.join("hud-hook");
    fs::write(
        &binary_path,
        "#!/bin/sh\n\
         if [ \"$1\" = \"--help\" ]; then\n\
           echo \"Commands: serve cwd\"\n\
           exit 0\n\
         fi\n\
         exit 0\n",
    )
    .expect("write hook binary");
    let mut permissions = fs::metadata(&binary_path)
        .expect("binary metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&binary_path, permissions).expect("set binary permissions");
    fs::write(
        env.storage.claude_root().join("settings.json"),
        "{ invalid json }",
    )
    .expect("write corrupt settings");

    let runtime = make_runtime_with_storage(&env);
    let report = runtime.get_hook_diagnostic().unwrap();

    assert_eq!(report.primary_issue, Some(HookIssue::ConfigMissing));
    assert!(!report.can_auto_fix, "report was {report:?}");
}

fn make_runtime_session_record(
    session_id: &str,
    state: &str,
    updated_at: chrono::DateTime<Utc>,
    last_activity_at: Option<chrono::DateTime<Utc>>,
    is_alive: Option<bool>,
) -> RuntimeSessionRecord {
    RuntimeSessionRecord {
        session_id: session_id.to_string(),
        pid: 42,
        state: state.to_string(),
        cwd: "/repo".to_string(),
        project_path: "/repo".to_string(),
        updated_at: updated_at.to_rfc3339(),
        state_changed_at: updated_at.to_rfc3339(),
        last_event: None,
        last_activity_at: last_activity_at.map(|value| value.to_rfc3339()),
        tools_in_flight: 0,
        is_alive,
    }
}

struct HookHealthTestEnv {
    _temp: TempDir,
    storage: StorageConfig,
    snapshot_path: std::path::PathBuf,
}

fn setup_hook_health_env() -> HookHealthTestEnv {
    let temp = tempfile::tempdir().expect("tempdir");
    let capacitor_root = temp.path().join("capacitor");
    let claude_root = temp.path().join("claude");
    fs::create_dir_all(&capacitor_root).expect("create capacitor root");
    fs::create_dir_all(&claude_root).expect("create claude root");
    let storage = StorageConfig::with_roots(capacitor_root.clone(), claude_root);
    HookHealthTestEnv {
        snapshot_path: temp.path().join("app_snapshot.json"),
        storage,
        _temp: temp,
    }
}

fn make_runtime_with_storage(env: &HookHealthTestEnv) -> Arc<CoreRuntime> {
    CoreRuntime::from_storage(
        Arc::new(InMemorySnapshotStorage::default()),
        env.storage.clone(),
    )
    .expect("runtime")
}

fn current_version(runtime: &CoreRuntime) -> u64 {
    runtime.version.load(Ordering::Relaxed)
}

fn assert_mutation_advances_version_and_wakes<F>(runtime: Arc<CoreRuntime>, mutate: F)
where
    F: FnOnce(&CoreRuntime) -> Result<(), super::CoreRuntimeError> + Send + 'static,
{
    let since_version = current_version(runtime.as_ref());
    let worker_runtime = Arc::clone(&runtime);

    let worker = thread::spawn(move || {
        thread::sleep(StdDuration::from_millis(50));
        mutate(worker_runtime.as_ref()).expect("mutation");
    });

    let start = Instant::now();
    let changed = runtime.wait_for_version_change(since_version, StdDuration::from_secs(2));
    let elapsed = start.elapsed();

    worker.join().expect("mutation thread");

    assert_eq!(changed, Some(since_version + 1));
    assert_eq!(current_version(runtime.as_ref()), since_version + 1);
    assert!(
        elapsed < StdDuration::from_millis(500),
        "mutation wait should wake promptly, elapsed={elapsed:?}",
    );
}

fn stale_dead_snapshot_for_gc_read_test() -> AppSnapshot {
    let now = "2099-04-01T12:00:00Z".to_string();
    let stale = "2099-04-01T11:30:00Z".to_string();

    AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            session_id: "dead-session".to_string(),
            pid: 0,
            cwd: "/repo".to_string(),
            project_id: "/repo".to_string(),
            project_path: "/repo".to_string(),
            workspace_id: default_workspace_id("/repo"),
            state: SessionState::Waiting,
            state_changed_at: stale.clone(),
            updated_at: stale.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(stale),
            terminated_at: None,
            tools_in_flight: 1,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now,
        snapshot_version: 0,
        schema_version: 0,
    }
}

fn stale_dead_snapshot_for_gc_notify_test() -> AppSnapshot {
    let now = Utc::now();
    let stale = (now - Duration::minutes(30)).to_rfc3339();

    AppSnapshot {
        projects: vec![],
        sessions: vec![SessionSummary {
            session_id: "stale-gc-session".to_string(),
            pid: 0,
            cwd: "/repo/gc".to_string(),
            project_id: "/repo/gc".to_string(),
            project_path: "/repo/gc".to_string(),
            workspace_id: default_workspace_id("/repo/gc"),
            state: SessionState::Working,
            state_changed_at: stale.clone(),
            updated_at: stale.clone(),
            last_event: Some("notification".to_string()),
            last_activity_at: Some(stale),
            terminated_at: None,
            tools_in_flight: 0,
            state_source: None,
            last_authoritative_event_at: None,
            is_alive: false,
            gc_reason: None,
        }],
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 1,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now.to_rfc3339(),
        snapshot_version: 0,
        schema_version: 0,
    }
}

fn make_hook_event_command(
    event_id: &str,
    session_id: &str,
    project_path: &str,
) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: event_id.to_string(),
        recorded_at: Utc::now().to_rfc3339(),
        event_type: HookEventType::UserPromptSubmit,
        session_id: session_id.to_string(),
        pid: Some(42),
        project_path: project_path.to_string(),
        cwd: Some(project_path.to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    }
}

fn make_shell_signal_command(pid: u32, cwd: &str) -> IngestShellSignalCommand {
    IngestShellSignalCommand {
        pid,
        cwd: cwd.to_string(),
        tty: format!("/dev/ttys{pid}"),
        parent_app: "terminal".to_string(),
        tmux_session: None,
        tmux_client_tty: None,
        tmux_pane: None,
        tmux_panes: vec![],
        recorded_at: Utc::now().to_rfc3339(),
    }
}

fn make_delegation_start_command(project_path: &str, worker_id: &str) -> MutateDelegationCommand {
    MutateDelegationCommand {
        kind: DelegationMutationKind::Start,
        project_path: project_path.to_string(),
        worker_id: worker_id.to_string(),
        idea_id: None,
        worktree_name: Some("notifier-proof".to_string()),
        worktree_path: Some(format!("{project_path}/.worktrees/notifier-proof")),
        session_id: None,
        milestone_id: None,
        brief_path: None,
        manifest_path: None,
        review_decision: None,
        note: None,
    }
}

fn make_run_create_command(run_id: &str, project_path: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create,
        project_path: project_path.to_string(),
        run_id: run_id.to_string(),
        method_id: Some("execution_only".to_string()),
        involvement: None,
        checkpoint_kind: None,
        checkpoint_title: None,
        checkpoint_summary: None,
        checkpoint_brief_path: None,
        checkpoint_manifest_path: None,
        checkpoint_media_artifacts: vec![],
        checkpoint_mermaid_sources: vec![],
        capture_url: None,
        checkpoint_id: None,
        capture_request_id: None,
        client_id: None,
        observed_capture_url: None,
        capture_failure_reason: None,
        decision_action: None,
        decision_note: None,
        session_id: None,
        delegation_worker_id: None,
        status_message: None,
        idea_id: None,
        idea_title: None,
        idea_description: None,
        completed_media_artifacts: vec![],
    }
}

fn snapshot_payload(sessions: Vec<SessionSummary>, last_hook_event_at: Option<String>) -> Vec<u8> {
    let now = Utc::now().to_rfc3339();
    let snapshot = AppSnapshot {
        projects: vec![ProjectSummary {
            project_path: "/repo".to_string(),
            project_id: "/repo/.git".to_string(),
            workspace_id: "workspace-repo".to_string(),
            display_name: "repo".to_string(),
            state: SessionState::Working,
            state_changed_at: now.clone(),
            updated_at: now.clone(),
            representative_session_id: sessions.first().map(|session| session.session_id.clone()),
            latest_session_id: sessions.first().map(|session| session.session_id.clone()),
            session_count: sessions.len() as u64,
            active_count: sessions
                .iter()
                .filter(|session| session.state.is_active())
                .count() as u64,
            has_session: !sessions.is_empty(),
        }],
        sessions,
        shells: vec![],
        routing: vec![],
        delegations: vec![],
        runs: vec![],
        diagnostics: DiagnosticsSummary {
            events_ingested: 0,
            sessions_tracked: 0,
            shell_signals_tracked: 0,
            events_skipped: 0,
            stale_events_skipped: 0,
            informational_events_skipped: 0,
            reducer_events_skipped: 0,
            last_error: None,
            last_hook_event_at: None,
        },
        generated_at: now,
        snapshot_version: 0,
        schema_version: 0,
    };
    let mut value = serde_json::to_value(snapshot).expect("serialize snapshot to value");
    if let Some(last_hook_event_at) = last_hook_event_at {
        value["diagnostics"]["last_hook_event_at"] = serde_json::Value::String(last_hook_event_at);
    }
    serde_json::to_vec(&value).expect("serialize snapshot json")
}

fn mock_runtime_snapshot_service_with_hook_activity(
    auth_token: &str,
    sessions: Vec<SessionSummary>,
    last_hook_event_at: Option<String>,
) -> MockRuntimeService {
    let snapshot = serde_json::from_slice::<serde_json::Value>(&snapshot_payload(
        sessions,
        last_hook_event_at,
    ))
    .expect("snapshot json value");
    MockRuntimeService::spawn(
        auth_token,
        vec![MockRuntimeServiceRoute::json("/runtime/snapshot", snapshot)],
    )
}

fn mock_runtime_health_and_snapshot_service(
    auth_token: &str,
    sessions: Vec<SessionSummary>,
    last_hook_event_at: Option<String>,
) -> MockRuntimeService {
    let snapshot = serde_json::from_slice::<serde_json::Value>(&snapshot_payload(
        sessions,
        last_hook_event_at,
    ))
    .expect("snapshot json value");
    MockRuntimeService::spawn(
        auth_token,
        vec![
            MockRuntimeServiceRoute::json("/runtime/snapshot", snapshot),
            MockRuntimeServiceRoute::json(
                "/health",
                serde_json::json!({
                    "status": "ok",
                    "pid": 4242,
                    "version": "runtime-service-test",
                    "protocol_version": 1,
                    "schema_version": 3,
                    "auth_mode": "bearer",
                    "service_mode": "bootstrap_only",
                }),
            ),
        ],
    )
}

fn make_snapshot_session(state: &str, seconds_ago: i64, is_alive: Option<bool>) -> SessionSummary {
    let timestamp = (Utc::now() - Duration::seconds(seconds_ago)).to_rfc3339();
    SessionSummary {
        session_id: format!("{state}-{seconds_ago}"),
        pid: 42,
        cwd: "/repo".to_string(),
        project_id: "/repo/.git".to_string(),
        project_path: "/repo".to_string(),
        workspace_id: "workspace-repo".to_string(),
        state: match state {
            "working" => SessionState::Working,
            "waiting" => SessionState::Waiting,
            "compacting" => SessionState::Compacting,
            "ready" => SessionState::Ready,
            _ => SessionState::Idle,
        },
        state_changed_at: timestamp.clone(),
        updated_at: timestamp.clone(),
        last_event: None,
        last_activity_at: Some(timestamp),
        terminated_at: None,
        tools_in_flight: 0,
        state_source: None,
        last_authoritative_event_at: None,
        is_alive: is_alive.unwrap_or(false),
        gc_reason: None,
    }
}

#[test]
fn unregister_shell_removes_shell_from_state() {
    let runtime = CoreRuntime::new().expect("runtime");

    runtime
        .ingest_shell_signal(IngestShellSignalCommand {
            pid: 9999,
            cwd: "/tmp/project".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            tmux_panes: vec![],
            recorded_at: "2099-01-01T00:00:00Z".to_string(),
        })
        .expect("shell signal");

    let snapshot = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snapshot.shells.len(), 1);
    assert_eq!(snapshot.shells[0].pid, 9999);

    let outcome = runtime
        .unregister_shell(ShellUnregisterCommand { pid: 9999 })
        .expect("unregister shell");
    assert!(outcome.ok);
    assert!(outcome.message.contains("9999"));
    assert!(outcome.message.contains("unregistered"));

    let snapshot = runtime.app_snapshot().expect("snapshot after unregister");
    assert!(snapshot.shells.is_empty());
}

#[test]
fn unregister_shell_for_missing_pid_succeeds_with_not_found() {
    let runtime = CoreRuntime::new().expect("runtime");

    let outcome = runtime
        .unregister_shell(ShellUnregisterCommand { pid: 7777 })
        .expect("unregister shell");
    assert!(outcome.ok);
    assert!(outcome.message.contains("not found"));
}

mod cold_start_transcript_tests {
    use super::*;
    use crate::domain::SignalAuthority;
    use tempfile::TempDir;

    fn setup_transcript(tmp: &TempDir, slug: &str, project_path: &str, session_id: &str) {
        let project_dir = tmp.path().join("projects").join(slug);
        fs::create_dir_all(&project_dir).unwrap();
        fs::write(project_dir.join(".project_path"), project_path).unwrap();
        fs::write(
            project_dir.join(format!("{session_id}.jsonl")),
            r#"{"type":"user","content":"hello"}"#,
        )
        .unwrap();
    }

    #[test]
    fn cold_start_from_transcripts_creates_valid_sessions() {
        let tmp = TempDir::new().unwrap();
        setup_transcript(&tmp, "my-project", "/repo/capacitor", "sess-abc");
        setup_transcript(&tmp, "other-project", "/repo/other", "sess-def");

        let storage = Arc::new(InMemorySnapshotStorage::default());
        let config =
            StorageConfig::with_roots(tmp.path().join("capacitor"), tmp.path().to_path_buf());
        let runtime =
            CoreRuntime::from_storage_with_transcript_cold_start(storage, config).expect("runtime");

        let snapshot = runtime.app_snapshot().expect("snapshot");
        assert_eq!(snapshot.sessions.len(), 2, "two sessions from transcripts");

        let sess_abc = snapshot
            .sessions
            .iter()
            .find(|s| s.session_id == "sess-abc")
            .expect("sess-abc found");
        assert_eq!(sess_abc.project_path, "/repo/capacitor");
        assert_eq!(sess_abc.state, SessionState::Idle);
        let source = sess_abc.state_source.as_ref().expect("has state_source");
        assert_eq!(source.event_kind, HookEventType::TranscriptActivity);
        assert_eq!(source.authority, SignalAuthority::Inferential);
    }

    #[test]
    fn cold_start_equivalent_to_continuous_live_ingest() {
        let tmp = TempDir::new().unwrap();
        setup_transcript(&tmp, "proj-a", "/repo/a", "sess-1");
        setup_transcript(&tmp, "proj-a", "/repo/a", "sess-2");
        setup_transcript(&tmp, "proj-b", "/repo/b", "sess-3");

        let discoveries = crate::observation::transcript::scan_for_sessions(tmp.path());

        let storage_a = Arc::new(InMemorySnapshotStorage::default());
        let config_a =
            StorageConfig::with_roots(tmp.path().join("cap_a"), tmp.path().to_path_buf());
        let runtime_a = CoreRuntime::from_storage_with_transcript_cold_start(storage_a, config_a)
            .expect("runtime_a");
        let snapshot_a = runtime_a.app_snapshot().expect("snapshot_a");

        let storage_b = Arc::new(InMemorySnapshotStorage::default());
        let config_b =
            StorageConfig::with_roots(tmp.path().join("cap_b"), tmp.path().to_path_buf());
        let runtime_b = CoreRuntime::from_storage(storage_b, config_b).expect("runtime_b");
        for discovery in &discoveries {
            runtime_b
                .ingest_transcript_observation(discovery.clone())
                .expect("live ingest ok");
        }
        let snapshot_b = runtime_b.app_snapshot().expect("snapshot_b");

        assert_eq!(snapshot_a.sessions.len(), 3, "three sessions from fixture");
        assert_eq!(
            snapshot_b.sessions.len(),
            3,
            "three sessions from live replay"
        );

        let mut sessions_a = snapshot_a.sessions.clone();
        let mut sessions_b = snapshot_b.sessions.clone();
        sessions_a.sort_by(|left, right| left.session_id.cmp(&right.session_id));
        sessions_b.sort_by(|left, right| left.session_id.cmp(&right.session_id));
        assert_eq!(
            sessions_a, sessions_b,
            "sessions must match after equivalent replay"
        );

        let mut projects_a = snapshot_a.projects.clone();
        let mut projects_b = snapshot_b.projects.clone();
        projects_a.sort_by(|left, right| left.project_id.cmp(&right.project_id));
        projects_b.sort_by(|left, right| left.project_id.cmp(&right.project_id));
        assert_eq!(
            projects_a, projects_b,
            "projects must match after equivalent replay"
        );

        let mut routing_a = snapshot_a.routing.clone();
        let mut routing_b = snapshot_b.routing.clone();
        let sort_routing = |routing: &mut Vec<crate::domain::RoutingView>| {
            routing.sort_by(|left, right| {
                left.workspace_id
                    .cmp(&right.workspace_id)
                    .then_with(|| left.project_path.cmp(&right.project_path))
                    .then_with(|| left.target.terminal_app.cmp(&right.target.terminal_app))
                    .then_with(|| left.target.session_name.cmp(&right.target.session_name))
                    .then_with(|| left.target.pane_id.cmp(&right.target.pane_id))
                    .then_with(|| left.target.host_tty.cmp(&right.target.host_tty))
                    .then_with(|| left.reason_code.cmp(&right.reason_code))
                    .then_with(|| left.reason.cmp(&right.reason))
                    .then_with(|| left.updated_at.cmp(&right.updated_at))
            });
        };
        sort_routing(&mut routing_a);
        sort_routing(&mut routing_b);
        assert_eq!(
            routing_a, routing_b,
            "routing must match after equivalent replay"
        );

        assert_eq!(
            snapshot_a.diagnostics.events_ingested, snapshot_b.diagnostics.events_ingested,
            "events_ingested must match"
        );
    }

    #[test]
    fn cold_start_sessions_get_upgraded_by_subsequent_hook() {
        let tmp = TempDir::new().unwrap();
        setup_transcript(&tmp, "proj", "/repo", "session-1");

        let storage = Arc::new(InMemorySnapshotStorage::default());
        let config = StorageConfig::with_roots(tmp.path().join("cap"), tmp.path().to_path_buf());
        let runtime =
            CoreRuntime::from_storage_with_transcript_cold_start(storage, config).expect("runtime");

        let snapshot = runtime.app_snapshot().expect("pre-hook snapshot");
        let sess = snapshot
            .sessions
            .iter()
            .find(|s| s.session_id == "session-1")
            .expect("transcript session");
        assert_eq!(
            sess.state_source.as_ref().unwrap().authority,
            SignalAuthority::Inferential
        );

        let hook = IngestHookEventCommand {
            event_id: "evt-1".to_string(),
            recorded_at: "2099-01-31T00:00:00Z".to_string(),
            event_type: HookEventType::UserPromptSubmit,
            session_id: "session-1".to_string(),
            pid: Some(42),
            project_path: "/repo".to_string(),
            cwd: Some("/repo".to_string()),
            file_path: None,
            workspace_id: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            agent_id: None,
            teammate_name: None,
        };
        let outcome = runtime.ingest_hook_event(hook).expect("hook ingest");
        assert!(outcome.ok);

        let snapshot = runtime.app_snapshot().expect("post-hook snapshot");
        let sess = snapshot
            .sessions
            .iter()
            .find(|s| s.session_id == "session-1")
            .expect("upgraded session");
        assert_eq!(sess.state, SessionState::Working);
        assert_eq!(
            sess.state_source.as_ref().unwrap().authority,
            SignalAuthority::DefinitiveTransient,
            "hook upgrades transcript authority"
        );
    }

    #[test]
    fn cold_start_skipped_when_snapshot_exists() {
        let tmp = TempDir::new().unwrap();
        setup_transcript(&tmp, "proj", "/repo", "transcript-session");

        let storage = Arc::new(InMemorySnapshotStorage::default());
        let empty_snapshot = AppSnapshot {
            projects: vec![],
            sessions: vec![],
            shells: vec![],
            routing: vec![],
            delegations: vec![],
            runs: vec![],
            diagnostics: DiagnosticsSummary {
                events_ingested: 0,
                sessions_tracked: 0,
                shell_signals_tracked: 0,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
                last_hook_event_at: None,
            },
            generated_at: "2099-01-01T00:00:00Z".to_string(),
            snapshot_version: 1,
            schema_version: 0,
        };
        storage.save_snapshot(&empty_snapshot).unwrap();

        let config = StorageConfig::with_roots(tmp.path().join("cap"), tmp.path().to_path_buf());
        let runtime =
            CoreRuntime::from_storage_with_transcript_cold_start(storage, config).expect("runtime");

        let snapshot = runtime.app_snapshot().expect("snapshot");
        assert!(
            snapshot.sessions.is_empty(),
            "transcript sessions NOT created when snapshot exists"
        );
    }
}
