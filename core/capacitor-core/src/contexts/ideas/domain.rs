use crate::runtime_types::Idea;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct CaptureIdeaRequest {
    pub(crate) project_path: String,
    pub(crate) idea_text: String,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct IdeaBacklog {
    pub(crate) ideas: Vec<Idea>,
    pub(crate) order: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct IdeaFieldUpdateRequest {
    pub(crate) project_path: String,
    pub(crate) idea_id: String,
    pub(crate) new_value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct IdeasOrderRequest {
    pub(crate) project_path: String,
    pub(crate) idea_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct WorkstreamPlan {
    pub(crate) idea_id: String,
    pub(crate) project_path: Option<String>,
    pub(crate) worktree_name: Option<String>,
}
