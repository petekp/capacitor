#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookTransport {
    Command,
    Http,
    Prompt,
    Agent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClaudeHookEventContract {
    pub event_name: &'static str,
    pub allowed_transports: &'static [HookTransport],
    pub managed_transport: Option<HookTransport>,
    pub needs_matcher: bool,
}

const COMMAND_ONLY: &[HookTransport] = &[HookTransport::Command];
const COMMAND_HTTP: &[HookTransport] = &[HookTransport::Command, HookTransport::Http];
const FULL_INTERACTIVE: &[HookTransport] = &[
    HookTransport::Command,
    HookTransport::Http,
    HookTransport::Prompt,
    HookTransport::Agent,
];

const CLAUDE_HOOK_EVENT_CONTRACTS: [ClaudeHookEventContract; 18] = [
    ClaudeHookEventContract {
        event_name: "SessionStart",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "InstructionsLoaded",
        allowed_transports: COMMAND_ONLY,
        managed_transport: None,
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "UserPromptSubmit",
        allowed_transports: FULL_INTERACTIVE,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "PreToolUse",
        allowed_transports: FULL_INTERACTIVE,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: true,
    },
    ClaudeHookEventContract {
        event_name: "PermissionRequest",
        allowed_transports: FULL_INTERACTIVE,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: true,
    },
    ClaudeHookEventContract {
        event_name: "PostToolUse",
        allowed_transports: FULL_INTERACTIVE,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: true,
    },
    ClaudeHookEventContract {
        event_name: "PostToolUseFailure",
        allowed_transports: FULL_INTERACTIVE,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: true,
    },
    ClaudeHookEventContract {
        event_name: "Notification",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "Stop",
        allowed_transports: COMMAND_HTTP,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "SubagentStart",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "SubagentStop",
        allowed_transports: COMMAND_HTTP,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "PreCompact",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "TeammateIdle",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "TaskCompleted",
        allowed_transports: COMMAND_HTTP,
        managed_transport: Some(HookTransport::Http),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "ConfigChange",
        allowed_transports: COMMAND_ONLY,
        managed_transport: None,
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "SessionEnd",
        allowed_transports: COMMAND_ONLY,
        managed_transport: Some(HookTransport::Command),
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "WorktreeCreate",
        allowed_transports: COMMAND_ONLY,
        managed_transport: None,
        needs_matcher: false,
    },
    ClaudeHookEventContract {
        event_name: "WorktreeRemove",
        allowed_transports: COMMAND_ONLY,
        managed_transport: None,
        needs_matcher: false,
    },
];

pub fn all_claude_hook_event_contracts() -> &'static [ClaudeHookEventContract] {
    &CLAUDE_HOOK_EVENT_CONTRACTS
}

pub fn managed_hook_event_contracts() -> impl Iterator<Item = &'static ClaudeHookEventContract> {
    CLAUDE_HOOK_EVENT_CONTRACTS
        .iter()
        .filter(|contract| contract.managed_transport.is_some())
}

pub fn find_claude_hook_event_contract(
    event_name: &str,
) -> Option<&'static ClaudeHookEventContract> {
    CLAUDE_HOOK_EVENT_CONTRACTS
        .iter()
        .find(|contract| contract.event_name == event_name)
}

pub fn find_managed_hook_event_contract(
    event_name: &str,
) -> Option<&'static ClaudeHookEventContract> {
    find_claude_hook_event_contract(event_name)
        .filter(|contract| contract.managed_transport.is_some())
}
