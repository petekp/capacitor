use crate::runtime_storage::StorageConfig;

use super::domain::{ConnectProjectRequest, ProjectCatalogSnapshot, SuggestedProjectCandidate};
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
        let _ = &self.app_storage;
        Err(ProjectPortError::Unimplemented)
    }

    fn connect_project(&self, request: &ConnectProjectRequest) -> Result<(), ProjectPortError> {
        let _ = (&self.app_storage, request);
        Err(ProjectPortError::Unimplemented)
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
    fn suggest_projects(&self) -> Result<Vec<SuggestedProjectCandidate>, ProjectPortError> {
        let _ = &self.app_storage;
        Err(ProjectPortError::Unimplemented)
    }
}
