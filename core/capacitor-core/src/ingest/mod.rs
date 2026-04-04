use crate::domain::{
    normalize_path_for_matching, IngestHookEventCommand, IngestShellSignalCommand, TmuxPaneInfo,
};

#[must_use]
pub(crate) fn normalize_hook_event(command: IngestHookEventCommand) -> IngestHookEventCommand {
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
pub(crate) fn normalize_shell_signal(
    command: IngestShellSignalCommand,
) -> IngestShellSignalCommand {
    IngestShellSignalCommand {
        pid: command.pid,
        cwd: normalize_required_path(&command.cwd),
        tty: command.tty.trim().to_string(),
        parent_app: command.parent_app.trim().to_string(),
        tmux_session: normalize_optional_text(command.tmux_session),
        tmux_client_tty: normalize_optional_text(command.tmux_client_tty),
        tmux_pane: normalize_optional_text(command.tmux_pane),
        tmux_panes: normalize_tmux_panes(command.tmux_panes),
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

#[must_use]
fn normalize_tmux_panes(value: Vec<TmuxPaneInfo>) -> Vec<TmuxPaneInfo> {
    value
        .into_iter()
        .filter_map(|pane| {
            let session_name = pane.session_name.trim().to_string();
            let pane_id = pane.pane_id.trim().to_string();
            let pane_path = normalize_required_path(&pane.pane_path);
            if session_name.is_empty() || pane_id.is_empty() || pane_path.is_empty() {
                return None;
            }
            Some(TmuxPaneInfo {
                session_name,
                pane_id,
                pane_path,
                session_attached: pane.session_attached,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{normalize_hook_event, normalize_shell_signal};
    use crate::domain::{
        HookEventType, IngestHookEventCommand, IngestShellSignalCommand, TmuxPaneInfo,
    };

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

    #[test]
    fn normalize_shell_signal_cleans_tmux_fields() {
        let normalized = normalize_shell_signal(IngestShellSignalCommand {
            pid: 42,
            cwd: " /repo/ ".to_string(),
            tty: " /dev/ttys001 ".to_string(),
            parent_app: " Ghostty ".to_string(),
            tmux_session: Some(" repo ".to_string()),
            tmux_client_tty: Some(" /dev/ttys099 ".to_string()),
            tmux_pane: Some(" %42 ".to_string()),
            tmux_panes: vec![TmuxPaneInfo {
                session_name: " repo ".to_string(),
                pane_id: " %42 ".to_string(),
                pane_path: " /repo/apps/swift/ ".to_string(),
                session_attached: true,
            }],
            recorded_at: " 2026-02-28T00:00:00Z ".to_string(),
        });

        assert_eq!(normalized.cwd, "/repo");
        assert_eq!(normalized.tty, "/dev/ttys001");
        assert_eq!(normalized.parent_app, "Ghostty");
        assert_eq!(normalized.tmux_session.as_deref(), Some("repo"));
        assert_eq!(normalized.tmux_client_tty.as_deref(), Some("/dev/ttys099"));
        assert_eq!(normalized.tmux_pane.as_deref(), Some("%42"));
        assert_eq!(normalized.tmux_panes.len(), 1);
        assert_eq!(normalized.tmux_panes[0].session_name, "repo");
        assert_eq!(normalized.tmux_panes[0].pane_id, "%42");
        assert_eq!(normalized.tmux_panes[0].pane_path, "/repo/apps/swift");
        assert!(normalized.tmux_panes[0].session_attached);
    }
}
