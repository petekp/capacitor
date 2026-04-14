use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::domain::{SessionState, SessionSummary, ShellSignal};

use super::utils::parse_rfc3339;
use super::{
    ReducerState, GC_REASON_SIGNAL_ABSENCE, HOOK_ACTIVITY_ALIVE_SECS, IDLE_RETENTION,
    SHELL_RETENTION, SIGNAL_ABSENCE_GRACE,
};

pub(super) fn gc_stale_sessions_at(state: &mut ReducerState, now: DateTime<Utc>) -> bool {
    let shell_count_before = state.shells.len();
    cleanup_shells_at(&mut state.shells, now);

    let alive_map = session_is_alive_map(&state.sessions, &state.shells, now);
    for session in state.sessions.values_mut() {
        session.is_alive = alive_map.get(&session.session_id).copied().unwrap_or(false);
    }

    let to_idle: Vec<String> = state
        .sessions
        .values()
        .filter(|s| s.state != SessionState::Idle)
        .filter(|s| !s.is_alive)
        .filter(|s| {
            parse_rfc3339(&s.updated_at)
                .map(|ts| now.signed_duration_since(ts) > SIGNAL_ABSENCE_GRACE)
                .unwrap_or(false)
        })
        .map(|s| s.session_id.clone())
        .collect();

    let mut changed = shell_count_before != state.shells.len();

    for sid in &to_idle {
        if let Some(session) = state.sessions.get_mut(sid) {
            session.state = SessionState::Idle;
            session.state_changed_at = now.to_rfc3339();
            session.is_alive = false;
            session.gc_reason = Some(GC_REASON_SIGNAL_ABSENCE.to_string());
            changed = true;
        }
    }

    let to_remove: Vec<String> = state
        .sessions
        .values()
        .filter(|s| s.state == SessionState::Idle)
        .filter(|s| {
            parse_rfc3339(&s.state_changed_at)
                .map(|ts| now.signed_duration_since(ts) > IDLE_RETENTION)
                .unwrap_or(false)
        })
        .map(|s| s.session_id.clone())
        .collect();

    for sid in &to_remove {
        state.sessions.remove(sid);
        changed = true;
    }

    if changed {
        state.recompute_projects();
        state.recompute_routing();
    }
    changed
}

pub(super) fn cleanup_orphaned_same_project_sessions(
    sessions: &mut HashMap<String, SessionSummary>,
    _shells: &HashMap<u32, ShellSignal>,
    project_path: &str,
    current_session_id: &str,
    incoming_recorded_at: &str,
    gc_reference_time: Option<DateTime<Utc>>,
) {
    let project_path = crate::domain::normalize_path_for_matching(project_path);
    if project_path.is_empty() {
        return;
    }

    let Some(reference_time) = gc_reference_time.or_else(|| parse_rfc3339(incoming_recorded_at))
    else {
        return;
    };

    let expired_session_ids: Vec<String> = sessions
        .values()
        .filter(|session| session.session_id != current_session_id)
        .filter(|session| {
            crate::domain::normalize_path_for_matching(&session.project_path) == project_path
        })
        .filter(|session| {
            // Terminated sessions are never evictable — they represent terminal
            // windows the user may return to.
            if session.terminated_at.is_some() {
                return false;
            }
            parse_rfc3339(&session.updated_at)
                .map(|ts| reference_time.signed_duration_since(ts) > SIGNAL_ABSENCE_GRACE)
                .unwrap_or(false)
        })
        .map(|session| session.session_id.clone())
        .collect();

    for session_id in expired_session_ids {
        sessions.remove(&session_id);
    }
}

pub(super) fn cleanup_shells(shells: &mut HashMap<u32, ShellSignal>) {
    cleanup_shells_at(shells, Utc::now());
}

pub(super) fn cleanup_shells_at(shells: &mut HashMap<u32, ShellSignal>, now: DateTime<Utc>) {
    let expired_pids: Vec<u32> = shells
        .iter()
        .filter(|(_, shell)| {
            parse_rfc3339(&shell.updated_at)
                .map(|ts| now.signed_duration_since(ts) > SHELL_RETENTION)
                .unwrap_or(false)
        })
        .map(|(pid, _)| *pid)
        .collect();
    for pid in expired_pids {
        shells.remove(&pid);
    }
}

pub(super) fn session_is_alive_map(
    sessions: &HashMap<String, SessionSummary>,
    _shells: &HashMap<u32, ShellSignal>,
    now: DateTime<Utc>,
) -> HashMap<String, bool> {
    sessions
        .values()
        .map(|session| {
            // Idle sessions are definitively not alive.
            if session.state == SessionState::Idle {
                return (session.session_id.clone(), false);
            }
            if session.terminated_at.is_some() {
                return (session.session_id.clone(), false);
            }
            // Observational: recent activity proves alive.
            let alive = session
                .last_activity_at
                .as_deref()
                .and_then(parse_rfc3339)
                .is_some_and(|ts| {
                    now.signed_duration_since(ts).num_seconds() < HOOK_ACTIVITY_ALIVE_SECS
                });
            (session.session_id.clone(), alive)
        })
        .collect()
}
