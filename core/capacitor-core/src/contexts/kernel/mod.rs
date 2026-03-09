#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct ProjectId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct WorkspaceId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct SessionId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct Timestamp(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct CorrelationId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct TtyHandle(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct ProjectRef {
    pub(crate) id: ProjectId,
    pub(crate) workspace_id: WorkspaceId,
    pub(crate) path: String,
    pub(crate) display_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub(crate) struct TerminalCoordinate {
    pub(crate) application: String,
    pub(crate) tty: Option<TtyHandle>,
    pub(crate) tmux_session: Option<String>,
}
