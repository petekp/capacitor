use std::sync::Arc;

use super::domain::{ConnectProjectRequest, ProjectCatalogSnapshot, SuggestedProjectCandidate};
use super::ports::{ProjectCatalogStore, ProjectPortError, WorkspaceInspectorPort};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ProjectCatalogError {
    #[error(transparent)]
    Port(#[from] ProjectPortError),
    #[error("project shell is not implemented")]
    Unimplemented,
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
        let _ = (&self.catalog_store, &self.workspace_inspector);
        todo!("Shell scaffold only")
    }

    pub(crate) fn connect_project(
        &self,
        request: &ConnectProjectRequest,
    ) -> Result<(), ProjectCatalogError> {
        let _ = (&self.catalog_store, &self.workspace_inspector, request);
        todo!("Shell scaffold only")
    }

    pub(crate) fn suggest_projects(
        &self,
    ) -> Result<Vec<SuggestedProjectCandidate>, ProjectCatalogError> {
        let _ = (&self.catalog_store, &self.workspace_inspector);
        todo!("Shell scaffold only")
    }
}
