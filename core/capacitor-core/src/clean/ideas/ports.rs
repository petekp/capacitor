use crate::clean::ideas::domain::{IdeaDraft, IdeaRecord, WorkstreamPlan};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum IdeaPortError {
    #[error("idea shell is not implemented")]
    Unimplemented,
}

pub(crate) trait IdeaRepository: Send + Sync {
    fn load_backlog(&self) -> Result<Vec<IdeaRecord>, IdeaPortError>;
    fn capture_idea(&self, draft: &IdeaDraft) -> Result<IdeaRecord, IdeaPortError>;
}

pub(crate) trait WorktreePort: Send + Sync {
    fn create_project_from_idea(&self, plan: &WorkstreamPlan) -> Result<(), IdeaPortError>;
}
