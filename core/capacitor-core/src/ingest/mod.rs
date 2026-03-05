use crate::domain::{
    normalize_path_for_matching, IngestHookEventCommand, IngestShellSignalCommand,
};

#[must_use]
pub fn normalize_hook_event(command: IngestHookEventCommand) -> IngestHookEventCommand {
    IngestHookEventCommand {
        event_id: command.event_id.trim().to_string(),
        recorded_at: command.recorded_at.trim().to_string(),
        event_type: command.event_type,
        session_id: command.session_id.trim().to_string(),
        pid: command.pid,
        project_path: normalize_required_path(&command.project_path),
        cwd: normalize_optional_path(command.cwd),
        file_path: normalize_optional_path(command.file_path),
        workspace_id: normalize_optional_text(command.workspace_id),
        notification_type: normalize_optional_text(command.notification_type),
        stop_hook_active: command.stop_hook_active,
        tool_name: normalize_optional_text(command.tool_name),
        agent_id: normalize_optional_text(command.agent_id),
        teammate_name: normalize_optional_text(command.teammate_name),
    }
}

#[must_use]
pub fn normalize_shell_signal(command: IngestShellSignalCommand) -> IngestShellSignalCommand {
    IngestShellSignalCommand {
        pid: command.pid,
        cwd: normalize_required_path(&command.cwd),
        tty: command.tty.trim().to_string(),
        parent_app: command.parent_app.trim().to_string(),
        tmux_session: normalize_optional_text(command.tmux_session),
        tmux_client_tty: normalize_optional_text(command.tmux_client_tty),
        recorded_at: command.recorded_at.trim().to_string(),
    }
}

#[must_use]
fn normalize_required_path(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    normalize_path_for_matching(trimmed)
}

#[must_use]
fn normalize_optional_path(value: Option<String>) -> Option<String> {
    value
        .map(|value| normalize_required_path(&value))
        .filter(|value| !value.is_empty())
}

#[must_use]
fn normalize_optional_text(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::normalize_hook_event;
    use crate::domain::{HookEventType, IngestHookEventCommand};

    #[test]
    fn normalize_hook_event_cleans_optional_fields() {
        let normalized = normalize_hook_event(IngestHookEventCommand {
            event_id: " evt-1 ".to_string(),
            recorded_at: " 2026-02-28T00:00:00Z ".to_string(),
            event_type: HookEventType::Notification,
            session_id: " session-1 ".to_string(),
            pid: Some(42),
            project_path: " /repo/ ".to_string(),
            cwd: Some(" /repo/src/ ".to_string()),
            file_path: Some(" src/main.rs ".to_string()),
            workspace_id: Some("  ".to_string()),
            notification_type: Some(" idle_prompt ".to_string()),
            stop_hook_active: None,
            tool_name: Some("  ".to_string()),
            agent_id: Some(" agent-1 ".to_string()),
            teammate_name: Some(" ".to_string()),
        });

        assert_eq!(normalized.event_id, "evt-1");
        assert_eq!(normalized.session_id, "session-1");
        assert_eq!(normalized.project_path, "/repo");
        assert_eq!(normalized.cwd.as_deref(), Some("/repo/src"));
        assert_eq!(normalized.file_path.as_deref(), Some("src/main.rs"));
        assert_eq!(normalized.notification_type.as_deref(), Some("idle_prompt"));
        assert_eq!(normalized.agent_id.as_deref(), Some("agent-1"));
        assert_eq!(normalized.workspace_id, None);
        assert_eq!(normalized.tool_name, None);
        assert_eq!(normalized.teammate_name, None);
    }
}
