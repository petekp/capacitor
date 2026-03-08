use std::sync::Arc;

use super::domain::{ConnectProjectRequest, ProjectCatalogSnapshot};
use super::ports::{ProjectCatalogStore, ProjectPortError, WorkspaceInspectorPort};
use crate::runtime_types::ShellSuggestedProjectCandidate;
use crate::runtime_validation::ValidationResultFfi;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ProjectCatalogError {
    #[error(transparent)]
    Port(#[from] ProjectPortError),
}

pub(crate) struct ProjectCatalogService {
    catalog_store: Arc<dyn ProjectCatalogStore>,
    workspace_inspector: Arc<dyn WorkspaceInspectorPort>,
}

impl ProjectCatalogService {
    pub(crate) fn new(
        catalog_store: Arc<dyn ProjectCatalogStore>,
        workspace_inspector: Arc<dyn WorkspaceInspectorPort>,
    ) -> Self {
        Self {
            catalog_store,
            workspace_inspector,
        }
    }

    pub(crate) fn refresh_project_catalog(
        &self,
    ) -> Result<ProjectCatalogSnapshot, ProjectCatalogError> {
        self.catalog_store.load_catalog().map_err(Into::into)
    }

    pub(crate) fn connect_project(
        &self,
        request: &ConnectProjectRequest,
    ) -> Result<(), ProjectCatalogError> {
        self.catalog_store
            .connect_project(request)
            .map_err(Into::into)
    }

    pub(crate) fn remove_project(&self, path: &str) -> Result<(), ProjectCatalogError> {
        self.catalog_store.remove_project(path).map_err(Into::into)
    }

    pub(crate) fn validate_project(
        &self,
        path: &str,
    ) -> Result<ValidationResultFfi, ProjectCatalogError> {
        self.catalog_store
            .validate_project(path)
            .map_err(Into::into)
    }

    pub(crate) fn create_project_claude_md(
        &self,
        project_path: &str,
    ) -> Result<(), ProjectCatalogError> {
        self.catalog_store
            .create_project_claude_md(project_path)
            .map_err(Into::into)
    }

    pub(crate) fn suggest_projects(
        &self,
    ) -> Result<Vec<ShellSuggestedProjectCandidate>, ProjectCatalogError> {
        self.workspace_inspector
            .suggest_projects()
            .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::clean::kernel::Timestamp;
    use crate::runtime_types::{ShellProjectCatalogEntry, ShellSuggestedProjectCandidate};
    use crate::runtime_validation::ValidationResultFfi;

    #[derive(Default)]
    struct StubProjectCatalogStore {
        connected_paths: Mutex<Vec<String>>,
        removed_paths: Mutex<Vec<String>>,
        created_claude_md_paths: Mutex<Vec<String>>,
    }

    impl ProjectCatalogStore for StubProjectCatalogStore {
        fn load_catalog(&self) -> Result<ProjectCatalogSnapshot, ProjectPortError> {
            Ok(ProjectCatalogSnapshot {
                projects: vec![ShellProjectCatalogEntry {
                    id: "/tmp/caps".to_string(),
                    display_name: "caps".to_string(),
                    path: "/tmp/caps".to_string(),
                    display_path: "/tmp/caps".to_string(),
                    last_active_at: None,
                    claude_md_path: None,
                    claude_md_preview: None,
                    has_local_settings: false,
                    task_count: 0,
                    stats: None,
                    is_missing: false,
                }],
                refreshed_at: Timestamp("2026-03-08T00:00:00Z".to_string()),
            })
        }

        fn connect_project(&self, request: &ConnectProjectRequest) -> Result<(), ProjectPortError> {
            self.connected_paths
                .lock()
                .expect("connected paths")
                .push(request.path.clone());
            Ok(())
        }

        fn remove_project(&self, path: &str) -> Result<(), ProjectPortError> {
            self.removed_paths
                .lock()
                .expect("removed paths")
                .push(path.to_string());
            Ok(())
        }

        fn validate_project(&self, path: &str) -> Result<ValidationResultFfi, ProjectPortError> {
            Ok(ValidationResultFfi {
                result_type: "valid".to_string(),
                path: path.to_string(),
                suggested_path: None,
                reason: None,
                has_claude_md: true,
                has_other_markers: true,
            })
        }

        fn create_project_claude_md(&self, project_path: &str) -> Result<(), ProjectPortError> {
            self.created_claude_md_paths
                .lock()
                .expect("created claude md paths")
                .push(project_path.to_string());
            Ok(())
        }
    }

    #[derive(Default)]
    struct StubWorkspaceInspector;

    impl WorkspaceInspectorPort for StubWorkspaceInspector {
        fn suggest_projects(
            &self,
        ) -> Result<Vec<ShellSuggestedProjectCandidate>, ProjectPortError> {
            Ok(vec![ShellSuggestedProjectCandidate {
                id: "/tmp/suggested".to_string(),
                display_name: "suggested".to_string(),
                path: "/tmp/suggested".to_string(),
                display_path: "/tmp/suggested".to_string(),
                task_count: 3,
                has_claude_md: true,
                has_project_indicators: true,
            }])
        }
    }

    #[test]
    fn project_catalog_service_routes_all_operations_through_ports() {
        let store = Arc::new(StubProjectCatalogStore::default());
        let service = ProjectCatalogService::new(store.clone(), Arc::new(StubWorkspaceInspector));

        let snapshot = service
            .refresh_project_catalog()
            .expect("refresh project catalog");
        assert_eq!(snapshot.projects.len(), 1);
        assert_eq!(snapshot.projects[0].path, "/tmp/caps");

        service
            .connect_project(&ConnectProjectRequest {
                path: "/tmp/connected".to_string(),
                display_name: Some("connected".to_string()),
            })
            .expect("connect project");
        assert_eq!(
            store
                .connected_paths
                .lock()
                .expect("connected paths")
                .as_slice(),
            ["/tmp/connected"],
        );

        service
            .remove_project("/tmp/connected")
            .expect("remove project");
        assert_eq!(
            store
                .removed_paths
                .lock()
                .expect("removed paths")
                .as_slice(),
            ["/tmp/connected"],
        );

        let validation = service
            .validate_project("/tmp/connected")
            .expect("validate project");
        assert_eq!(validation.result_type, "valid");

        service
            .create_project_claude_md("/tmp/connected")
            .expect("create claude md");
        assert_eq!(
            store
                .created_claude_md_paths
                .lock()
                .expect("created claude md paths")
                .as_slice(),
            ["/tmp/connected"],
        );

        let suggestions = service.suggest_projects().expect("suggest projects");
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].path, "/tmp/suggested");
    }
}
