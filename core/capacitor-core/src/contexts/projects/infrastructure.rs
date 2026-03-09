use crate::domain::now_rfc3339;
use crate::runtime_config::{load_hud_config_with_storage, save_hud_config_with_storage};
use crate::runtime_projects::{load_projects_with_storage, suggest_projects_with_storage};
use crate::runtime_storage::StorageConfig;
use crate::runtime_types::ShellSuggestedProjectCandidate;
use crate::runtime_validation::ValidationResultFfi;
use crate::runtime_validation::{create_claude_md, validate_project_path};

use super::domain::{ConnectProjectRequest, ProjectCatalogSnapshot};
use super::ports::{ProjectCatalogStore, ProjectPortError, WorkspaceInspectorPort};

pub(crate) struct LiveProjectCatalogStore {
    app_storage: StorageConfig,
}

impl LiveProjectCatalogStore {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl ProjectCatalogStore for LiveProjectCatalogStore {
    fn load_catalog(&self) -> Result<ProjectCatalogSnapshot, ProjectPortError> {
        Ok(ProjectCatalogSnapshot {
            projects: load_projects_with_storage(&self.app_storage)?,
            refreshed_at: crate::contexts::kernel::Timestamp(now_rfc3339()),
        })
    }

    fn connect_project(&self, request: &ConnectProjectRequest) -> Result<(), ProjectPortError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);

        if !std::path::Path::new(&request.path).exists() {
            return Err(ProjectPortError::from(format!(
                "Path does not exist: {}",
                request.path
            )));
        }

        if config.pinned_projects.contains(&request.path) {
            return Err(ProjectPortError::from(format!(
                "Project already pinned: {}",
                request.path
            )));
        }

        config.pinned_projects.push(request.path.clone());
        save_hud_config_with_storage(&self.app_storage, &config).map_err(Into::into)
    }

    fn remove_project(&self, path: &str) -> Result<(), ProjectPortError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);
        config.pinned_projects.retain(|p| p != path);
        save_hud_config_with_storage(&self.app_storage, &config).map_err(Into::into)
    }

    fn validate_project(&self, path: &str) -> Result<ValidationResultFfi, ProjectPortError> {
        let config = load_hud_config_with_storage(&self.app_storage);
        Ok(validate_project_path(path, &config.pinned_projects).into())
    }

    fn create_project_claude_md(&self, project_path: &str) -> Result<(), ProjectPortError> {
        create_claude_md(project_path).map_err(|error| ProjectPortError::from(error.to_string()))
    }
}

pub(crate) struct LiveWorkspaceInspector {
    app_storage: StorageConfig,
}

impl LiveWorkspaceInspector {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl WorkspaceInspectorPort for LiveWorkspaceInspector {
    fn suggest_projects(&self) -> Result<Vec<ShellSuggestedProjectCandidate>, ProjectPortError> {
        suggest_projects_with_storage(&self.app_storage).map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_types::HudConfig;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn live_project_catalog_store_loads_connects_validates_and_removes_projects() {
        let temp = tempdir().expect("temp dir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));
        fs::create_dir_all(storage.root()).expect("create capacitor root");
        fs::create_dir_all(storage.claude_root()).expect("create claude root");

        let project_path = temp.path().join("caps-project");
        fs::create_dir_all(&project_path).expect("create project");
        fs::write(project_path.join("CLAUDE.md"), "# Caps").expect("write claude md");

        save_hud_config_with_storage(
            &storage,
            &HudConfig {
                pinned_projects: vec![project_path.to_string_lossy().to_string()],
                terminal_app: "Ghostty".to_string(),
            },
        )
        .expect("save config");

        let store = LiveProjectCatalogStore::new(storage.clone());

        let snapshot = store.load_catalog().expect("load catalog");
        assert_eq!(snapshot.projects.len(), 1);
        assert_eq!(snapshot.projects[0].path, project_path.to_string_lossy());
        assert!(snapshot.refreshed_at.0.contains('T'));
        assert!(
            snapshot.refreshed_at.0.ends_with('Z') || snapshot.refreshed_at.0.ends_with("+00:00")
        );

        let validation = store
            .validate_project(project_path.to_string_lossy().as_ref())
            .expect("validate project");
        assert_eq!(validation.result_type, "already_tracked");

        let new_project_path = temp.path().join("new-project");
        fs::create_dir_all(&new_project_path).expect("create new project");
        fs::write(
            new_project_path.join("Cargo.toml"),
            "[package]\nname = \"caps\"\n",
        )
        .expect("write cargo toml");

        store
            .connect_project(&ConnectProjectRequest {
                path: new_project_path.to_string_lossy().to_string(),
                display_name: None,
            })
            .expect("connect project");

        let config = load_hud_config_with_storage(&storage);
        assert!(config
            .pinned_projects
            .contains(&new_project_path.to_string_lossy().to_string()));

        store
            .create_project_claude_md(new_project_path.to_string_lossy().as_ref())
            .expect("create claude md");
        assert!(new_project_path.join("CLAUDE.md").exists());

        store
            .remove_project(new_project_path.to_string_lossy().as_ref())
            .expect("remove project");
        let config_after_remove = load_hud_config_with_storage(&storage);
        assert!(!config_after_remove
            .pinned_projects
            .contains(&new_project_path.to_string_lossy().to_string()));
    }

    #[test]
    fn live_workspace_inspector_suggests_unpinned_projects_from_claude_sessions() {
        let temp = tempdir().expect("temp dir");
        let storage =
            StorageConfig::with_roots(temp.path().join(".capacitor"), temp.path().join(".claude"));
        fs::create_dir_all(storage.root()).expect("create capacitor root");
        fs::create_dir_all(storage.claude_projects_dir()).expect("create claude projects root");

        let suggested_path = temp.path().join("suggest-me");
        fs::create_dir_all(&suggested_path).expect("create suggested project");
        fs::write(
            suggested_path.join("Cargo.toml"),
            "[package]\nname = \"suggest-me\"\n",
        )
        .expect("write cargo toml");

        let encoded =
            crate::runtime_projects::encode_project_path(suggested_path.to_string_lossy().as_ref());
        let claude_project_dir = storage.claude_projects_dir().join(encoded);
        fs::create_dir_all(&claude_project_dir).expect("create claude project dir");
        fs::write(claude_project_dir.join("session-1.jsonl"), "{}\n").expect("write session");

        let inspector = LiveWorkspaceInspector::new(storage);
        let suggestions = inspector.suggest_projects().expect("suggest projects");

        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].path, suggested_path.to_string_lossy());
        assert_eq!(suggestions[0].display_name, "suggest-me");
        assert_eq!(suggestions[0].task_count, 1);
        assert!(suggestions[0].has_project_indicators);
    }
}
