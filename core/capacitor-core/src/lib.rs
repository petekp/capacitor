//! Canonical Capacitor core runtime.
//!
//! This crate is the long-term source of truth for domain policy, projection,
//! and activation planning exposed through UniFFI.

uniffi::setup_scaffolding!();

pub mod domain;
pub mod ingest;
pub mod query;
pub mod reduce;
pub mod runtime_activation;
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

use domain::{
    default_workspace_id, display_name, now_rfc3339, AppSnapshot, IngestHookEventCommand,
    IngestShellSignalCommand, MutateIdeaCommand, MutateProjectCommand, MutateWorktreeCommand,
    MutationOutcome, ProjectMutationKind,
};
use runtime_artifacts::{count_artifacts_in_dir, count_hooks_in_dir};
use runtime_config::{load_hud_config_with_storage, resolve_symlink, save_hud_config_with_storage};
use runtime_projects::{has_project_indicators, load_projects_with_storage};
use runtime_sessions::ProjectStatus;
use runtime_setup::{DependencyStatus, HookStatus, InstallResult, SetupChecker, SetupStatus};
use runtime_storage::StorageConfig;
use runtime_types::{
    DashboardData, GlobalConfig, HookDiagnosticReport, HookIssue, HookTestResult, Plugin,
    PluginManifest, SuggestedProject,
};
use runtime_validation::{create_claude_md, validate_project_path, ValidationResultFfi};
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

        Ok(Arc::new(Self {
            state: std::sync::Mutex::new(state),
            snapshot_storage,
            app_storage,
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

    fn setup_checker(&self) -> SetupChecker {
        SetupChecker::new(self.app_storage.clone())
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

    fn test_state_file_io(&self) -> bool {
        runtime_state::snapshot::runtime_health().unwrap_or(false)
    }
}

fn heartbeat_status(
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

fn has_active_runtime_session(
    snapshot: Option<&runtime_state::snapshot::RuntimeSessionsSnapshot>,
) -> bool {
    let snapshot = match snapshot {
        Some(snapshot) => snapshot,
        None => return false,
    };

    snapshot.sessions().iter().any(|record| {
        let is_alive = record.is_alive.unwrap_or(true);
        let is_active = !matches!(record.state.to_ascii_lowercase().as_str(), "idle");
        is_alive && is_active
    })
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
        let state = self.lock_state()?;
        Ok(query::app_snapshot(&state))
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
        let projects = load_projects_with_storage(&self.app_storage).unwrap_or_default();

        Ok(DashboardData {
            global,
            plugins,
            projects,
        })
    }

    pub fn get_suggested_projects(&self) -> Result<Vec<SuggestedProject>, CoreRuntimeError> {
        let projects_dir = self.app_storage.claude_root().join("projects");
        if !projects_dir.exists() {
            return Ok(Vec::new());
        }

        let config = load_hud_config_with_storage(&self.app_storage);
        let pinned_set: std::collections::HashSet<_> = config.pinned_projects.iter().collect();

        let mut suggestions: Vec<(SuggestedProject, u32)> = Vec::new();

        if let Ok(entries) = fs_err::read_dir(&projects_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }

                let encoded_name = entry.file_name().to_string_lossy().to_string();
                if let Some(real_path) = runtime_projects::try_resolve_encoded_path(&encoded_name) {
                    if pinned_set.contains(&real_path) {
                        continue;
                    }

                    let project_path = PathBuf::from(&real_path);

                    if let Ok(home) = std::env::var("HOME") {
                        if real_path == home {
                            continue;
                        }
                    }

                    let is_child_of_pinned = config
                        .pinned_projects
                        .iter()
                        .any(|pinned| project_path.starts_with(pinned));
                    if is_child_of_pinned {
                        continue;
                    }

                    let has_indicators = has_project_indicators(&project_path);
                    let has_claude_md = project_path.join("CLAUDE.md").exists();

                    if !has_indicators && !has_claude_md {
                        continue;
                    }

                    let task_count = fs_err::read_dir(entry.path())
                        .map(|entries| {
                            entries
                                .filter_map(|e| e.ok())
                                .take(100)
                                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                                .count() as u32
                        })
                        .unwrap_or(0);

                    let display_path = if real_path.starts_with("/Users/") {
                        format!(
                            "~/{}",
                            real_path.split('/').skip(3).collect::<Vec<_>>().join("/")
                        )
                    } else {
                        real_path.clone()
                    };

                    let name = real_path
                        .split('/')
                        .next_back()
                        .unwrap_or(&real_path)
                        .to_string();

                    suggestions.push((
                        SuggestedProject {
                            path: real_path,
                            display_path,
                            name,
                            task_count,
                            has_claude_md,
                            has_project_indicators: has_indicators,
                        },
                        task_count,
                    ));
                }
            }
        }

        suggestions.sort_by(|a, b| b.1.cmp(&a.1));
        Ok(suggestions.into_iter().take(8).map(|(s, _)| s).collect())
    }

    pub fn add_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);

        if !std::path::Path::new(&path).exists() {
            return Err(CoreRuntimeError::from(format!(
                "Path does not exist: {path}"
            )));
        }

        if config.pinned_projects.contains(&path) {
            return Err(CoreRuntimeError::from(format!(
                "Project already pinned: {path}"
            )));
        }

        config.pinned_projects.push(path);
        save_hud_config_with_storage(&self.app_storage, &config).map_err(CoreRuntimeError::from)
    }

    pub fn remove_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);
        config.pinned_projects.retain(|p| p != &path);
        save_hud_config_with_storage(&self.app_storage, &config).map_err(CoreRuntimeError::from)
    }

    pub fn validate_project(&self, path: String) -> ValidationResultFfi {
        let config = load_hud_config_with_storage(&self.app_storage);
        validate_project_path(&path, &config.pinned_projects).into()
    }

    pub fn create_project_claude_md(&self, project_path: String) -> Result<(), CoreRuntimeError> {
        create_claude_md(&project_path).map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_project_status(&self, project_path: String) -> Option<ProjectStatus> {
        runtime_sessions::read_project_status(&project_path)
    }

    pub fn capture_idea(
        &self,
        project_path: String,
        idea_text: String,
    ) -> Result<String, CoreRuntimeError> {
        runtime_ideas::capture_idea_with_storage(&self.app_storage, &project_path, &idea_text)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn load_ideas(
        &self,
        project_path: String,
    ) -> Result<Vec<runtime_types::Idea>, CoreRuntimeError> {
        runtime_ideas::load_ideas_with_storage(&self.app_storage, &project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_status(
        &self,
        project_path: String,
        idea_id: String,
        new_status: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::update_idea_status_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_status,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_effort(
        &self,
        project_path: String,
        idea_id: String,
        new_effort: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::update_idea_effort_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_effort,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_triage(
        &self,
        project_path: String,
        idea_id: String,
        new_triage: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::update_idea_triage_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_triage,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_title(
        &self,
        project_path: String,
        idea_id: String,
        new_title: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::update_idea_title_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_title,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_description(
        &self,
        project_path: String,
        idea_id: String,
        new_description: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::update_idea_description_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_description,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn save_ideas_order(
        &self,
        project_path: String,
        idea_ids: Vec<String>,
    ) -> Result<(), CoreRuntimeError> {
        runtime_ideas::save_ideas_order_with_storage(&self.app_storage, &project_path, idea_ids)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn load_ideas_order(&self, project_path: String) -> Result<Vec<String>, CoreRuntimeError> {
        runtime_ideas::load_ideas_order_with_storage(&self.app_storage, &project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_ideas_file_path(&self, project_path: String) -> String {
        self.app_storage
            .project_ideas_file(&project_path)
            .to_string_lossy()
            .to_string()
    }

    pub fn check_setup_status(&self) -> SetupStatus {
        self.setup_checker().check_setup_status()
    }

    pub fn check_dependency(&self, name: String) -> DependencyStatus {
        self.setup_checker().check_dependency(&name)
    }

    pub fn install_hook_binary_from_path(
        &self,
        source_path: String,
    ) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .install_binary_from_path(&source_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn install_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .install_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn remove_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .remove_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_hook_status(&self) -> HookStatus {
        self.setup_checker().check_setup_status().hooks
    }

    pub fn check_hook_health(&self) -> runtime_types::HookHealthReport {
        const HOOK_HEALTH_THRESHOLD_SECS: u64 = 60;
        const HOOK_HEALTH_GRACE_SECS: u64 = 300;

        let heartbeat_path = self.app_storage.root().join("hud-hook-heartbeat");
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;

        let (status, age) = match std::fs::metadata(&heartbeat_path) {
            Ok(meta) => match meta.modified() {
                Ok(mtime) => {
                    let age_secs = mtime.elapsed().map(|d| d.as_secs()).unwrap_or(0);
                    let has_active_session = if age_secs > threshold_secs {
                        has_active_runtime_session(
                            runtime_state::snapshot::sessions_snapshot().as_ref(),
                        )
                    } else {
                        false
                    };

                    let status = heartbeat_status(
                        age_secs,
                        threshold_secs,
                        HOOK_HEALTH_GRACE_SECS,
                        has_active_session,
                    );
                    (status, Some(age_secs))
                }
                Err(e) => (
                    runtime_types::HookHealthStatus::Unreadable {
                        reason: e.to_string(),
                    },
                    None,
                ),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (runtime_types::HookHealthStatus::Unknown, None)
            }
            Err(e) => (
                runtime_types::HookHealthStatus::Unreadable {
                    reason: e.to_string(),
                },
                None,
            ),
        };

        runtime_types::HookHealthReport {
            status,
            heartbeat_path: heartbeat_path.display().to_string(),
            threshold_secs,
            last_heartbeat_age_secs: age,
        }
    }

    pub fn get_hook_diagnostic(&self) -> HookDiagnosticReport {
        let setup_status = self.check_setup_status();
        let health = self.check_hook_health();

        let binary_ok = setup_status
            .dependencies
            .iter()
            .find(|d| d.name == "hud-hook")
            .map(|d| d.found)
            .unwrap_or(false);

        let config_ok = matches!(setup_status.hooks, HookStatus::Installed { .. });
        let firing_ok = matches!(health.status, runtime_types::HookHealthStatus::Healthy);
        let is_first_run = matches!(health.status, runtime_types::HookHealthStatus::Unknown);

        let primary_issue: Option<HookIssue> = match &setup_status.hooks {
            HookStatus::PolicyBlocked { reason } => Some(HookIssue::PolicyBlocked {
                reason: reason.clone(),
            }),
            HookStatus::SymlinkBroken { target, reason } => Some(HookIssue::SymlinkBroken {
                target: target.clone(),
                reason: reason.clone(),
            }),
            HookStatus::BinaryBroken { reason } => Some(HookIssue::BinaryBroken {
                reason: reason.clone(),
            }),
            _ if !binary_ok => Some(HookIssue::BinaryMissing),
            HookStatus::NotInstalled => Some(HookIssue::ConfigMissing),
            HookStatus::Installed { .. } => match &health.status {
                runtime_types::HookHealthStatus::Healthy => None,
                runtime_types::HookHealthStatus::Unknown => Some(HookIssue::NotFiring {
                    last_seen_secs: None,
                }),
                runtime_types::HookHealthStatus::Stale { last_seen_secs } => {
                    Some(HookIssue::NotFiring {
                        last_seen_secs: Some(*last_seen_secs),
                    })
                }
                runtime_types::HookHealthStatus::Unreadable { .. } => None,
            },
        };

        let can_auto_fix = !matches!(primary_issue, Some(HookIssue::PolicyBlocked { .. }));
        let is_healthy = primary_issue.is_none();

        let symlink_path = dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| std::path::PathBuf::from("/usr/local/bin/hud-hook"));

        let symlink_target = if symlink_path.is_symlink() {
            std::fs::read_link(&symlink_path)
                .ok()
                .map(|p| p.to_string_lossy().to_string())
        } else {
            None
        };

        HookDiagnosticReport {
            is_healthy,
            primary_issue,
            can_auto_fix,
            is_first_run,
            binary_ok,
            config_ok,
            firing_ok,
            symlink_path: symlink_path.to_string_lossy().to_string(),
            symlink_target,
            last_heartbeat_age_secs: health.last_heartbeat_age_secs,
        }
    }

    pub fn run_hook_test(&self) -> HookTestResult {
        let health = self.check_hook_health();
        let heartbeat_ok = matches!(health.status, runtime_types::HookHealthStatus::Healthy);
        let heartbeat_age = health.last_heartbeat_age_secs;

        let state_file_ok = self.test_state_file_io();
        let success = heartbeat_ok && state_file_ok;
        let message = if success {
            "Hooks are working correctly".to_string()
        } else if !heartbeat_ok {
            match heartbeat_age {
                Some(age) => format!(
                    "Heartbeat stale ({}s ago). Start a Claude session to test.",
                    age
                ),
                None => "No heartbeat detected. Start a Claude session to test hooks.".to_string(),
            }
        } else {
            "Runtime health check failed. Ensure the runtime snapshot is available.".to_string()
        };

        HookTestResult {
            success,
            heartbeat_ok,
            heartbeat_age_secs: heartbeat_age,
            state_file_ok,
            message,
        }
    }

    pub fn resolve_activation_with_trace(
        &self,
        project_path: String,
        shell_state: Option<runtime_activation::ShellCwdStateFfi>,
        tmux_context: runtime_activation::TmuxContextFfi,
        include_trace: bool,
    ) -> runtime_activation::ActivationDecision {
        runtime_activation::resolve_activation_with_trace(
            &project_path,
            shell_state.as_ref(),
            &tmux_context,
            include_trace,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::CoreRuntime;
    use crate::domain::{
        HookEventType, IngestHookEventCommand, MutateProjectCommand, ProjectMutationKind,
    };

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
}
