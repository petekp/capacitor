use crate::clean::projects::domain::{ConnectProjectRequest, ProjectCatalogSnapshot};
use crate::runtime_types::ShellSuggestedProjectCandidate;
use crate::runtime_validation::ValidationResultFfi;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ProjectPortError {
    #[error("project shell is not implemented")]
    Unimplemented,
    #[error("{0}")]
    Message(String),
}

impl From<String> for ProjectPortError {
    fn from(value: String) -> Self {
        Self::Message(value)
    }
}

pub(crate) trait ProjectCatalogStore: Send + Sync {
    fn load_catalog(&self) -> Result<ProjectCatalogSnapshot, ProjectPortError>;
    fn connect_project(&self, request: &ConnectProjectRequest) -> Result<(), ProjectPortError>;
    fn remove_project(&self, path: &str) -> Result<(), ProjectPortError>;
    fn validate_project(&self, path: &str) -> Result<ValidationResultFfi, ProjectPortError>;
    fn create_project_claude_md(&self, project_path: &str) -> Result<(), ProjectPortError>;
}

pub(crate) trait WorkspaceInspectorPort: Send + Sync {
    fn suggest_projects(&self) -> Result<Vec<ShellSuggestedProjectCandidate>, ProjectPortError>;
}
