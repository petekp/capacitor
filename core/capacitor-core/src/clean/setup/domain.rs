use crate::clean::kernel::Timestamp;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SetupRequirementKind {
    ClaudeCli,
    HookBinary,
    ShellIntegration,
    Permissions,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct SetupRequirement {
    pub(crate) kind: Option<SetupRequirementKind>,
    pub(crate) satisfied: bool,
    pub(crate) detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct SetupReadiness {
    pub(crate) ready: bool,
    pub(crate) requirements: Vec<SetupRequirement>,
    pub(crate) checked_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SetupAction {
    InstallHookBinary,
    InstallHooks,
    InstallShellSnippet,
    RepairPermissions,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct SetupPlan {
    pub(crate) actions: Vec<SetupAction>,
    pub(crate) generated_at: Timestamp,
}
