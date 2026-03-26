use capacitor_core::runtime_contracts::{
    all_claude_hook_event_contracts, find_claude_hook_event_contract, managed_hook_event_contracts,
    HookTransport,
};

#[test]
fn managed_hook_contract_uses_only_documented_transports() {
    for contract in managed_hook_event_contracts() {
        let managed = contract
            .managed_transport
            .expect("managed contract should declare a managed transport");
        assert!(
            contract.allowed_transports.contains(&managed),
            "managed transport {:?} must be documented for {}",
            managed,
            contract.event_name
        );
    }
}

#[test]
fn all_managed_events_use_command_transport() {
    for contract in managed_hook_event_contracts() {
        assert_eq!(
            contract.managed_transport,
            Some(HookTransport::Command),
            "{} should use command transport (unified command transport)",
            contract.event_name,
        );
    }
}

#[test]
fn command_only_events_remain_command_only_in_allowed_transports() {
    for event_name in [
        "SessionStart",
        "SessionEnd",
        "Notification",
        "PreCompact",
        "SubagentStart",
        "TeammateIdle",
    ] {
        let contract = find_claude_hook_event_contract(event_name)
            .unwrap_or_else(|| panic!("missing contract for {event_name}"));
        assert_eq!(
            contract.allowed_transports,
            &[HookTransport::Command],
            "{event_name} should remain command-only in allowed_transports",
        );
    }
}

#[test]
fn documented_contract_contains_expected_hook_events() {
    let events: Vec<_> = all_claude_hook_event_contracts()
        .iter()
        .map(|contract| contract.event_name)
        .collect();

    for event_name in [
        "SessionStart",
        "InstructionsLoaded",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "Notification",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "TeammateIdle",
        "TaskCompleted",
        "ConfigChange",
        "SessionEnd",
        "WorktreeCreate",
        "WorktreeRemove",
    ] {
        assert!(
            events.contains(&event_name),
            "expected contract entry for {event_name}"
        );
    }
}
