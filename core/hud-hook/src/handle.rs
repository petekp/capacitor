//! Event handler for Claude Code hooks.
//!
//! Processes hook events and updates session state through the canonical
//! `capacitor-core` runtime. Called by the HTTP server in `serve.rs`.
//!
//! ## State Machine
//!
//! ```text
//! SessionStart           → ready
//! UserPromptSubmit       → working
//! PreToolUse/PostToolUse/PostToolUseFailure → working  (refresh if already working)
//! PermissionRequest      → waiting
//! Notification           → ready/waiting (idle_prompt|auth_success => ready, permission_prompt|elicitation_dialog => waiting)
//! TaskCompleted          → ready    (main agent only)
//! PreCompact             → compacting
//! Stop                   → ready    (unless stop_hook_active=true)
//! SessionEnd             → removes session record
//! ```

use capacitor_core::domain::SessionState;
use std::path::Path;

use crate::hook_types::{HookEvent, HookInput};

const SESSION_STATE_GATE_ID: &str = "session_state_reliability_gate_v1";
const SESSION_STATE_MAPPING_SCENARIO_ID: &str = "SS-P0-1";

pub(crate) fn handle_hook_input(hook_input: HookInput) -> Result<(), String> {
    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    handle_hook_input_with_home(hook_input, &home)
}

fn handle_hook_input_with_home(hook_input: HookInput, home: &Path) -> Result<(), String> {
    let _ = home;
    let event = match hook_input.to_event() {
        Some(e) => e,
        None => return Ok(()),
    };
    if let HookEvent::Unknown { event_name } = &event {
        tracing::debug!(
            gate_id = SESSION_STATE_GATE_ID,
            scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
            classification = "unhandled_unknown",
            transition = "skip",
            skip_reason = "unknown_hook_event",
            event_name = %event_name,
            session_id = ?hook_input.session_id,
            "Skipping unknown hook event"
        );
        return Ok(());
    }

    let session_id = match &hook_input.session_id {
        Some(id) => id.clone(),
        None => {
            tracing::debug!(
                gate_id = SESSION_STATE_GATE_ID,
                scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
                classification = "stateful_noop",
                transition = "skip",
                skip_reason = "missing_session_id",
                event = ?hook_input.hook_event_name,
                "Skipping event (missing session_id)"
            );
            return Ok(());
        }
    };

    if !crate::runtime_client::runtime_enabled() {
        return Err("Core runtime disabled".to_string());
    }

    let cwd = hook_input.resolve_cwd(None);
    let (action, _new_state, _file_activity) = process_event(&event, None, &hook_input);
    let (classification, transition, skip_reason) =
        classify_hook_event(&event, &hook_input, action);

    // Skip subagent Stop events — they share the parent session_id
    // but shouldn't affect the parent session's state.
    if matches!(event, HookEvent::Stop { .. }) && hook_input.agent_id.is_some() {
        tracing::debug!(
            gate_id = SESSION_STATE_GATE_ID,
            scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
            classification = "stateful_noop",
            transition = "skip",
            skip_reason = "subagent_stop_guard",
            agent_id = ?hook_input.agent_id,
            session = %session_id,
            "Skipping subagent Stop event"
        );
        return Ok(());
    }

    if cwd.is_none() && action != Action::Delete {
        tracing::debug!(
            gate_id = SESSION_STATE_GATE_ID,
            scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
            classification = "stateful_noop",
            transition = "skip",
            skip_reason = "missing_cwd",
            event = ?hook_input.hook_event_name,
            session = %session_id,
            "Skipping event (missing cwd)"
        );
        return Ok(());
    }

    let cwd = cwd.unwrap_or_default();
    // In the HTTP server model, we can't infer the Claude session's PID from
    // process hierarchy (getppid() returns the Swift app, not Claude Code).
    // Pass None and let the reducer preserve any existing session PID.
    let session_pid: Option<u32> = None;

    let runtime_sent = crate::runtime_client::send_handle_event(
        &event,
        &hook_input,
        &session_id,
        session_pid,
        &cwd,
    );
    if runtime_sent {
        if let Some(notification_type) = notification_type_for_log(&event) {
            tracing::debug!(
                gate_id = SESSION_STATE_GATE_ID,
                scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
                classification,
                transition,
                skip_reason,
                event = ?hook_input.hook_event_name,
                notification_type = %notification_type,
                session = %session_id,
                "Runtime accepted event"
            );
        } else {
            tracing::debug!(
                gate_id = SESSION_STATE_GATE_ID,
                scenario_id = SESSION_STATE_MAPPING_SCENARIO_ID,
                classification,
                transition,
                skip_reason,
                event = ?hook_input.hook_event_name,
                session = %session_id,
                "Runtime accepted event"
            );
        }
        return Ok(());
    }

    Err("Failed to send hook event to core runtime".to_string())
}

#[derive(Debug, PartialEq, Clone, Copy)]
enum Action {
    Upsert,
    Refresh,
    Delete,
    Skip,
}

fn classify_hook_event(
    event: &HookEvent,
    input: &HookInput,
    action: Action,
) -> (&'static str, &'static str, &'static str) {
    match event {
        HookEvent::SubagentStart
        | HookEvent::SubagentStop
        | HookEvent::TeammateIdle
        | HookEvent::WorktreeCreate
        | HookEvent::WorktreeRemove
        | HookEvent::ConfigChange => (
            "non_state_event",
            action_label(action),
            "informational_event",
        ),
        HookEvent::Notification { notification_type }
            if notification_type != "idle_prompt"
                && notification_type != "auth_success"
                && notification_type != "permission_prompt"
                && notification_type != "elicitation_dialog" =>
        {
            (
                "stateful_noop",
                action_label(action),
                "notification_non_stateful",
            )
        }
        HookEvent::Stop {
            stop_hook_active: true,
        } => ("stateful_noop", action_label(action), "stop_hook_active"),
        HookEvent::TaskCompleted if input.agent_id.is_some() || input.teammate_name.is_some() => (
            "stateful_noop",
            action_label(action),
            "auxiliary_task_metadata",
        ),
        _ => match action {
            Action::Skip => ("stateful_noop", "skip", "guard_skip"),
            _ => ("stateful_transition", action_label(action), "none"),
        },
    }
}

fn action_label(action: Action) -> &'static str {
    match action {
        Action::Upsert => "upsert",
        Action::Refresh => "refresh",
        Action::Delete => "delete",
        Action::Skip => "skip",
    }
}

fn notification_type_for_log(event: &HookEvent) -> Option<&str> {
    match event {
        HookEvent::Notification { notification_type } if !notification_type.is_empty() => {
            Some(notification_type.as_str())
        }
        _ => None,
    }
}

/// Returns true if the session is in an active state that shouldn't be overridden.
fn is_active_state(state: Option<SessionState>) -> bool {
    matches!(
        state,
        Some(SessionState::Working) | Some(SessionState::Waiting) | Some(SessionState::Compacting)
    )
}

fn process_event(
    event: &HookEvent,
    current_state: Option<SessionState>,
    input: &HookInput,
) -> (Action, Option<SessionState>, Option<(String, String)>) {
    match event {
        HookEvent::SessionStart => {
            if is_active_state(current_state) {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::UserPromptSubmit => (Action::Upsert, Some(SessionState::Working), None),

        HookEvent::PreToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Refresh, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PostToolUse { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Refresh, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PostToolUseFailure { .. } => {
            if current_state == Some(SessionState::Working) {
                (Action::Refresh, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Working), None)
            }
        }

        HookEvent::PermissionRequest => (Action::Upsert, Some(SessionState::Waiting), None),

        HookEvent::PreCompact => (Action::Upsert, Some(SessionState::Compacting), None),

        HookEvent::Notification { notification_type } => {
            if notification_type == "idle_prompt" || notification_type == "auth_success" {
                (Action::Upsert, Some(SessionState::Ready), None)
            } else if notification_type == "permission_prompt"
                || notification_type == "elicitation_dialog"
            {
                (Action::Upsert, Some(SessionState::Waiting), None)
            } else {
                (Action::Skip, None, None)
            }
        }

        HookEvent::Stop { stop_hook_active } => {
            if *stop_hook_active {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::TaskCompleted => {
            if input.agent_id.is_some() || input.teammate_name.is_some() {
                (Action::Skip, None, None)
            } else {
                (Action::Upsert, Some(SessionState::Ready), None)
            }
        }

        HookEvent::SessionEnd => (Action::Delete, None, None),

        // Informational events (SubagentStart, TeammateIdle, WorktreeCreate, etc.)
        // and unknown future events are recognized but don't affect session state.
        _ => (Action::Skip, None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::env_lock;
    use std::collections::BTreeMap;
    use std::fmt;
    use std::sync::{Arc, Mutex, OnceLock};
    use tracing::field::{Field, Visit};
    use tracing::Subscriber;
    use tracing_subscriber::{layer::Context, prelude::*, Layer};

    struct EnvGuard {
        key: &'static str,
        prior: Option<String>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, prior }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.prior {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    #[test]
    fn subagent_stop_skips_runtime_send() {
        let _guard = env_lock();
        let _enabled = EnvGuard::set("CAPACITOR_CORE_ENABLED", "1");
        let temp_dir = std::env::temp_dir().join(format!(
            "hud-hook-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir");
        let hook_input = HookInput {
            hook_event_name: Some("Stop".to_string()),
            session_id: Some("session-1".to_string()),
            cwd: Some("/repo".to_string()),
            notification_type: None,
            stop_hook_active: Some(false),
            tool_name: None,
            tool_input: None,
            tool_response: None,
            agent_id: Some("agent-123".to_string()),
            teammate_name: None,
        };

        let result = handle_hook_input_with_home(hook_input, &temp_dir);
        assert!(result.is_ok());
    }

    #[test]
    fn unknown_event_skips_runtime_send() {
        let _guard = env_lock();
        let _enabled = EnvGuard::set("CAPACITOR_CORE_ENABLED", "1");
        let temp_dir = std::env::temp_dir().join(format!(
            "hud-hook-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir");
        let hook_input = HookInput {
            hook_event_name: Some("SomeFutureHookEvent".to_string()),
            session_id: Some("session-1".to_string()),
            cwd: Some("/repo".to_string()),
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            tool_input: None,
            tool_response: None,
            agent_id: None,
            teammate_name: None,
        };

        let result = handle_hook_input_with_home(hook_input, &temp_dir);
        assert!(result.is_ok());
    }

    #[derive(Debug, Clone, Default)]
    struct CapturedEvent {
        fields: BTreeMap<String, String>,
    }

    impl CapturedEvent {
        fn field_matches(&self, key: &str, expected: &str) -> bool {
            self.fields
                .get(key)
                .map(|value| value.trim_matches('"') == expected)
                .unwrap_or(false)
        }
    }

    struct FieldCaptureLayer {
        events: Arc<Mutex<Vec<CapturedEvent>>>,
    }

    impl FieldCaptureLayer {
        fn new(events: Arc<Mutex<Vec<CapturedEvent>>>) -> Self {
            Self { events }
        }
    }

    impl<S> Layer<S> for FieldCaptureLayer
    where
        S: Subscriber,
    {
        fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
            let mut visitor = FieldVisitor::default();
            event.record(&mut visitor);
            self.events
                .lock()
                .expect("capture events lock")
                .push(CapturedEvent {
                    fields: visitor.fields,
                });
        }
    }

    #[derive(Default)]
    struct FieldVisitor {
        fields: BTreeMap<String, String>,
    }

    impl FieldVisitor {
        fn insert(&mut self, field: &Field, value: String) {
            self.fields.insert(field.name().to_string(), value);
        }
    }

    impl Visit for FieldVisitor {
        fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
            self.insert(field, format!("{value:?}"));
        }

        fn record_str(&mut self, field: &Field, value: &str) {
            self.insert(field, value.to_string());
        }

        fn record_bool(&mut self, field: &Field, value: bool) {
            self.insert(field, value.to_string());
        }

        fn record_i64(&mut self, field: &Field, value: i64) {
            self.insert(field, value.to_string());
        }

        fn record_u64(&mut self, field: &Field, value: u64) {
            self.insert(field, value.to_string());
        }
    }

    fn ensure_registered_runtime() {
        static TEST_RUNTIME: OnceLock<()> = OnceLock::new();

        TEST_RUNTIME.get_or_init(|| {
            let runtime = capacitor_core::CoreRuntime::new().expect("test runtime");
            crate::runtime_client::register_service_runtime(runtime)
                .expect("register test runtime");
        });
    }

    #[test]
    fn notification_runtime_log_includes_notification_type() {
        let _guard = env_lock();
        let _enabled = EnvGuard::set("CAPACITOR_CORE_ENABLED", "1");
        ensure_registered_runtime();

        let temp_dir = std::env::temp_dir().join(format!(
            "hud-hook-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir");

        let hook_input = HookInput {
            hook_event_name: Some("Notification".to_string()),
            session_id: Some("session-1".to_string()),
            cwd: Some("/repo".to_string()),
            notification_type: Some("permission_prompt".to_string()),
            stop_hook_active: None,
            tool_name: None,
            tool_input: None,
            tool_response: None,
            agent_id: None,
            teammate_name: None,
        };

        let events = Arc::new(Mutex::new(Vec::new()));
        let subscriber =
            tracing_subscriber::registry().with(FieldCaptureLayer::new(Arc::clone(&events)));

        let result = tracing::subscriber::with_default(subscriber, || {
            handle_hook_input_with_home(hook_input, &temp_dir)
        });
        assert!(result.is_ok());

        let captured = events.lock().expect("captured events lock");
        let runtime_event = captured
            .iter()
            .find(|event| event.field_matches("message", "Runtime accepted event"))
            .cloned()
            .expect("expected runtime acceptance log event");

        assert!(
            runtime_event.field_matches("notification_type", "permission_prompt"),
            "expected Runtime accepted event log to include notification_type=permission_prompt, got {captured:?}"
        );
    }
}
