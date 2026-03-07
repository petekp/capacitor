use crate::clean::projects::domain::{
    ConnectProjectRequest, ProjectCatalogSnapshot, SuggestedProjectCandidate,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ProjectPortError {
    #[error("project shell is not implemented")]
    Unimplemented,
}

pub(crate) trait ProjectCatalogStore: Send + Sync {
    fn load_catalog(&self) -> Result<ProjectCatalogSnapshot, ProjectPortError>;
    fn connect_project(&self, request: &ConnectProjectRequest) -> Result<(), ProjectPortError>;
}

pub(crate) trait WorkspaceInspectorPort: Send + Sync {
    fn suggest_projects(&self) -> Result<Vec<SuggestedProjectCandidate>, ProjectPortError>;
}
