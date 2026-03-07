use crate::clean::kernel::{CorrelationId, ProjectRef, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum IdeaStatus {
    Inbox,
    Planned,
    Archived,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct IdeaDraft {
    pub(crate) correlation_id: CorrelationId,
    pub(crate) project: Option<ProjectRef>,
    pub(crate) title: String,
    pub(crate) description: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct IdeaRecord {
    pub(crate) id: String,
    pub(crate) draft: IdeaDraft,
    pub(crate) status: Option<IdeaStatus>,
    pub(crate) captured_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct WorkstreamPlan {
    pub(crate) idea_id: String,
    pub(crate) project: Option<ProjectRef>,
    pub(crate) worktree_name: Option<String>,
}
