use crate::clean::kernel::{ProjectRef, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CatalogSource {
    Explicit,
    Suggested,
    Discovered,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ProjectCatalogEntry {
    pub(crate) project: ProjectRef,
    pub(crate) last_activity_at: Option<Timestamp>,
    pub(crate) is_pinned: bool,
    pub(crate) source: Option<CatalogSource>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct SuggestedProjectCandidate {
    pub(crate) path: String,
    pub(crate) display_name: String,
    pub(crate) reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ProjectCatalogSnapshot {
    pub(crate) entries: Vec<ProjectCatalogEntry>,
    pub(crate) suggested: Vec<SuggestedProjectCandidate>,
    pub(crate) refreshed_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ConnectProjectRequest {
    pub(crate) path: String,
    pub(crate) display_name: Option<String>,
}
