//! Client helper for sending hook events to the capacitor daemon.
//!
//! This is a best-effort path: failures should never block or crash the hook.
//! When the daemon is unavailable, we fall back to the legacy file-based flow.

use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION,
};
use chrono::Utc;
use hud_core::state::HookEvent;
use hud_core::ParentApp;
use rand::RngCore;
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const ENABLE_ENV: &str = "CAPACITOR_DAEMON_ENABLED";
const SOCKET_ENV: &str = "CAPACITOR_DAEMON_SOCKET";
const SOCKET_NAME: &str = "daemon.sock";
const READ_TIMEOUT_MS: u64 = 150;
const WRITE_TIMEOUT_MS: u64 = 150;

pub fn send_handle_event(event: &HookEvent, session_id: &str, pid: u32, cwd: &str) {
    if !daemon_enabled() {
        return;
    }

    let event_type = match event_type_for_hook(event) {
        Some(event_type) => event_type,
        None => return,
    };

    let (tool, file_path, notification_type, stop_hook_active) = match event {
        HookEvent::PreToolUse { tool_name } => (tool_name.clone(), None, None, None),
        HookEvent::PostToolUse {
            tool_name,
            file_path,
        } => (tool_name.clone(), file_path.clone(), None, None),
        HookEvent::Notification { notification_type } => {
            (None, None, Some(notification_type.clone()), None)
        }
        HookEvent::Stop { stop_hook_active } => (None, None, None, Some(*stop_hook_active)),
        _ => (None, None, None, None),
    };

    let envelope = EventEnvelope {
        event_id: make_event_id(pid),
        recorded_at: Utc::now().to_rfc3339(),
        event_type,
        session_id: Some(session_id.to_string()),
        pid: Some(pid),
        cwd: Some(cwd.to_string()),
        tool,
        file_path,
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type,
        stop_hook_active,
        metadata: None,
    };

    if let Err(err) = send_event(envelope) {
        tracing::warn!(error = %err, "Failed to send event to daemon");
    }
}

pub fn send_shell_cwd_event(
    pid: u32,
    cwd: &str,
    tty: &str,
    parent_app: ParentApp,
    tmux_session: Option<String>,
    tmux_client_tty: Option<String>,
) {
    if !daemon_enabled() {
        return;
    }

    let envelope = EventEnvelope {
        event_id: make_event_id(pid),
        recorded_at: Utc::now().to_rfc3339(),
        event_type: EventType::ShellCwd,
        session_id: None,
        pid: Some(pid),
        cwd: Some(cwd.to_string()),
        tool: None,
        file_path: None,
        parent_app: Some(parent_app_string(parent_app)),
        tty: Some(tty.to_string()),
        tmux_session,
        tmux_client_tty,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    };

    if let Err(err) = send_event(envelope) {
        tracing::warn!(error = %err, "Failed to send shell-cwd event to daemon");
    }
}

fn daemon_enabled() -> bool {
    match env::var(ENABLE_ENV) {
        Ok(value) => matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"),
        Err(_) => false,
    }
}

fn socket_path() -> Result<PathBuf, String> {
    if let Ok(path) = env::var(SOCKET_ENV) {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join(SOCKET_NAME))
}

fn send_event(event: EventEnvelope) -> Result<(), String> {
    let socket = socket_path()?;
    let mut stream = UnixStream::connect(&socket)
        .map_err(|err| format!("Failed to connect to daemon socket: {}", err))?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(READ_TIMEOUT_MS)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(WRITE_TIMEOUT_MS)));

    let request = Request {
        protocol_version: PROTOCOL_VERSION,
        method: Method::Event,
        id: Some(event.event_id.clone()),
        params: Some(
            serde_json::to_value(event)
                .map_err(|err| format!("Failed to serialize event: {}", err))?,
        ),
    };

    serde_json::to_writer(&mut stream, &request)
        .map_err(|err| format!("Failed to write request: {}", err))?;
    stream
        .write_all(b"\n")
        .map_err(|err| format!("Failed to flush request: {}", err))?;
    stream.flush().ok();

    let response = read_response(&mut stream)?;
    if response.ok {
        Ok(())
    } else {
        let message = response
            .error
            .map(|err| format!("{}: {}", err.code, err.message))
            .unwrap_or_else(|| "Unknown daemon error".to_string());
        Err(message)
    }
}

fn read_response(stream: &mut UnixStream) -> Result<Response, String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if buffer.len() > MAX_REQUEST_BYTES {
                    return Err("Response exceeded maximum size".to_string());
                }
                if chunk[..n].contains(&b'\n') {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                return Err("Timed out waiting for daemon response".to_string());
            }
            Err(err) => return Err(format!("Failed to read response: {}", err)),
        }
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let response_bytes = match newline_index {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };

    if response_bytes.is_empty() {
        return Err("Daemon response was empty".to_string());
    }

    serde_json::from_slice(response_bytes)
        .map_err(|err| format!("Failed to parse response JSON: {}", err))
}

fn event_type_for_hook(event: &HookEvent) -> Option<EventType> {
    match event {
        HookEvent::SessionStart => Some(EventType::SessionStart),
        HookEvent::UserPromptSubmit => Some(EventType::UserPromptSubmit),
        HookEvent::PreToolUse { .. } => Some(EventType::PreToolUse),
        HookEvent::PostToolUse { .. } => Some(EventType::PostToolUse),
        HookEvent::PermissionRequest => Some(EventType::PermissionRequest),
        HookEvent::PreCompact => Some(EventType::PreCompact),
        HookEvent::Notification { .. } => Some(EventType::Notification),
        HookEvent::Stop { .. } => Some(EventType::Stop),
        HookEvent::SessionEnd => Some(EventType::SessionEnd),
        HookEvent::Unknown { .. } => None,
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
