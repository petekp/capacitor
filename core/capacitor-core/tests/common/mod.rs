use capacitor_core::domain::{HookEventType, IngestHookEventCommand};

pub fn valid_hook_event_command(event_type: HookEventType) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: "evt-1".to_string(),
        recorded_at: "2099-02-28T19:00:00Z".to_string(),
        event_type,
        session_id: "session-1".to_string(),
        pid: Some(4242),
        project_path: "/tmp/core-project".to_string(),
        cwd: Some("/tmp/core-project".to_string()),
        file_path: None,
        workspace_id: None,
        notification_type: None,
        stop_hook_active: None,
        tool_name: None,
        agent_id: None,
        teammate_name: None,
    }
}
