//! Canonical Capacitor core runtime.
//!
//! This crate is the long-term source of truth for domain policy and
//! projection exposed through UniFFI.

uniffi::setup_scaffolding!();

mod clean;
pub mod domain;
pub mod ingest;
pub mod query;
pub mod reduce;
pub mod runtime_artifacts;
pub mod runtime_boundaries;
pub mod runtime_config;
pub mod runtime_error;
pub mod runtime_ideas;
pub mod runtime_patterns;
pub mod runtime_projects;
pub mod runtime_sessions;
pub mod runtime_setup;
pub mod runtime_state;
pub mod runtime_stats;
pub mod runtime_storage;
pub mod runtime_types;
pub mod runtime_validation;
pub mod storage;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use domain::{
    default_workspace_id, display_name, now_rfc3339, AppSnapshot, IngestHookEventCommand,
    IngestShellSignalCommand, MutateIdeaCommand, MutateProjectCommand, MutateWorktreeCommand,
    MutationOutcome, ProjectMutationKind,
};
use runtime_artifacts::{count_artifacts_in_dir, count_hooks_in_dir};
use runtime_config::resolve_symlink;
use runtime_sessions::ProjectStatus;
use runtime_setup::{DependencyStatus, HookStatus, InstallResult, SetupStatus};
use runtime_storage::StorageConfig;
use runtime_types::{
    DashboardData, GlobalConfig, HookDiagnosticReport, HookTestResult, Plugin, PluginManifest,
    ShellSuggestedProjectCandidate,
};
use runtime_validation::ValidationResultFfi;
use storage::{InMemorySnapshotStorage, JsonFileSnapshotStorage, SnapshotStorage};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreRuntimeError {
    #[error("{message}")]
    General { message: String },
}

impl From<String> for CoreRuntimeError {
    fn from(message: String) -> Self {
        Self::General { message }
    }
}

impl From<&str> for CoreRuntimeError {
    fn from(message: &str) -> Self {
        Self::General {
            message: message.to_string(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct CoreRuntime {
    state: std::sync::Mutex<reduce::ReducerState>,
    snapshot_storage: Arc<dyn SnapshotStorage>,
    app_storage: StorageConfig,
    clean_shell: clean::CleanArchitectureShell,
}

impl CoreRuntime {
    fn from_storage(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Result<Arc<Self>, CoreRuntimeError> {
        let state = snapshot_storage
            .load_snapshot()
            .map_err(CoreRuntimeError::from)?
            .map(reduce::ReducerState::from_snapshot)
            .unwrap_or_default();
        let clean_shell = clean::CleanArchitectureShell::bootstrap(
            Arc::clone(&snapshot_storage),
            app_storage.clone(),
        );

        Ok(Arc::new(Self {
            state: std::sync::Mutex::new(state),
            snapshot_storage,
            app_storage,
            clean_shell,
        }))
    }

    fn lock_state(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, reduce::ReducerState>, CoreRuntimeError> {
        self.state
            .lock()
            .map_err(|_| CoreRuntimeError::from("runtime state lock poisoned"))
    }

    fn persist_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), CoreRuntimeError> {
        self.snapshot_storage
            .save_snapshot(snapshot)
            .map_err(CoreRuntimeError::from)
    }

    fn list_plugins_internal(&self) -> Result<Vec<Plugin>, CoreRuntimeError> {
        let registry_path = self
            .app_storage
            .claude_root()
            .join("plugins")
            .join("installed_plugins.json");
        if !registry_path.exists() {
            return Ok(Vec::new());
        }

        let content = fs_err::read_to_string(&registry_path)
            .map_err(|e| CoreRuntimeError::from(format!("Failed to read plugin registry: {e}")))?;

        #[derive(serde::Deserialize)]
        struct Registry {
            plugins: HashMap<String, Vec<PluginInfo>>,
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct PluginInfo {
            install_path: String,
        }

        let registry: Registry = serde_json::from_str(&content)
            .map_err(|e| CoreRuntimeError::from(format!("Failed to parse plugin registry: {e}")))?;

        let settings_path = self.app_storage.claude_root().join("settings.json");
        let enabled_plugins: HashMap<String, bool> = if settings_path.exists() {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Settings {
                enabled_plugins: Option<HashMap<String, bool>>,
            }

            fs_err::read_to_string(&settings_path)
                .ok()
                .and_then(|c| serde_json::from_str::<Settings>(&c).ok())
                .and_then(|s| s.enabled_plugins)
                .unwrap_or_default()
        } else {
            HashMap::new()
        };

        let mut plugins = Vec::new();

        for (id, installs) in registry.plugins {
            if let Some(install) = installs.first() {
                let plugin_path = PathBuf::from(&install.install_path);

                let manifest_path = plugin_path.join(".claude-plugin").join("plugin.json");
                let manifest: Option<PluginManifest> = fs_err::read_to_string(&manifest_path)
                    .ok()
                    .and_then(|c| serde_json::from_str(&c).ok());

                let name = manifest
                    .as_ref()
                    .map(|m| m.name.clone())
                    .unwrap_or_else(|| id.clone());
                let description = manifest
                    .as_ref()
                    .and_then(|m| m.description.clone())
                    .unwrap_or_default();

                let enabled = enabled_plugins.get(&id).copied().unwrap_or(true);

                plugins.push(Plugin {
                    id: id.clone(),
                    name,
                    description,
                    enabled,
                    path: install.install_path.clone(),
                    skill_count: count_artifacts_in_dir(&plugin_path.join("skills"), "skills"),
                    command_count: count_artifacts_in_dir(
                        &plugin_path.join("commands"),
                        "commands",
                    ),
                    agent_count: count_artifacts_in_dir(&plugin_path.join("agents"), "agents"),
                    hook_count: count_hooks_in_dir(&plugin_path),
                });
            }
        }

        plugins.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(plugins)
    }
}

pub(crate) fn heartbeat_status(
    age_secs: u64,
    threshold_secs: u64,
    grace_secs: u64,
    has_active_session: bool,
) -> runtime_types::HookHealthStatus {
    if age_secs <= threshold_secs {
        return runtime_types::HookHealthStatus::Healthy;
    }

    if has_active_session && age_secs <= grace_secs {
        return runtime_types::HookHealthStatus::Healthy;
    }

    runtime_types::HookHealthStatus::Stale {
        last_seen_secs: age_secs,
    }
}

pub(crate) fn has_active_runtime_session(
    snapshot: Option<&runtime_state::snapshot::RuntimeSessionsSnapshot>,
    max_age_secs: u64,
) -> bool {
    let snapshot = match snapshot {
        Some(snapshot) => snapshot,
        None => return false,
    };

    let now = Utc::now();
    snapshot
        .sessions()
        .iter()
        .any(|record| runtime_session_is_active_for_health(record, now, max_age_secs))
}

fn runtime_session_is_active_for_health(
    record: &runtime_state::snapshot::RuntimeSessionRecord,
    now: DateTime<Utc>,
    max_age_secs: u64,
) -> bool {
    if !matches!(
        record.state.to_ascii_lowercase().as_str(),
        "working" | "waiting" | "compacting"
    ) {
        return false;
    }

    let last_activity = record
        .last_activity_at
        .as_deref()
        .and_then(parse_rfc3339_utc)
        .or_else(|| parse_rfc3339_utc(&record.updated_at))
        .or_else(|| parse_rfc3339_utc(&record.state_changed_at));

    let recently_active = last_activity
        .map(|timestamp| now.signed_duration_since(timestamp).num_seconds() <= max_age_secs as i64)
        .unwrap_or(false);

    let is_alive = record.is_alive.unwrap_or(recently_active);
    is_alive && recently_active
}

fn parse_rfc3339_utc(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|timestamp| timestamp.with_timezone(&Utc))
}

#[uniffi::export]
impl CoreRuntime {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreRuntimeError> {
        Self::from_storage(
            Arc::new(InMemorySnapshotStorage::default()),
            StorageConfig::default(),
        )
    }

    #[uniffi::constructor]
    pub fn new_with_snapshot_file(snapshot_file: String) -> Result<Arc<Self>, CoreRuntimeError> {
        let path = snapshot_file.trim();
        if path.is_empty() {
            return Err(CoreRuntimeError::from("snapshot_file path cannot be empty"));
        }

        Self::from_storage(
            Arc::new(JsonFileSnapshotStorage::new(path)),
            StorageConfig::default(),
        )
    }

    pub fn app_snapshot(&self) -> Result<AppSnapshot, CoreRuntimeError> {
        self.clean_shell
            .app_snapshot()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn ingest_hook_event(
        &self,
        command: IngestHookEventCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let normalized = ingest::normalize_hook_event(command);
        let mut state = self.lock_state()?;
        let outcome = state.apply_hook_event(normalized);
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn ingest_shell_signal(
        &self,
        command: IngestShellSignalCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let normalized = ingest::normalize_shell_signal(command);
        let mut state = self.lock_state()?;
        let outcome = state.apply_shell_signal(normalized);
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_project(
        &self,
        command: MutateProjectCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = match command.kind {
            ProjectMutationKind::Add => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                if normalized_path.is_empty() {
                    MutationOutcome {
                        ok: false,
                        message: "project_path cannot be empty".to_string(),
                    }
                } else {
                    let project_id = crate::domain::resolve_project_identity(&normalized_path)
                        .map(|identity| identity.project_id)
                        .unwrap_or_else(|| normalized_path.clone());
                    let workspace_id = default_workspace_id(&normalized_path);
                    let display_name = command
                        .display_name
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| display_name(&normalized_path));

                    state.projects.insert(
                        normalized_path.clone(),
                        domain::ProjectSummary {
                            project_path: normalized_path,
                            project_id,
                            workspace_id,
                            display_name,
                            state: domain::SessionState::Idle,
                            state_changed_at: now_rfc3339(),
                            updated_at: now_rfc3339(),
                            representative_session_id: None,
                            latest_session_id: None,
                            session_count: 0,
                            active_count: 0,
                            has_session: false,
                        },
                    );

                    MutationOutcome {
                        ok: true,
                        message: "project added".to_string(),
                    }
                }
            }
            ProjectMutationKind::Remove => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                state.projects.remove(&normalized_path);
                state
                    .sessions
                    .retain(|_, session| session.project_path != normalized_path);
                MutationOutcome {
                    ok: true,
                    message: "project removed".to_string(),
                }
            }
            ProjectMutationKind::Rename => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                if let Some(project) = state.projects.get_mut(&normalized_path) {
                    if let Some(name) = command.display_name {
                        if !name.trim().is_empty() {
                            project.display_name = name;
                        }
                    }
                    project.updated_at = now_rfc3339();
                    MutationOutcome {
                        ok: true,
                        message: "project renamed".to_string(),
                    }
                } else {
                    MutationOutcome {
                        ok: false,
                        message: "project not found".to_string(),
                    }
                }
            }
        };

        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_idea(
        &self,
        command: MutateIdeaCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        state.events_ingested = state.events_ingested.saturating_add(1);
        let message = format!(
            "idea mutation accepted kind={:?} project_path={} idea_id={}",
            command.kind, command.project_path, command.idea_id
        );
        let outcome = MutationOutcome { ok: true, message };
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_worktree(
        &self,
        command: MutateWorktreeCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        state.events_ingested = state.events_ingested.saturating_add(1);
        let message = format!(
            "worktree mutation accepted kind={:?} repo_path={} worktree_name={} force={}",
            command.kind, command.repo_path, command.worktree_name, command.force
        );
        let outcome = MutationOutcome { ok: true, message };
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    // Runtime setup + project APIs

    pub fn claude_dir(&self) -> String {
        self.app_storage.claude_root().to_string_lossy().to_string()
    }

    pub fn capacitor_dir(&self) -> String {
        self.app_storage.root().to_string_lossy().to_string()
    }

    pub fn load_dashboard(&self) -> Result<DashboardData, CoreRuntimeError> {
        let settings_path = self.app_storage.claude_root().join("settings.json");
        let instructions_path = self.app_storage.claude_root().join("CLAUDE.md");

        let skills_dir = resolve_symlink(&self.app_storage.claude_root().join("skills"));
        let commands_dir = resolve_symlink(&self.app_storage.claude_root().join("commands"));
        let agents_dir = resolve_symlink(&self.app_storage.claude_root().join("agents"));

        let global = GlobalConfig {
            settings_path: settings_path.to_string_lossy().to_string(),
            settings_exists: settings_path.exists(),
            instructions_path: if instructions_path.exists() {
                Some(instructions_path.to_string_lossy().to_string())
            } else {
                None
            },
            skills_dir: skills_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            commands_dir: commands_dir
                .as_ref()
                .map(|p| p.to_string_lossy().to_string()),
            agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            skill_count: skills_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "skills"))
                .unwrap_or(0),
            command_count: commands_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "commands"))
                .unwrap_or(0),
            agent_count: agents_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "agents"))
                .unwrap_or(0),
        };

        let plugins = self.list_plugins_internal().unwrap_or_default();
        let projects = self
            .clean_shell
            .projects
            .refresh_project_catalog()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))?
            .projects;

        Ok(DashboardData {
            global,
            plugins,
            projects,
        })
    }

    pub fn get_suggested_projects(
        &self,
    ) -> Result<Vec<ShellSuggestedProjectCandidate>, CoreRuntimeError> {
        self.clean_shell
            .projects
            .suggest_projects()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn add_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .projects
            .connect_project(&clean::projects::domain::ConnectProjectRequest {
                path,
                display_name: None,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn remove_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .projects
            .remove_project(&path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn validate_project(&self, path: String) -> ValidationResultFfi {
        self.clean_shell
            .projects
            .validate_project(&path)
            .unwrap_or_else(|error| ValidationResultFfi {
                result_type: "not_a_project".to_string(),
                path,
                suggested_path: None,
                reason: Some(error.to_string()),
                has_claude_md: false,
                has_other_markers: false,
            })
    }

    pub fn create_project_claude_md(&self, project_path: String) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .projects
            .create_project_claude_md(&project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_project_status(&self, project_path: String) -> Option<ProjectStatus> {
        runtime_sessions::read_project_status(&project_path)
    }

    pub fn capture_idea(
        &self,
        project_path: String,
        idea_text: String,
    ) -> Result<String, CoreRuntimeError> {
        self.clean_shell
            .ideas
            .capture_idea(&clean::ideas::domain::CaptureIdeaRequest {
                project_path,
                idea_text,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn load_ideas(
        &self,
        project_path: String,
    ) -> Result<Vec<runtime_types::Idea>, CoreRuntimeError> {
        self.clean_shell
            .ideas
            .load_idea_backlog(&project_path)
            .map(|backlog| backlog.ideas)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_status(
        &self,
        project_path: String,
        idea_id: String,
        new_status: String,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .update_idea_status(&clean::ideas::domain::IdeaFieldUpdateRequest {
                project_path,
                idea_id,
                new_value: new_status,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_effort(
        &self,
        project_path: String,
        idea_id: String,
        new_effort: String,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .update_idea_effort(&clean::ideas::domain::IdeaFieldUpdateRequest {
                project_path,
                idea_id,
                new_value: new_effort,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_triage(
        &self,
        project_path: String,
        idea_id: String,
        new_triage: String,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .update_idea_triage(&clean::ideas::domain::IdeaFieldUpdateRequest {
                project_path,
                idea_id,
                new_value: new_triage,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_title(
        &self,
        project_path: String,
        idea_id: String,
        new_title: String,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .update_idea_title(&clean::ideas::domain::IdeaFieldUpdateRequest {
                project_path,
                idea_id,
                new_value: new_title,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_description(
        &self,
        project_path: String,
        idea_id: String,
        new_description: String,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .update_idea_description(&clean::ideas::domain::IdeaFieldUpdateRequest {
                project_path,
                idea_id,
                new_value: new_description,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn save_ideas_order(
        &self,
        project_path: String,
        idea_ids: Vec<String>,
    ) -> Result<(), CoreRuntimeError> {
        self.clean_shell
            .ideas
            .save_ideas_order(&clean::ideas::domain::IdeasOrderRequest {
                project_path,
                idea_ids,
            })
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn load_ideas_order(&self, project_path: String) -> Result<Vec<String>, CoreRuntimeError> {
        self.clean_shell
            .ideas
            .load_ideas_order(&project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_ideas_file_path(&self, project_path: String) -> String {
        self.clean_shell.ideas.ideas_file_path(&project_path)
    }

    pub fn check_setup_status(&self) -> SetupStatus {
        self.clean_shell.check_setup_status()
    }

    pub fn check_dependency(&self, name: String) -> DependencyStatus {
        self.clean_shell.check_dependency(&name)
    }

    pub fn install_hook_binary_from_path(
        &self,
        source_path: String,
    ) -> Result<InstallResult, CoreRuntimeError> {
        self.clean_shell
            .setup
            .install_binary_from_path(&source_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn install_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.clean_shell
            .setup
            .install_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn remove_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.clean_shell
            .setup
            .remove_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_hook_status(&self) -> HookStatus {
        self.clean_shell.get_hook_status()
    }

    pub fn check_hook_health(&self) -> runtime_types::HookHealthReport {
        self.clean_shell.check_hook_health()
    }

    pub fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
        self.clean_shell.get_hook_diagnostic()
    }

    pub fn run_hook_test(&self) -> HookTestResult {
        self.clean_shell.run_hook_test()
    }
}

#[cfg(test)]
mod tests {
    use super::CoreRuntime;
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
        MutateProjectCommand, ProjectMutationKind, ProjectSummary, SessionState, SessionSummary,
    };
    use crate::runtime_state::snapshot::{RuntimeSessionRecord, RuntimeSessionsSnapshot};
    use crate::runtime_storage::StorageConfig;
    use crate::runtime_types::{HookHealthStatus, HudConfig};
    use crate::storage::InMemorySnapshotStorage;
    use chrono::{Duration, Utc};
    use std::fs::{self, File};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration as StdDuration, SystemTime};
    use tempfile::TempDir;

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

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
        match ENV_LOCK.get_or_init(|| Mutex::new(())).lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
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
                recorded_at: "2026-02-28T00:00:00Z".to_string(),
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
    fn check_hook_health_treats_recent_waiting_session_as_grace_healthy() {
        let _guard = env_lock();
        let temp = setup_hook_health_env();
        let _snapshot_env = EnvVarGuard::set(
            "CAPACITOR_CORE_SNAPSHOT",
            temp.snapshot_path.to_str().expect("snapshot path"),
        );
        write_snapshot(
            &temp.snapshot_path,
            vec![make_snapshot_session("waiting", 45, Some(true))],
        );
        write_heartbeat(&temp.heartbeat_path, 120);

        let runtime = make_runtime_with_storage(&temp);
        let report = runtime.check_hook_health();

        assert!(matches!(report.status, HookHealthStatus::Healthy));
        assert!(report.last_heartbeat_age_secs.is_some_and(|age| age >= 120));
    }

    #[test]
    fn check_hook_health_does_not_extend_grace_for_ready_sessions() {
        let _guard = env_lock();
        let temp = setup_hook_health_env();
        let _snapshot_env = EnvVarGuard::set(
            "CAPACITOR_CORE_SNAPSHOT",
            temp.snapshot_path.to_str().expect("snapshot path"),
        );
        write_snapshot(
            &temp.snapshot_path,
            vec![make_snapshot_session("ready", 30, Some(true))],
        );
        write_heartbeat(&temp.heartbeat_path, 120);

        let runtime = make_runtime_with_storage(&temp);
        let report = runtime.check_hook_health();

        assert!(
            matches!(
                report.status,
                HookHealthStatus::Stale { last_seen_secs } if last_seen_secs >= 120
            ),
            "report was {report:?}"
        );
        assert!(report.last_heartbeat_age_secs.is_some_and(|age| age >= 120));
    }

    #[test]
    fn core_runtime_load_dashboard_reads_projects_via_projects_boundary() {
        let temp = setup_project_catalog_env();
        let runtime = make_runtime_for_storage(&temp.storage);
        let pinned_path = temp.temp.path().join("dashboard-project");
        fs::create_dir_all(&pinned_path).expect("create dashboard project");
        fs::write(pinned_path.join("CLAUDE.md"), "# Dashboard").expect("write claude md");

        let config_path = temp.storage.projects_file();
        fs::create_dir_all(config_path.parent().expect("config parent"))
            .expect("create config parent");
        fs::write(
            &config_path,
            serde_json::to_string_pretty(&HudConfig {
                pinned_projects: vec![pinned_path.to_string_lossy().to_string()],
                terminal_app: "Ghostty".to_string(),
            })
            .expect("serialize config"),
        )
        .expect("write config");

        let dashboard = runtime.load_dashboard().expect("load dashboard");

        assert_eq!(dashboard.projects.len(), 1);
        assert_eq!(dashboard.projects[0].path, pinned_path.to_string_lossy());
    }

    #[test]
    fn core_runtime_project_catalog_mutation_and_suggestions_flow_through_projects_boundary() {
        let temp = setup_project_catalog_env();
        let runtime = make_runtime_for_storage(&temp.storage);

        let suggested_path = temp.temp.path().join("suggested-project");
        fs::create_dir_all(&suggested_path).expect("create suggested project");
        fs::write(
            suggested_path.join("Cargo.toml"),
            "[package]\nname = \"suggested-project\"\n",
        )
        .expect("write cargo toml");

        let encoded =
            crate::runtime_projects::encode_project_path(suggested_path.to_string_lossy().as_ref());
        let claude_project_dir = temp.storage.claude_projects_dir().join(encoded);
        fs::create_dir_all(&claude_project_dir).expect("create claude project dir");
        fs::write(claude_project_dir.join("session-1.jsonl"), "{}\n").expect("write session");

        let suggestions = runtime
            .get_suggested_projects()
            .expect("get suggested projects");
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].path, suggested_path.to_string_lossy());

        runtime
            .add_project(suggested_path.to_string_lossy().to_string())
            .expect("add project");

        let validation = runtime.validate_project(suggested_path.to_string_lossy().to_string());
        assert_eq!(validation.result_type, "already_tracked");

        runtime
            .create_project_claude_md(suggested_path.to_string_lossy().as_ref().to_string())
            .expect("create claude md");
        assert!(suggested_path.join("CLAUDE.md").exists());

        runtime
            .remove_project(suggested_path.to_string_lossy().to_string())
            .expect("remove project");
        let config: HudConfig = serde_json::from_str(
            &fs::read_to_string(temp.storage.projects_file()).expect("read config"),
        )
        .expect("parse config");
        assert!(!config
            .pinned_projects
            .contains(&suggested_path.to_string_lossy().to_string()));
    }

    #[test]
    fn core_runtime_idea_crud_and_order_flow_through_ideas_boundary() {
        let temp = setup_project_catalog_env();
        let runtime = make_runtime_for_storage(&temp.storage);
        let project_path = "/tmp/idea-boundary-project";

        let idea_id = runtime
            .capture_idea(project_path.to_string(), "ship the finish line".to_string())
            .expect("capture idea");

        let ideas = runtime
            .load_ideas(project_path.to_string())
            .expect("load ideas");
        assert_eq!(ideas.len(), 1);
        assert_eq!(ideas[0].id, idea_id);

        runtime
            .update_idea_status(
                project_path.to_string(),
                idea_id.clone(),
                "done".to_string(),
            )
            .expect("update status");
        runtime
            .update_idea_effort(
                project_path.to_string(),
                idea_id.clone(),
                "medium".to_string(),
            )
            .expect("update effort");
        runtime
            .update_idea_triage(
                project_path.to_string(),
                idea_id.clone(),
                "validated".to_string(),
            )
            .expect("update triage");
        runtime
            .update_idea_title(
                project_path.to_string(),
                idea_id.clone(),
                "Ship the finish line".to_string(),
            )
            .expect("update title");
        runtime
            .update_idea_description(
                project_path.to_string(),
                idea_id.clone(),
                "Ship the finish line slice".to_string(),
            )
            .expect("update description");
        runtime
            .save_ideas_order(project_path.to_string(), vec![idea_id.clone()])
            .expect("save ideas order");

        let reloaded_ideas = runtime
            .load_ideas(project_path.to_string())
            .expect("reload ideas");
        assert_eq!(reloaded_ideas[0].status, "done");
        assert_eq!(reloaded_ideas[0].effort, "medium");
        assert_eq!(reloaded_ideas[0].triage, "validated");
        assert_eq!(reloaded_ideas[0].title, "Ship the finish line");
        assert_eq!(reloaded_ideas[0].description, "Ship the finish line slice");

        let order = runtime
            .load_ideas_order(project_path.to_string())
            .expect("load ideas order");
        assert_eq!(order, vec![idea_id.clone()]);

        assert_eq!(
            runtime.get_ideas_file_path(project_path.to_string()),
            temp.storage
                .project_ideas_file(project_path)
                .to_string_lossy()
        );
    }

    #[test]
    fn core_runtime_setup_mutation_flow_through_setup_boundary() {
        let temp = setup_project_catalog_env();
        let runtime = make_runtime_for_storage(&temp.storage);

        let binary_result = runtime
            .install_hook_binary_from_path("/definitely/missing/hud-hook".to_string())
            .expect("install hook binary from path");
        assert!(!binary_result.success);
        assert!(binary_result.message.contains("Source binary not found"));

        fs::write(
            temp.storage.claude_settings_file(),
            r#"{"disableAllHooks":true}"#,
        )
        .expect("write policy-blocked settings");
        let install_result = runtime.install_hooks().expect("install hooks");
        assert!(!install_result.success);
        assert!(install_result.message.contains("Cannot install hooks"));

        let remove_result = runtime.remove_hooks().expect("remove hooks");
        assert!(remove_result.success);
        assert!(remove_result.message.contains("No hook entries found"));
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
            ready_reason: None,
            is_alive,
        }
    }

    struct HookHealthTestEnv {
        _temp: TempDir,
        storage: StorageConfig,
        snapshot_path: std::path::PathBuf,
        heartbeat_path: std::path::PathBuf,
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
            heartbeat_path: capacitor_root.join("hud-hook-heartbeat"),
            storage,
            _temp: temp,
        }
    }

    fn make_runtime_with_storage(env: &HookHealthTestEnv) -> Arc<CoreRuntime> {
        make_runtime_for_storage(&env.storage)
    }

    struct ProjectCatalogTestEnv {
        temp: TempDir,
        storage: StorageConfig,
    }

    fn setup_project_catalog_env() -> ProjectCatalogTestEnv {
        let temp = tempfile::tempdir().expect("tempdir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));
        fs::create_dir_all(storage.root()).expect("create capacitor root");
        fs::create_dir_all(storage.claude_projects_dir()).expect("create claude projects root");
        ProjectCatalogTestEnv { temp, storage }
    }

    fn make_runtime_for_storage(storage: &StorageConfig) -> Arc<CoreRuntime> {
        CoreRuntime::from_storage(
            Arc::new(InMemorySnapshotStorage::default()),
            storage.clone(),
        )
        .expect("runtime")
    }

    fn write_snapshot(path: &std::path::Path, sessions: Vec<SessionSummary>) {
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
                representative_session_id: sessions
                    .first()
                    .map(|session| session.session_id.clone()),
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
            diagnostics: DiagnosticsSummary {
                events_ingested: 0,
                sessions_tracked: 0,
                shell_signals_tracked: 0,
                events_skipped: 0,
                stale_events_skipped: 0,
                informational_events_skipped: 0,
                reducer_events_skipped: 0,
                last_error: None,
            },
            generated_at: now,
        };
        let payload = serde_json::to_vec(&snapshot).expect("serialize snapshot");
        fs::write(path, payload).expect("write snapshot");
    }

    fn make_snapshot_session(
        state: &str,
        seconds_ago: i64,
        is_alive: Option<bool>,
    ) -> SessionSummary {
        let timestamp = (Utc::now() - Duration::seconds(seconds_ago)).to_rfc3339();
        let ready_reason = is_alive.and_then(|alive| {
            if alive {
                Some("alive".to_string())
            } else {
                None
            }
        });
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
            tools_in_flight: 0,
            ready_reason,
        }
    }

    fn write_heartbeat(path: &std::path::Path, age_secs: u64) {
        fs::write(path, "heartbeat").expect("write heartbeat");
        let file = File::options()
            .write(true)
            .open(path)
            .expect("open heartbeat");
        let modified = SystemTime::now()
            .checked_sub(StdDuration::from_secs(age_secs))
            .expect("compute heartbeat time");
        file.set_times(std::fs::FileTimes::new().set_modified(modified))
            .expect("set heartbeat mtime");
    }
}
