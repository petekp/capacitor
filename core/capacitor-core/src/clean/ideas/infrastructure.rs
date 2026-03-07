use crate::runtime_storage::StorageConfig;

use super::domain::{IdeaDraft, IdeaRecord, WorkstreamPlan};
use super::ports::{IdeaPortError, IdeaRepository, WorktreePort};

pub(crate) struct LiveIdeaRepository {
    app_storage: StorageConfig,
}

impl LiveIdeaRepository {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl IdeaRepository for LiveIdeaRepository {
    fn load_backlog(&self) -> Result<Vec<IdeaRecord>, IdeaPortError> {
        let _ = &self.app_storage;
        Err(IdeaPortError::Unimplemented)
    }

    fn capture_idea(&self, draft: &IdeaDraft) -> Result<IdeaRecord, IdeaPortError> {
        let _ = (&self.app_storage, draft);
        Err(IdeaPortError::Unimplemented)
    }
}

pub(crate) struct LiveWorktreePort {
    app_storage: StorageConfig,
}

impl LiveWorktreePort {
    pub(crate) fn new(app_storage: StorageConfig) -> Self {
        Self { app_storage }
    }
}

impl WorktreePort for LiveWorktreePort {
    fn create_project_from_idea(&self, plan: &WorkstreamPlan) -> Result<(), IdeaPortError> {
        let _ = (&self.app_storage, plan);
        Err(IdeaPortError::Unimplemented)
    }
}
