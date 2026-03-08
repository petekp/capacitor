use crate::clean::kernel::Timestamp;
use crate::runtime_types::ShellProjectCatalogEntry;

#[derive(Debug, Clone, Default)]
pub(crate) struct ProjectCatalogSnapshot {
    pub(crate) projects: Vec<ShellProjectCatalogEntry>,
    pub(crate) refreshed_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ConnectProjectRequest {
    pub(crate) path: String,
    pub(crate) display_name: Option<String>,
}
