//! Runtime client helper for sending hook and shell events into the local runtime service.
//!
//! Outside the service process this client discovers the authenticated local
//! runtime endpoint. Inside `hud-hook serve` it reuses the registered runtime
//! instance directly so the adapter and runtime stay on one semantic path.

use capacitor_core::{
    domain::{HookEventType, IngestHookEventCommand, IngestShellSignalCommand},
    runtime_service::{RuntimeServiceEndpoint, RUNTIME_SERVICE_DEFAULT_PORT},
    runtime_types::ParentApp,
    CoreRuntime,
};
use chrono::Utc;
use rand::RngCore;
use std::sync::{Arc, OnceLock};

const ENABLE_ENV: &str = "CAPACITOR_CORE_ENABLED";

use crate::hook_types::{HookEvent, HookInput};

static REGISTERED_SERVICE_RUNTIME: OnceLock<Arc<CoreRuntime>> = OnceLock::new();

pub fn register_service_runtime(runtime: Arc<CoreRuntime>) -> Result<(), String> {
    REGISTERED_SERVICE_RUNTIME
        .set(runtime)
        .map_err(|_| "runtime service already registered in this process".to_string())
}

pub fn send_handle_event(
    event: &HookEvent,
    hook_input: &HookInput,
    session_id: &str,
    pid: Option<u32>,
    cwd: &str,
) -> bool {
    let event_type = match event_type_for_hook(event) {
        Some(event_type) => event_type,
        None => return false,
    };

    let command = IngestHookEventCommand {
        event_id: make_event_id(pid.unwrap_or(0)),
        recorded_at: Utc::now().to_rfc3339(),
        event_type,
        session_id: session_id.to_string(),
        pid,
        project_path: cwd.to_string(),
        cwd: Some(cwd.to_string()),
        file_path: event_file_path(event, hook_input),
        workspace_id: None,
        notification_type: event_notification_type(event),
        stop_hook_active: event_stop_hook_active(event),
        tool_name: event_tool_name(event, hook_input),
        agent_id: normalize_optional(&hook_input.agent_id),
        teammate_name: normalize_optional(&hook_input.teammate_name),
    };

    send_event(command).is_ok()
}

#[allow(clippy::too_many_arguments)]
pub fn send_shell_cwd_event(
    pid: u32,
    cwd: &str,
    tty: &str,
    parent_app: ParentApp,
    tmux_session: Option<String>,
    tmux_client_tty: Option<String>,
    _proc_start: Option<u64>,
    _tmux_pane: Option<String>,
) -> Result<(), String> {
    let command = IngestShellSignalCommand {
        pid,
        cwd: cwd.to_string(),
        tty: tty.to_string(),
        parent_app: parent_app_string(parent_app),
        tmux_session,
        tmux_client_tty,
        recorded_at: Utc::now().to_rfc3339(),
    };

    send_shell_signal(command)
}

pub fn runtime_enabled() -> bool {
    env_flag(ENABLE_ENV).unwrap_or(true)
}

fn send_event(command: IngestHookEventCommand) -> Result<(), String> {
    match runtime_transport()? {
        RuntimeTransport::Service(endpoint) => endpoint.ingest_hook_event(&command).map(|_| ()),
        RuntimeTransport::RegisteredService(runtime) => runtime
            .ingest_hook_event(command)
            .map(|_| ())
            .map_err(|error| error.to_string()),
    }
}

fn send_shell_signal(command: IngestShellSignalCommand) -> Result<(), String> {
    match runtime_transport()? {
        RuntimeTransport::Service(endpoint) => endpoint.ingest_shell_signal(&command).map(|_| ()),
        RuntimeTransport::RegisteredService(runtime) => runtime
            .ingest_shell_signal(command)
            .map(|_| ())
            .map_err(|error| error.to_string()),
    }
}

enum RuntimeTransport {
    Service(RuntimeServiceEndpoint),
    RegisteredService(Arc<CoreRuntime>),
}

fn runtime_transport() -> Result<RuntimeTransport, String> {
    if !runtime_enabled() {
        return Err("Core runtime disabled".to_string());
    }

    if let Some(runtime) = REGISTERED_SERVICE_RUNTIME.get() {
        return Ok(RuntimeTransport::RegisteredService(Arc::clone(runtime)));
    }

    runtime_service_endpoint()?
        .map(RuntimeTransport::Service)
        .ok_or_else(|| "runtime service endpoint unavailable".to_string())
}

fn runtime_service_endpoint() -> Result<Option<RuntimeServiceEndpoint>, String> {
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    RuntimeServiceEndpoint::discover(&home, RUNTIME_SERVICE_DEFAULT_PORT)
}

fn event_type_for_hook(event: &HookEvent) -> Option<HookEventType> {
    match event {
        HookEvent::SessionStart => Some(HookEventType::SessionStart),
        HookEvent::UserPromptSubmit => Some(HookEventType::UserPromptSubmit),
        HookEvent::PreToolUse { .. } => Some(HookEventType::PreToolUse),
        HookEvent::PostToolUse { .. } => Some(HookEventType::PostToolUse),
        HookEvent::PostToolUseFailure { .. } => Some(HookEventType::PostToolUseFailure),
        HookEvent::PermissionRequest => Some(HookEventType::PermissionRequest),
        HookEvent::PreCompact => Some(HookEventType::PreCompact),
        HookEvent::Notification { .. } => Some(HookEventType::Notification),
        HookEvent::SubagentStart => Some(HookEventType::SubagentStart),
        HookEvent::SubagentStop => Some(HookEventType::SubagentStop),
        HookEvent::Stop { .. } => Some(HookEventType::Stop),
        HookEvent::TeammateIdle => Some(HookEventType::TeammateIdle),
        HookEvent::TaskCompleted => Some(HookEventType::TaskCompleted),
        HookEvent::WorktreeCreate => Some(HookEventType::WorktreeCreate),
        HookEvent::WorktreeRemove => Some(HookEventType::WorktreeRemove),
        HookEvent::ConfigChange => Some(HookEventType::ConfigChange),
        HookEvent::SessionEnd => Some(HookEventType::SessionEnd),
        HookEvent::Unknown { .. } => None,
    }
}

fn event_tool_name(event: &HookEvent, hook_input: &HookInput) -> Option<String> {
    let tool = match event {
        HookEvent::PreToolUse { tool_name, .. }
        | HookEvent::PostToolUse { tool_name, .. }
        | HookEvent::PostToolUseFailure { tool_name, .. } => tool_name.clone(),
        HookEvent::PermissionRequest => hook_input.tool_name.clone(),
        _ => None,
    };

    normalize_optional(&tool)
}

fn event_file_path(event: &HookEvent, hook_input: &HookInput) -> Option<String> {
    let fallback_input_path = hook_input
        .tool_input
        .as_ref()
        .and_then(|input| input.file_path.clone().or_else(|| input.path.clone()));

    let file = match event {
        HookEvent::PreToolUse { file_path, .. }
        | HookEvent::PostToolUse { file_path, .. }
        | HookEvent::PostToolUseFailure { file_path, .. } => file_path.clone(),
        HookEvent::PermissionRequest => fallback_input_path,
        _ => None,
    };

    normalize_optional(&file)
}

fn event_notification_type(event: &HookEvent) -> Option<String> {
    match event {
        HookEvent::Notification { notification_type } => {
            normalize_optional(&Some(notification_type.clone()))
        }
        _ => None,
    }
}

fn event_stop_hook_active(event: &HookEvent) -> Option<bool> {
    match event {
        HookEvent::Stop { stop_hook_active } => Some(*stop_hook_active),
        _ => None,
    }
}

fn normalize_optional(value: &Option<String>) -> Option<String> {
    value
        .as_ref()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn env_flag(key: &str) -> Option<bool> {
    std::env::var(key).ok().and_then(|value| parse_bool(&value))
}

fn parse_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn make_event_id(pid: u32) -> String {
    let mut random = rand::thread_rng();
    let rand = random.next_u64();
    format!("evt-{}-{}-{:x}", Utc::now().timestamp_millis(), pid, rand)
}

fn parent_app_string(app: ParentApp) -> String {
    serde_json::to_string(&app)
        .unwrap_or_else(|_| "unknown".to_string())
        .trim_matches('"')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook_types::{HookEvent, HookInput, ToolInput};
    use std::collections::BTreeMap;

    #[test]
    fn parse_bool_handles_common_flags() {
        assert_eq!(parse_bool("1"), Some(true));
        assert_eq!(parse_bool("true"), Some(true));
        assert_eq!(parse_bool("0"), Some(false));
        assert_eq!(parse_bool("false"), Some(false));
        assert_eq!(parse_bool("maybe"), None);
    }

    #[test]
    fn event_type_mapping_is_complete_for_known_events() {
        assert_eq!(
            event_type_for_hook(&HookEvent::TaskCompleted),
            Some(HookEventType::TaskCompleted)
        );
        assert_eq!(
            event_type_for_hook(&HookEvent::Stop {
                stop_hook_active: false
            }),
            Some(HookEventType::Stop)
        );
        assert_eq!(
            event_type_for_hook(&HookEvent::Unknown {
                event_name: "FutureEvent".to_string()
            }),
            None
        );
    }

    #[test]
    fn file_path_prefers_event_payload_then_fallback_input() {
        let hook_input = HookInput {
            hook_event_name: Some("PermissionRequest".to_string()),
            session_id: Some("session-1".to_string()),
            transcript_path: None,
            cwd: Some("/repo".to_string()),
            permission_mode: None,
            trigger: None,
            prompt: None,
            custom_instructions: None,
            notification_type: None,
            message: None,
            title: None,
            stop_hook_active: None,
            last_assistant_message: None,
            tool_name: Some("Read".to_string()),
            tool_use_id: None,
            tool_input: Some(ToolInput {
                file_path: Some(" src/main.rs ".to_string()),
                path: None,
                extra: BTreeMap::new(),
            }),
            tool_response: None,
            error: None,
            is_interrupt: None,
            permission_suggestions: None,
            source: None,
            reason: None,
            model: None,
            agent_id: None,
            agent_type: None,
            agent_transcript_path: None,
            teammate_name: None,
            team_name: None,
            task_id: None,
            task_subject: None,
            task_description: None,
            extra: BTreeMap::new(),
        };

        let event = HookEvent::PermissionRequest;
        let path = event_file_path(&event, &hook_input);
        assert_eq!(path.as_deref(), Some("src/main.rs"));
    }
}
