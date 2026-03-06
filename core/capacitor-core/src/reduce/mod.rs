use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Utc};

use crate::domain::{
    display_name, normalize_path_for_matching, now_rfc3339, resolve_project_identity, workspace_id,
    AppSnapshot, DiagnosticsSummary, HookEventType, IngestHookEventCommand,
    IngestShellSignalCommand, MutationOutcome, ProjectSummary, SessionState, SessionSummary,
    ShellSignal,
};

const STALE_EVENT_GRACE_SECS: i64 = 5;

#[derive(Debug, Default, Clone)]
pub struct ReducerState {
    pub projects: BTreeMap<String, ProjectSummary>,
    pub sessions: HashMap<String, SessionSummary>,
    pub shells: HashMap<u32, ShellSignal>,
    pub routing: BTreeMap<String, crate::domain::RoutingView>,
    pub events_ingested: u64,
    pub stale_events_skipped: u64,
    pub informational_events_skipped: u64,
    pub reducer_events_skipped: u64,
    pub last_error: Option<String>,
}

#[allow(clippy::large_enum_variant)]
enum SessionUpdate {
    Upsert(SessionSummary),
    Delete(String),
    Skip(&'static str),
}

impl ReducerState {
    #[must_use]
    pub fn from_snapshot(snapshot: AppSnapshot) -> Self {
        let mut projects = BTreeMap::new();
        for project in snapshot.projects {
            projects.insert(project.project_path.clone(), project);
        }

        let mut sessions = HashMap::new();
        for session in snapshot.sessions {
            sessions.insert(session.session_id.clone(), session);
        }

        let mut shells = HashMap::new();
        for shell in snapshot.shells {
            shells.insert(shell.pid, shell);
        }

        let mut routing = BTreeMap::new();
        for view in snapshot.routing {
            routing.insert(view.workspace_id.clone(), view);
        }

        Self {
            projects,
            sessions,
            shells,
            routing,
            events_ingested: snapshot.diagnostics.events_ingested,
            stale_events_skipped: snapshot.diagnostics.stale_events_skipped,
            informational_events_skipped: snapshot.diagnostics.informational_events_skipped,
            reducer_events_skipped: snapshot.diagnostics.reducer_events_skipped,
            last_error: snapshot.diagnostics.last_error,
        }
    }

    #[must_use]
    pub fn apply_hook_event(&mut self, command: IngestHookEventCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);

        if command.event_id.is_empty() {
            self.last_error = Some("ingest_hook_event missing event_id".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing event_id".to_string(),
            };
        }

        if command.session_id.is_empty() {
            self.last_error = Some("ingest_hook_event missing session_id".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing session_id".to_string(),
            };
        }

        let current = self.sessions.get(&command.session_id).cloned();
        if is_event_stale(current.as_ref(), &command) {
            self.stale_events_skipped += 1;
            return MutationOutcome {
                ok: true,
                message: "stale event skipped".to_string(),
            };
        }

        let update = reduce_session(current.as_ref(), &command);
        match &update {
            SessionUpdate::Upsert(session) => {
                self.sessions
                    .insert(session.session_id.clone(), session.clone());
            }
            SessionUpdate::Delete(session_id) => {
                self.sessions.remove(session_id);
            }
            SessionUpdate::Skip(reason) => match *reason {
                "informational_event" => self.informational_events_skipped += 1,
                _ => self.reducer_events_skipped += 1,
            },
        }

        self.recompute_projects();

        match update {
            SessionUpdate::Upsert(_) => MutationOutcome {
                ok: true,
                message: "event ingested".to_string(),
            },
            SessionUpdate::Delete(_) => MutationOutcome {
                ok: true,
                message: "session ended".to_string(),
            },
            SessionUpdate::Skip(reason) => MutationOutcome {
                ok: true,
                message: format!("event skipped: {reason}"),
            },
        }
    }

    #[must_use]
    pub fn apply_shell_signal(&mut self, command: IngestShellSignalCommand) -> MutationOutcome {
        self.events_ingested = self.events_ingested.saturating_add(1);

        if command.cwd.is_empty() || command.tty.is_empty() {
            self.last_error = Some("ingest_shell_signal missing cwd or tty".to_string());
            return MutationOutcome {
                ok: false,
                message: "missing cwd or tty".to_string(),
            };
        }

        let updated_at = if command.recorded_at.is_empty() {
            now_rfc3339()
        } else {
            command.recorded_at
        };

        let shell = ShellSignal {
            pid: command.pid,
            cwd: normalize_path_for_matching(&command.cwd),
            tty: command.tty,
            parent_app: command.parent_app,
            tmux_session: command.tmux_session,
            tmux_client_tty: command.tmux_client_tty,
            updated_at,
        };
        self.shells.insert(shell.pid, shell);

        MutationOutcome {
            ok: true,
            message: "shell signal ingested".to_string(),
        }
    }

    #[must_use]
    pub fn snapshot(&self) -> AppSnapshot {
        let projects = self.projects.values().cloned().collect::<Vec<_>>();

        let mut sessions = self.sessions.values().cloned().collect::<Vec<_>>();
        sessions.sort_by(|left, right| {
            left.project_path
                .cmp(&right.project_path)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });

        let mut shells = self.shells.values().cloned().collect::<Vec<_>>();
        shells.sort_by(|left, right| left.pid.cmp(&right.pid));

        let routing = self.routing.values().cloned().collect::<Vec<_>>();

        AppSnapshot {
            projects,
            sessions,
            shells,
            routing,
            diagnostics: DiagnosticsSummary {
                events_ingested: self.events_ingested,
                sessions_tracked: self.sessions.len() as u64,
                shell_signals_tracked: self.shells.len() as u64,
                events_skipped: self.stale_events_skipped
                    + self.informational_events_skipped
                    + self.reducer_events_skipped,
                stale_events_skipped: self.stale_events_skipped,
                informational_events_skipped: self.informational_events_skipped,
                reducer_events_skipped: self.reducer_events_skipped,
                last_error: self.last_error.clone(),
            },
            generated_at: now_rfc3339(),
        }
    }

    fn recompute_projects(&mut self) {
        let mut next = BTreeMap::new();

        for existing in self.projects.values() {
            next.insert(
                existing.project_path.clone(),
                ProjectSummary {
                    project_path: existing.project_path.clone(),
                    project_id: existing.project_id.clone(),
                    workspace_id: existing.workspace_id.clone(),
                    display_name: existing.display_name.clone(),
                    state: SessionState::Idle,
                    state_changed_at: existing.state_changed_at.clone(),
                    updated_at: existing.updated_at.clone(),
                    representative_session_id: None,
                    latest_session_id: None,
                    session_count: 0,
                    active_count: 0,
                    has_session: false,
                },
            );
        }

        let mut by_project: HashMap<String, Vec<&SessionSummary>> = HashMap::new();
        for session in self.sessions.values() {
            if session.project_path.is_empty() {
                continue;
            }
            by_project
                .entry(session.project_path.clone())
                .or_default()
                .push(session);
        }

        for (project_path, sessions) in by_project {
            let Some(reduced) = reduce_project_sessions(&project_path, &sessions) else {
                continue;
            };

            let entry = next
                .entry(project_path.clone())
                .or_insert_with(|| ProjectSummary {
                    project_path: project_path.clone(),
                    project_id: reduced.project_id.clone(),
                    workspace_id: reduced.workspace_id.clone(),
                    display_name: display_name(&project_path),
                    state: SessionState::Idle,
                    state_changed_at: reduced.state_changed_at.clone(),
                    updated_at: reduced.updated_at.clone(),
                    representative_session_id: None,
                    latest_session_id: None,
                    session_count: 0,
                    active_count: 0,
                    has_session: false,
                });

            entry.project_id = reduced.project_id;
            entry.workspace_id = reduced.workspace_id;
            entry.display_name = if entry.display_name.trim().is_empty() {
                display_name(&project_path)
            } else {
                entry.display_name.clone()
            };
            entry.state = reduced.state;
            entry.state_changed_at = reduced.state_changed_at;
            entry.updated_at = reduced.updated_at;
            entry.representative_session_id = reduced.representative_session_id;
            entry.latest_session_id = reduced.latest_session_id;
            entry.session_count = reduced.session_count;
            entry.active_count = reduced.active_count;
            entry.has_session = reduced.session_count > 0;
        }

        self.projects = next;
    }
}

#[derive(Debug, Clone)]
struct ReducedProjectState {
    project_id: String,
    workspace_id: String,
    state: SessionState,
    representative_session_id: Option<String>,
    latest_session_id: Option<String>,
    state_changed_at: String,
    updated_at: String,
    session_count: u64,
    active_count: u64,
}

fn reduce_project_sessions(
    project_path: &str,
    sessions: &[&SessionSummary],
) -> Option<ReducedProjectState> {
    let representative = sessions.iter().max_by(|left, right| {
        left.state
            .priority()
            .cmp(&right.state.priority())
            .then_with(|| compare_timestamp_strings(&left.updated_at, &right.updated_at))
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let latest = sessions.iter().max_by(|left, right| {
        compare_timestamp_strings(&left.updated_at, &right.updated_at)
            .then_with(|| left.session_id.cmp(&right.session_id))
    })?;

    let project_id = if !representative.project_id.is_empty() {
        representative.project_id.clone()
    } else if !latest.project_id.is_empty() {
        latest.project_id.clone()
    } else {
        project_path.to_string()
    };

    let workspace = if !representative.workspace_id.is_empty() {
        representative.workspace_id.clone()
    } else if !latest.workspace_id.is_empty() {
        latest.workspace_id.clone()
    } else {
        workspace_id(&project_id, project_path)
    };

    let active_count = sessions
        .iter()
        .filter(|session| session.state.is_active())
        .count() as u64;

    Some(ReducedProjectState {
        project_id,
        workspace_id: workspace,
        state: representative.state,
        representative_session_id: Some(representative.session_id.clone()),
        latest_session_id: Some(latest.session_id.clone()),
        state_changed_at: representative.state_changed_at.clone(),
        updated_at: latest.updated_at.clone(),
        session_count: sessions.len() as u64,
        active_count,
    })
}

fn reduce_session(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
) -> SessionUpdate {
    match event.event_type {
        HookEventType::SessionStart => {
            let already_working = current
                .map(|record| {
                    record.state == SessionState::Working || record.state == SessionState::Waiting
                })
                .unwrap_or(false);
            if already_working {
                SessionUpdate::Skip("session_start_already_active")
            } else {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Ready, None))
            }
        }
        HookEventType::UserPromptSubmit | HookEventType::PreToolUse => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
        }
        HookEventType::PostToolUse | HookEventType::PostToolUseFailure => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Working, None))
        }
        HookEventType::PermissionRequest => {
            SessionUpdate::Upsert(upsert_session(current, event, SessionState::Waiting, None))
        }
        HookEventType::PreCompact => SessionUpdate::Upsert(upsert_session(
            current,
            event,
            SessionState::Compacting,
            None,
        )),
        HookEventType::Notification => match event.notification_type.as_deref() {
            Some("idle_prompt") => {
                if current
                    .map(|record| record.tools_in_flight > 0)
                    .unwrap_or(false)
                {
                    SessionUpdate::Skip("idle_prompt_tools_in_flight")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        event,
                        SessionState::Ready,
                        Some("idle_prompt".to_string()),
                    ))
                }
            }
            Some("auth_success") => SessionUpdate::Upsert(upsert_session(
                current,
                event,
                SessionState::Ready,
                Some("auth_success".to_string()),
            )),
            Some("permission_prompt") => SessionUpdate::Upsert(upsert_session(
                current,
                event,
                SessionState::Waiting,
                Some("permission_prompt".to_string()),
            )),
            Some("elicitation_dialog") => {
                SessionUpdate::Upsert(upsert_session(current, event, SessionState::Waiting, None))
            }
            _ => SessionUpdate::Skip("notification_non_stateful"),
        },
        HookEventType::Stop => {
            if should_skip_stop(event) {
                SessionUpdate::Skip("stop_guard")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("stop_gate".to_string()),
                ))
            }
        }
        HookEventType::TaskCompleted => {
            if has_auxiliary_task_metadata(event) {
                SessionUpdate::Skip("auxiliary_task_metadata")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("task_completed".to_string()),
                ))
            }
        }
        HookEventType::SessionEnd => {
            let pid = event
                .pid
                .or_else(|| current.map(|record| record.pid))
                .unwrap_or(0);
            if pid > 0 && is_pid_alive(pid) {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    event,
                    SessionState::Ready,
                    Some("session_cleared".to_string()),
                ))
            } else {
                SessionUpdate::Delete(event.session_id.clone())
            }
        }
        HookEventType::SubagentStart
        | HookEventType::SubagentStop
        | HookEventType::TeammateIdle
        | HookEventType::WorktreeCreate
        | HookEventType::WorktreeRemove
        | HookEventType::ConfigChange
        | HookEventType::Unknown => SessionUpdate::Skip("informational_event"),
    }
}

fn upsert_session(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
    new_state: SessionState,
    ready_reason: Option<String>,
) -> SessionSummary {
    let pid = event
        .pid
        .or_else(|| current.map(|record| record.pid))
        .unwrap_or(0);

    let cwd = event
        .cwd
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(normalize_path_for_matching)
        .or_else(|| {
            current
                .map(|record| normalize_path_for_matching(&record.cwd))
                .filter(|value| !value.is_empty())
        })
        .or_else(|| {
            if event.project_path.is_empty() {
                None
            } else {
                Some(normalize_path_for_matching(&event.project_path))
            }
        })
        .unwrap_or_default();

    let (project_path, project_id) = derive_project_identity(current, event, &cwd);

    let workspace = event
        .workspace_id
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| workspace_id(&project_id, &project_path));

    let updated_at = if event.recorded_at.is_empty() {
        now_rfc3339()
    } else {
        event.recorded_at.clone()
    };

    let state_changed_at = match current {
        Some(record) if record.state == new_state => record.state_changed_at.clone(),
        _ => updated_at.clone(),
    };

    let mut last_activity_at = current.and_then(|record| record.last_activity_at.clone());
    if should_update_activity(event.event_type) {
        last_activity_at = Some(updated_at.clone());
    }

    let tools_in_flight = adjust_tools_in_flight(
        current.map(|record| record.tools_in_flight).unwrap_or(0),
        event.event_type,
    );

    let next_ready_reason = if new_state == SessionState::Ready {
        ready_reason.or_else(|| current.and_then(|record| record.ready_reason.clone()))
    } else {
        None
    };

    SessionSummary {
        session_id: event.session_id.clone(),
        pid,
        cwd,
        project_id,
        project_path,
        workspace_id: workspace,
        state: new_state,
        state_changed_at,
        updated_at,
        last_event: Some(event.event_type.as_str().to_string()),
        last_activity_at,
        tools_in_flight,
        ready_reason: next_ready_reason,
    }
}

fn derive_project_identity(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
    cwd: &str,
) -> (String, String) {
    let identity_from_file = event
        .file_path
        .as_deref()
        .and_then(|file_path| resolve_file_path(cwd, file_path))
        .and_then(|resolved| resolve_project_identity(&resolved));

    let identity = identity_from_file
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                resolve_project_identity(cwd)
            }
        })
        .or_else(|| {
            if event.project_path.trim().is_empty() {
                None
            } else {
                resolve_project_identity(&event.project_path)
            }
        });

    let mut project_path = identity
        .as_ref()
        .map(|value| value.project_path.clone())
        .or_else(|| {
            current
                .map(|record| record.project_path.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                Some(cwd.to_string())
            }
        })
        .or_else(|| {
            if event.project_path.trim().is_empty() {
                None
            } else {
                Some(event.project_path.clone())
            }
        })
        .unwrap_or_default();

    let mut project_id = identity
        .as_ref()
        .map(|value| value.project_id.clone())
        .or_else(|| {
            current
                .map(|record| record.project_id.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .unwrap_or_else(|| project_path.clone());

    if event.file_path.is_none() {
        if let Some(current_record) = current {
            if !current_record.project_path.is_empty()
                && path_is_parent_or_self(&project_path, &current_record.project_path)
            {
                project_path = current_record.project_path.clone();
                if !current_record.project_id.trim().is_empty() {
                    project_id = current_record.project_id.clone();
                }
            }
        }
    }

    (
        normalize_path_for_matching(&project_path),
        normalize_path_for_matching(&project_id),
    )
}

fn resolve_file_path(cwd: &str, file_path: &str) -> Option<String> {
    let trimmed = file_path.trim();
    if trimmed.is_empty() {
        return None;
    }

    let path = std::path::Path::new(trimmed);
    if path.is_absolute() {
        return Some(path.to_string_lossy().to_string());
    }

    if cwd.trim().is_empty() {
        return None;
    }

    let combined = std::path::Path::new(cwd).join(path);
    Some(combined.to_string_lossy().to_string())
}

fn path_is_parent_or_self(parent: &str, child: &str) -> bool {
    let parent = normalize_path_for_matching(parent);
    let child = normalize_path_for_matching(child);

    if parent.is_empty() || child.is_empty() {
        return false;
    }

    parent == child || child.starts_with(&(parent + "/"))
}

fn should_update_activity(event_type: HookEventType) -> bool {
    matches!(
        event_type,
        HookEventType::UserPromptSubmit
            | HookEventType::PreToolUse
            | HookEventType::PostToolUse
            | HookEventType::PostToolUseFailure
            | HookEventType::PreCompact
    )
}

fn adjust_tools_in_flight(current: u32, event_type: HookEventType) -> u32 {
    match event_type {
        HookEventType::PreToolUse => current.saturating_add(1),
        HookEventType::PostToolUse | HookEventType::PostToolUseFailure => current.saturating_sub(1),
        HookEventType::SessionStart
        | HookEventType::SessionEnd
        | HookEventType::PreCompact
        | HookEventType::Stop
        | HookEventType::TaskCompleted => 0,
        _ => current,
    }
}

fn has_auxiliary_task_metadata(event: &IngestHookEventCommand) -> bool {
    event
        .agent_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty())
        || event
            .teammate_name
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
}

fn should_skip_stop(event: &IngestHookEventCommand) -> bool {
    if event.stop_hook_active == Some(true) {
        return true;
    }

    event
        .agent_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty())
}

/// Checks whether a process is still running via `kill(pid, 0)`.
///
/// Used to distinguish `/clear` (process stays alive) from a true session exit
/// (process is gone). When the PID is alive at `SessionEnd` time, we transition
/// to `Ready` instead of deleting the session — avoiding a transient idle flicker
/// while Claude Code reinitializes the cleared conversation.
fn is_pid_alive(pid: u32) -> bool {
    // SAFETY: kill(pid, 0) is a standard POSIX call that checks process existence
    // without sending any signal. Returns 0 if the process exists, -1 otherwise.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn is_event_stale(current: Option<&SessionSummary>, event: &IngestHookEventCommand) -> bool {
    let Some(current) = current else { return false };
    let Some(event_time) = parse_rfc3339(&event.recorded_at) else {
        return false;
    };
    let Some(current_time) = parse_rfc3339(&current.updated_at) else {
        return false;
    };

    current_time.signed_duration_since(event_time).num_seconds() > STALE_EVENT_GRACE_SECS
}

fn compare_timestamp_strings(left: &str, right: &str) -> Ordering {
    match (parse_rfc3339(left), parse_rfc3339(right)) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::ReducerState;
    use crate::domain::{
        default_workspace_id, HookEventType, IngestHookEventCommand, IngestShellSignalCommand,
        SessionState,
    };

    fn event_base(event_type: HookEventType) -> IngestHookEventCommand {
        IngestHookEventCommand {
            event_id: "evt-1".to_string(),
            recorded_at: "2026-01-31T00:00:00Z".to_string(),
            event_type,
            session_id: "session-1".to_string(),
            pid: Some(1234),
            project_path: "/repo".to_string(),
            cwd: Some("/repo".to_string()),
            file_path: None,
            workspace_id: None,
            notification_type: None,
            stop_hook_active: None,
            tool_name: None,
            agent_id: None,
            teammate_name: None,
        }
    }

    #[test]
    fn reducer_maps_hook_events_into_session_state() {
        let mut state = ReducerState::default();
        let outcome = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        assert!(outcome.ok);
        assert_eq!(
            state.sessions.get("session-1").map(|session| session.state),
            Some(SessionState::Working)
        );
    }

    #[test]
    fn reducer_ignores_stale_events() {
        let mut state = ReducerState::default();

        let mut current = event_base(HookEventType::UserPromptSubmit);
        current.recorded_at = "2026-01-31T00:00:10Z".to_string();
        let _ = state.apply_hook_event(current);

        let mut stale = event_base(HookEventType::PermissionRequest);
        stale.recorded_at = "2026-01-31T00:00:00Z".to_string();
        let outcome = state.apply_hook_event(stale);

        assert!(outcome.ok);
        assert_eq!(outcome.message, "stale event skipped");
        assert_eq!(
            state.sessions.get("session-1").map(|session| session.state),
            Some(SessionState::Working)
        );
    }

    #[test]
    fn reducer_tracks_tools_in_flight_and_idle_prompt_gate() {
        let mut state = ReducerState::default();

        let _ = state.apply_hook_event(event_base(HookEventType::PreToolUse));

        let mut notification = event_base(HookEventType::Notification);
        notification.notification_type = Some("idle_prompt".to_string());
        notification.recorded_at = "2026-01-31T00:00:01Z".to_string();

        let skipped = state.apply_hook_event(notification.clone());
        assert_eq!(
            skipped.message,
            "event skipped: idle_prompt_tools_in_flight"
        );
        assert_eq!(
            state.sessions.get("session-1").map(|session| session.state),
            Some(SessionState::Working)
        );

        let mut post_tool = event_base(HookEventType::PostToolUse);
        post_tool.recorded_at = "2026-01-31T00:00:02Z".to_string();
        let _ = state.apply_hook_event(post_tool);

        notification.recorded_at = "2026-01-31T00:00:03Z".to_string();
        let applied = state.apply_hook_event(notification);
        assert!(applied.ok);
        assert_eq!(
            state.sessions.get("session-1").map(|session| session.state),
            Some(SessionState::Ready)
        );
    }

    #[test]
    fn reducer_stop_guard_skips_for_subagent() {
        let mut state = ReducerState::default();
        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let mut stop = event_base(HookEventType::Stop);
        stop.agent_id = Some("agent-1".to_string());
        stop.stop_hook_active = Some(false);
        stop.recorded_at = "2026-01-31T00:00:05Z".to_string();

        let outcome = state.apply_hook_event(stop);
        assert_eq!(outcome.message, "event skipped: stop_guard");
        assert_eq!(
            state.sessions.get("session-1").map(|session| session.state),
            Some(SessionState::Working)
        );
    }

    #[test]
    fn session_end_with_live_pid_transitions_to_ready() {
        let mut state = ReducerState::default();
        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let mut end = event_base(HookEventType::SessionEnd);
        // Use the current process PID so is_pid_alive returns true
        end.pid = Some(std::process::id());
        end.recorded_at = "2026-01-31T00:00:05Z".to_string();

        let outcome = state.apply_hook_event(end);
        assert!(outcome.ok);
        assert_eq!(
            state.sessions.get("session-1").map(|s| s.state),
            Some(SessionState::Ready),
        );
        assert_eq!(
            state
                .sessions
                .get("session-1")
                .and_then(|s| s.ready_reason.as_deref()),
            Some("session_cleared"),
        );
    }

    #[test]
    fn session_end_with_dead_pid_deletes_session() {
        let mut state = ReducerState::default();
        let _ = state.apply_hook_event(event_base(HookEventType::UserPromptSubmit));

        let mut end = event_base(HookEventType::SessionEnd);
        // PID 1234 from event_base is not alive → should delete
        end.recorded_at = "2026-01-31T00:00:05Z".to_string();

        let outcome = state.apply_hook_event(end);
        assert!(outcome.ok);
        assert!(!state.sessions.contains_key("session-1"));
    }

    #[test]
    fn reducer_tracks_shell_signals() {
        let mut state = ReducerState::default();
        let outcome = state.apply_shell_signal(IngestShellSignalCommand {
            pid: 4242,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: Some("cap".to_string()),
            tmux_client_tty: Some("/dev/ttys099".to_string()),
            recorded_at: "2026-02-28T00:00:00Z".to_string(),
        });

        assert!(outcome.ok);
        assert!(state.shells.contains_key(&4242));
        assert_eq!(
            state
                .shells
                .get(&4242)
                .and_then(|shell| shell.tmux_client_tty.as_deref()),
            Some("/dev/ttys099")
        );
    }

    #[test]
    fn default_workspace_is_stable() {
        let a = default_workspace_id("/Users/Pete/Code/Repo");
        let b = default_workspace_id("/users/pete/code/repo");
        assert_eq!(a, b);
    }

    #[test]
    fn projects_are_reduced_by_priority_and_recency() {
        let mut state = ReducerState::default();

        let mut first = event_base(HookEventType::PermissionRequest);
        first.session_id = "session-1".to_string();
        first.recorded_at = "2026-01-31T00:00:01Z".to_string();
        let _ = state.apply_hook_event(first);

        let mut second = event_base(HookEventType::UserPromptSubmit);
        second.session_id = "session-2".to_string();
        second.recorded_at = "2026-01-31T00:00:02Z".to_string();
        let _ = state.apply_hook_event(second);

        let snapshot = state.snapshot();
        let project = snapshot
            .projects
            .iter()
            .find(|project| project.project_path == "/repo")
            .expect("project");

        assert_eq!(project.state, SessionState::Waiting);
        assert_eq!(project.session_count, 2);
        assert_eq!(project.active_count, 2);
        assert!(project.has_session);
    }

    #[test]
    fn diagnostics_tracks_skip_counters() {
        let mut state = ReducerState::default();

        // Establish a session so we can trigger skip paths
        let start = event_base(HookEventType::UserPromptSubmit);
        let _ = state.apply_hook_event(start);

        // 1) Stale event → stale_events_skipped
        let mut stale = event_base(HookEventType::PermissionRequest);
        stale.recorded_at = "2025-12-01T00:00:00Z".to_string();
        let outcome = state.apply_hook_event(stale);
        assert_eq!(outcome.message, "stale event skipped");

        // 2) Informational event → informational_events_skipped
        let mut config_change = event_base(HookEventType::ConfigChange);
        config_change.recorded_at = "2026-01-31T00:00:01Z".to_string();
        let outcome = state.apply_hook_event(config_change);
        assert!(outcome.message.contains("informational_event"));

        // 3) Another informational event to prove counting
        let mut worktree = event_base(HookEventType::WorktreeCreate);
        worktree.recorded_at = "2026-01-31T00:00:02Z".to_string();
        let outcome = state.apply_hook_event(worktree);
        assert!(outcome.message.contains("informational_event"));

        // 4) Idle prompt while tools in flight → idle_prompt_skipped
        let mut pre_tool = event_base(HookEventType::PreToolUse);
        pre_tool.recorded_at = "2026-01-31T00:00:03Z".to_string();
        let _ = state.apply_hook_event(pre_tool);

        let mut idle = event_base(HookEventType::Notification);
        idle.notification_type = Some("idle_prompt".to_string());
        idle.recorded_at = "2026-01-31T00:00:04Z".to_string();
        let outcome = state.apply_hook_event(idle);
        assert!(outcome.message.contains("idle_prompt_tools_in_flight"));

        // Verify skip counters in snapshot
        let diag = state.snapshot().diagnostics;
        assert!(
            diag.events_skipped > 0,
            "events_skipped should be non-zero, got {}",
            diag.events_skipped
        );
        assert!(
            diag.stale_events_skipped > 0,
            "stale_events_skipped should be non-zero"
        );
        assert!(
            diag.informational_events_skipped >= 2,
            "informational_events_skipped should be >= 2, got {}",
            diag.informational_events_skipped
        );
        assert_eq!(
            diag.events_skipped,
            diag.stale_events_skipped
                + diag.informational_events_skipped
                + diag.reducer_events_skipped,
            "events_skipped should equal sum of sub-counters"
        );
    }
}
