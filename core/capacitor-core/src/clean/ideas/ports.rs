use crate::clean::ideas::domain::{
    CaptureIdeaRequest, IdeaBacklog, IdeaFieldUpdateRequest, IdeasOrderRequest, WorkstreamPlan,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum IdeaPortError {
    #[error("idea shell is not implemented")]
    Unimplemented,
    #[error("{0}")]
    Message(String),
}

impl From<String> for IdeaPortError {
    fn from(value: String) -> Self {
        Self::Message(value)
    }
}

pub(crate) trait IdeaRepository: Send + Sync {
    fn load_backlog(&self, project_path: &str) -> Result<IdeaBacklog, IdeaPortError>;
    fn capture_idea(&self, request: &CaptureIdeaRequest) -> Result<String, IdeaPortError>;
    fn update_idea_status(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError>;
    fn update_idea_effort(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError>;
    fn update_idea_triage(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError>;
    fn update_idea_title(&self, request: &IdeaFieldUpdateRequest) -> Result<(), IdeaPortError>;
    fn update_idea_description(
        &self,
        request: &IdeaFieldUpdateRequest,
    ) -> Result<(), IdeaPortError>;
    fn save_ideas_order(&self, request: &IdeasOrderRequest) -> Result<(), IdeaPortError>;
    fn load_ideas_order(&self, project_path: &str) -> Result<Vec<String>, IdeaPortError>;
    fn ideas_file_path(&self, project_path: &str) -> String;
}

pub(crate) trait WorktreePort: Send + Sync {
    fn create_project_from_idea(&self, plan: &WorkstreamPlan) -> Result<(), IdeaPortError>;
}
