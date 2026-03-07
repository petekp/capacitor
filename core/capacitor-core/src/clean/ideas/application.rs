use std::sync::Arc;

use super::domain::{IdeaDraft, IdeaRecord, WorkstreamPlan};
use super::ports::{IdeaPortError, IdeaRepository, WorktreePort};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum IdeaServiceError {
    #[error(transparent)]
    Port(#[from] IdeaPortError),
    #[error("idea shell is not implemented")]
    Unimplemented,
}

pub(crate) struct IdeaService {
    repository: Arc<dyn IdeaRepository>,
    worktree_port: Arc<dyn WorktreePort>,
}

impl IdeaService {
    pub(crate) fn new(
        repository: Arc<dyn IdeaRepository>,
        worktree_port: Arc<dyn WorktreePort>,
    ) -> Self {
        Self {
            repository,
            worktree_port,
        }
    }

    pub(crate) fn load_idea_backlog(&self) -> Result<Vec<IdeaRecord>, IdeaServiceError> {
        let _ = (&self.repository, &self.worktree_port);
        todo!("Shell scaffold only")
    }

    pub(crate) fn capture_idea(&self, draft: &IdeaDraft) -> Result<IdeaRecord, IdeaServiceError> {
        let _ = (&self.repository, &self.worktree_port, draft);
        todo!("Shell scaffold only")
    }

    pub(crate) fn create_project_from_idea(
        &self,
        plan: &WorkstreamPlan,
    ) -> Result<(), IdeaServiceError> {
        let _ = (&self.repository, &self.worktree_port, plan);
        todo!("Shell scaffold only")
    }
}
