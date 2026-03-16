//! Canonical Capacitor core runtime.
//!
//! This crate is the long-term source of truth for runtime facts, ingest,
//! reducer/query state, and projections exposed through UniFFI.

uniffi::setup_scaffolding!();

pub mod domain;
pub mod ingest;
pub mod observation;
pub mod projection;
pub mod query;
pub mod reduce;
pub mod runtime_artifacts;
pub mod runtime_boundaries;
pub mod runtime_config;
pub mod runtime_contracts;
pub mod runtime_error;
pub mod runtime_ideas;
pub mod runtime_patterns;
pub mod runtime_projects;
pub mod runtime_service;
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
    IngestShellSignalCommand, MutateDelegationCommand, MutateIdeaCommand, MutateProjectCommand,
    MutateWorktreeCommand, MutationOutcome, ProjectMutationKind, ResolveRoutingCommand,
    RoutingView,
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

    fn test_runtime_service_health(&self) -> bool {
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

fn hook_event_age_secs(timestamp: Option<&str>) -> Option<u64> {
    let timestamp = timestamp?;
    let parsed = chrono::DateTime::parse_from_rfc3339(timestamp).ok()?;
    let parsed = parsed.with_timezone(&Utc);
    let age = Utc::now().signed_duration_since(parsed).num_seconds();
    if age < 0 {
        Some(0)
    } else {
        Some(age as u64)
    }
}

fn has_active_runtime_session(
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
        let state = self.lock_state()?;
        Ok(query::app_snapshot(&state))
    }

    pub fn resolve_routing(
        &self,
        command: ResolveRoutingCommand,
    ) -> Result<RoutingView, CoreRuntimeError> {
        let state = self.lock_state()?;
        Ok(state.resolve_routing(command))
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
                state.delegations.remove(&normalized_path);
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

    pub fn mutate_delegation(
        &self,
        command: MutateDelegationCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = state.apply_delegation_mutation(command);
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
        let threshold_secs = HOOK_HEALTH_THRESHOLD_SECS;
        let snapshot = runtime_state::snapshot::hook_health_snapshot();
        let age = snapshot
            .as_ref()
            .and_then(|snapshot| hook_event_age_secs(snapshot.last_hook_event_at.as_deref()));
        let has_active_session = if age.is_some_and(|age_secs| age_secs > threshold_secs) {
            snapshot
                .as_ref()
                .map(|snapshot| {
                    has_active_runtime_session(Some(&snapshot.sessions), HOOK_HEALTH_GRACE_SECS)
                })
                .unwrap_or(false)
        } else {
            false
        };

        let status = match age {
            Some(age_secs) => heartbeat_status(
                age_secs,
                threshold_secs,
                HOOK_HEALTH_GRACE_SECS,
                has_active_session,
            ),
            None => runtime_types::HookHealthStatus::Unknown,
        };

        runtime_types::HookHealthReport {
            status,
            signal_source: "runtime_service_snapshot".to_string(),
            threshold_secs,
            last_hook_event_age_secs: age,
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
            last_hook_event_age_secs: health.last_hook_event_age_secs,
        }
    }

    pub fn run_hook_test(&self) -> HookTestResult {
        let health = self.check_hook_health();
        let hook_activity_ok = matches!(health.status, runtime_types::HookHealthStatus::Healthy);
        let hook_activity_age = health.last_hook_event_age_secs;

        let runtime_service_ok = self.test_runtime_service_health();
        let success = hook_activity_ok && runtime_service_ok;
        let message = if success {
            "Hooks are working correctly".to_string()
        } else if !hook_activity_ok {
            match hook_activity_age {
                Some(age) => format!(
                    "Hook activity stale ({}s ago). Start a Claude session to test.",
                    age
                ),
                None => "No recent hook activity detected. Start a Claude session to test hooks."
                    .to_string(),
            }
        } else {
            "Runtime health check failed. Ensure the local runtime service is available."
                .to_string()
        };

        HookTestResult {
            success,
            hook_activity_ok,
            hook_activity_age_secs: hook_activity_age,
            runtime_service_ok,
            message,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CoreRuntime;
    use crate::domain::{
        AppSnapshot, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
        MutateProjectCommand, ProjectMutationKind, ProjectSummary, SessionState, SessionSummary,
    };
    use crate::runtime_service::{RUNTIME_SERVICE_PORT_ENV, RUNTIME_SERVICE_TOKEN_ENV};
    use crate::runtime_state::snapshot::test_support::{
        env_lock as shared_env_lock, MockRuntimeService, MockRuntimeServiceRoute,
    };
    use crate::runtime_state::snapshot::{RuntimeSessionRecord, RuntimeSessionsSnapshot};
    use crate::runtime_storage::StorageConfig;
    use crate::runtime_types::HookHealthStatus;
    use crate::storage::InMemorySnapshotStorage;
    use chrono::{Duration, Utc};
    use std::fs;
    use std::sync::Arc;
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
        let result = runtime.run_hook_test();

        assert!(result.success, "result was {result:?}");
        assert!(result.hook_activity_ok, "result was {result:?}");
        assert!(result.runtime_service_ok, "result was {result:?}");
        runtime_service.finish();
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

    fn snapshot_payload(
        sessions: Vec<SessionSummary>,
        last_hook_event_at: Option<String>,
    ) -> Vec<u8> {
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
            delegations: vec![],
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
        };
        let mut value = serde_json::to_value(snapshot).expect("serialize snapshot to value");
        if let Some(last_hook_event_at) = last_hook_event_at {
            value["diagnostics"]["last_hook_event_at"] =
                serde_json::Value::String(last_hook_event_at);
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
                        "auth_mode": "bearer",
                        "service_mode": "bootstrap_only",
                    }),
                ),
            ],
        )
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
}
