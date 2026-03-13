use crate::domain::{IngestHookEventCommand, IngestShellSignalCommand};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObservationSourceKind {
    ClaudeHook,
    ShellSignal,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ObservationPayload {
    HookEvent(IngestHookEventCommand),
    ShellSignal(IngestShellSignalCommand),
}

#[derive(Debug, Clone, PartialEq)]
pub struct ObservationRecord {
    pub source_kind: ObservationSourceKind,
    pub recorded_at: String,
    pub idempotency_key: String,
    pub payload: ObservationPayload,
}

impl ObservationRecord {
    #[must_use]
    pub fn from_hook_event(command: IngestHookEventCommand) -> Self {
        let idempotency_key = format!(
            "hook:{}:{}:{}",
            command.event_id, command.session_id, command.recorded_at
        );

        Self {
            source_kind: ObservationSourceKind::ClaudeHook,
            recorded_at: command.recorded_at.clone(),
            idempotency_key,
            payload: ObservationPayload::HookEvent(command),
        }
    }

    #[must_use]
    pub fn from_shell_signal(command: IngestShellSignalCommand) -> Self {
        let idempotency_key = format!(
            "shell:{}:{}:{}",
            command.pid, command.tty, command.recorded_at
        );

        Self {
            source_kind: ObservationSourceKind::ShellSignal,
            recorded_at: command.recorded_at.clone(),
            idempotency_key,
            payload: ObservationPayload::ShellSignal(command),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ObservationPayload, ObservationRecord, ObservationSourceKind};
    use crate::domain::{HookEventType, IngestHookEventCommand, IngestShellSignalCommand};

    #[test]
    fn observation_record_from_hook_event_captures_source_and_idempotency() {
        let observation = ObservationRecord::from_hook_event(IngestHookEventCommand {
            event_id: "evt-1".to_string(),
            recorded_at: "2026-03-09T12:00:00Z".to_string(),
            event_type: HookEventType::UserPromptSubmit,
            session_id: "session-1".to_string(),
            pid: Some(42),
            project_path: "/repo".to_string(),
            cwd: Some("/repo".to_string()),
            file_path: None,
            workspace_id: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            agent_id: None,
            teammate_name: None,
        });

        assert_eq!(observation.source_kind, ObservationSourceKind::ClaudeHook);
        assert_eq!(observation.recorded_at, "2026-03-09T12:00:00Z");
        assert_eq!(
            observation.idempotency_key,
            "hook:evt-1:session-1:2026-03-09T12:00:00Z"
        );
        assert!(matches!(
            observation.payload,
            ObservationPayload::HookEvent(_)
        ));
    }

    #[test]
    fn observation_record_from_shell_signal_captures_source_and_idempotency() {
        let observation = ObservationRecord::from_shell_signal(IngestShellSignalCommand {
            pid: 42,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            recorded_at: "2026-03-09T12:00:00Z".to_string(),
        });

        assert_eq!(observation.source_kind, ObservationSourceKind::ShellSignal);
        assert_eq!(observation.recorded_at, "2026-03-09T12:00:00Z");
        assert_eq!(
            observation.idempotency_key,
            "shell:42:/dev/ttys001:2026-03-09T12:00:00Z"
        );
        assert!(matches!(
            observation.payload,
            ObservationPayload::ShellSignal(_)
        ));
    }
}
