use chrono::Utc;

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Working,
    Ready,
    #[default]
    Idle,
    Compacting,
    Waiting,
}

impl SessionState {
    #[must_use]
    pub fn priority(self) -> u8 {
        match self {
            Self::Waiting => 4,
            Self::Compacting => 3,
            Self::Working => 2,
            Self::Ready => 1,
            Self::Idle => 0,
        }
    }

    #[must_use]
    pub fn is_active(self) -> bool {
        matches!(self, Self::Working | Self::Waiting | Self::Compacting)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ProjectSummary {
    pub project_path: String,
    pub project_id: String,
    pub workspace_id: String,
    pub display_name: String,
    pub state: SessionState,
    pub state_changed_at: String,
    pub updated_at: String,
    pub representative_session_id: Option<String>,
    pub latest_session_id: Option<String>,
    pub session_count: u64,
    pub active_count: u64,
    pub has_session: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SessionSummary {
    pub session_id: String,
    pub pid: u32,
    pub cwd: String,
    pub project_id: String,
    pub project_path: String,
    pub workspace_id: String,
    pub state: SessionState,
    pub state_changed_at: String,
    pub updated_at: String,
    pub last_event: Option<String>,
    pub last_activity_at: Option<String>,
    pub tools_in_flight: u32,
    pub ready_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ShellSignal {
    pub pid: u32,
    pub cwd: String,
    pub tty: String,
    pub parent_app: String,
    pub tmux_session: Option<String>,
    pub updated_at: String,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum RoutingStatus {
    Attached,
    Detached,
    #[default]
    Unavailable,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum RoutingTargetKind {
    TmuxSession,
    TerminalApp,
    #[default]
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct RoutingView {
    pub workspace_id: String,
    pub project_path: String,
    pub status: RoutingStatus,
    pub target_kind: RoutingTargetKind,
    pub target_value: Option<String>,
    pub reason_code: String,
    pub reason: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct DiagnosticsSummary {
    pub events_ingested: u64,
    pub sessions_tracked: u64,
    pub shell_signals_tracked: u64,
    #[serde(default)]
    pub events_skipped: u64,
    #[serde(default)]
    pub stale_events_skipped: u64,
    #[serde(default)]
    pub informational_events_skipped: u64,
    #[serde(default)]
    pub reducer_events_skipped: u64,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct AppSnapshot {
    pub projects: Vec<ProjectSummary>,
    pub sessions: Vec<SessionSummary>,
    pub shells: Vec<ShellSignal>,
    pub routing: Vec<RoutingView>,
    pub diagnostics: DiagnosticsSummary,
    pub generated_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum HookEventType {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    PermissionRequest,
    PreCompact,
    Notification,
    SubagentStart,
    SubagentStop,
    Stop,
    TeammateIdle,
    TaskCompleted,
    WorktreeCreate,
    WorktreeRemove,
    ConfigChange,
    SessionEnd,
    Unknown,
}

impl HookEventType {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "session_start",
            Self::UserPromptSubmit => "user_prompt_submit",
            Self::PreToolUse => "pre_tool_use",
            Self::PostToolUse => "post_tool_use",
            Self::PostToolUseFailure => "post_tool_use_failure",
            Self::PermissionRequest => "permission_request",
            Self::PreCompact => "pre_compact",
            Self::Notification => "notification",
            Self::SubagentStart => "subagent_start",
            Self::SubagentStop => "subagent_stop",
            Self::Stop => "stop",
            Self::TeammateIdle => "teammate_idle",
            Self::TaskCompleted => "task_completed",
            Self::WorktreeCreate => "worktree_create",
            Self::WorktreeRemove => "worktree_remove",
            Self::ConfigChange => "config_change",
            Self::SessionEnd => "session_end",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct IngestHookEventCommand {
    pub event_id: String,
    pub recorded_at: String,
    pub event_type: HookEventType,
    pub session_id: String,
    pub pid: Option<u32>,
    pub project_path: String,
    pub cwd: Option<String>,
    pub file_path: Option<String>,
    pub workspace_id: Option<String>,
    pub notification_type: Option<String>,
    pub stop_hook_active: Option<bool>,
    pub tool_name: Option<String>,
    pub agent_id: Option<String>,
    pub teammate_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct IngestShellSignalCommand {
    pub pid: u32,
    pub cwd: String,
    pub tty: String,
    pub parent_app: String,
    pub tmux_session: Option<String>,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ProjectMutationKind {
    Add,
    Remove,
    Rename,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MutateProjectCommand {
    pub kind: ProjectMutationKind,
    pub project_path: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum IdeaMutationKind {
    Add,
    Update,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MutateIdeaCommand {
    pub kind: IdeaMutationKind,
    pub project_path: String,
    pub idea_id: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub status: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeMutationKind {
    Create,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MutateWorktreeCommand {
    pub kind: WorktreeMutationKind,
    pub repo_path: String,
    pub worktree_name: String,
    pub force: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MutationOutcome {
    pub ok: bool,
    pub message: String,
}

#[must_use]
pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}
