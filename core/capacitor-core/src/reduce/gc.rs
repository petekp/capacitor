use std::cmp::Ordering;
use std::collections::HashMap;

use chrono::{DateTime, Utc};

use crate::domain::{normalize_path_for_matching, SessionState, SessionSummary, ShellSignal};

use super::utils::{compare_timestamp_strings, parse_rfc3339};
use super::{
    ReducerState, GC_REASON_ORPHANED_STALE, GC_REASON_SOLE_DEAD_NO_SHELL, HOOK_ACTIVITY_ALIVE_SECS,
    ORPHANED_SESSION_GRACE, SHELL_GC_RETENTION, SOLE_DEAD_SESSION_GRACE,
};

pub(super) fn gc_stale_sessions_at(state: &mut ReducerState, now: DateTime<Utc>) -> bool {
    let shell_count_before_gc = state.shells.len();
    cleanup_shells_at(&mut state.shells, now);

    let session_is_alive = session_is_alive_map(&state.sessions, &state.shells, now);
    for session in state.sessions.values_mut() {
        session.is_alive = session_is_alive
            .get(&session.session_id)
            .copied()
            .unwrap_or(false);
    }

    // Group sessions by normalized project path. For each project we only
    // evict stale non-Idle sessions when at least one session will survive the
    // GC pass. A survivor is either Idle (always survives) or fresh enough to
    // be within ORPHANED_SESSION_GRACE. This prevents the pathological case
    // where all concurrent workers are quiet and the GC wipes the entire
    // project to zero sessions.
    let mut project_sessions: HashMap<String, Vec<String>> = HashMap::new();
    for session in state.sessions.values() {
        if session.project_path.is_empty() {
            continue;
        }
        let key = normalize_path_for_matching(&session.project_path);
        project_sessions
            .entry(key)
            .or_default()
            .push(session.session_id.clone());
    }

    let mut expired_session_ids: Vec<String> = Vec::new();
    let mut idle_session_ids: Vec<String> = Vec::new();

    for session_ids in project_sessions.values() {
        if session_ids.len() <= 1 {
            // Sole session — only transition to Idle if conclusively dead
            // with no corroborating shell signal and well beyond the dead
            // session grace period.
            if let Some(session_id) = session_ids.first() {
                if let Some(session) = state.sessions.get(session_id) {
                    if is_sole_session_conclusively_dead(session, now, &state.shells) {
                        idle_session_ids.push(session_id.clone());
                    }
                }
            }
            continue;
        }

        let stale: Vec<String> = session_ids
            .iter()
            .filter_map(|session_id| {
                state
                    .sessions
                    .get(session_id)
                    .filter(|session| is_session_evictable(session, now, &state.shells))
                    .map(|_| session_id.clone())
            })
            .collect();

        // A survivor is any session that is NOT evictable: either Idle
        // or fresh enough to be within the grace window.
        let has_survivor = session_ids.iter().any(|session_id| {
            state
                .sessions
                .get(session_id)
                .map(|session| !is_session_evictable(session, now, &state.shells))
                .unwrap_or(false)
        });

        if has_survivor {
            expired_session_ids.extend(stale);
        }
        // If no survivor exists, skip eviction for this project entirely.
    }

    let mut needs_recompute = shell_count_before_gc != state.shells.len();

    for session_id in idle_session_ids {
        if let Some(session) = state.sessions.get_mut(&session_id) {
            session.state = SessionState::Idle;
            session.state_changed_at = now.to_rfc3339();
            session.is_alive = false;
            session.gc_reason = Some(GC_REASON_SOLE_DEAD_NO_SHELL.to_string());
            needs_recompute = true;
        }
    }

    if !expired_session_ids.is_empty() {
        for id in &expired_session_ids {
            tracing::info!(
                session_id = %id,
                reason = GC_REASON_ORPHANED_STALE,
                "GC: removing expired session"
            );
            state.sessions.remove(id);
        }
        needs_recompute = true;
    }

    if needs_recompute {
        state.recompute_projects();
        state.recompute_routing();
    }

    needs_recompute
}

pub(super) fn cleanup_orphaned_same_project_sessions(
    sessions: &mut HashMap<String, SessionSummary>,
    shells: &HashMap<u32, ShellSignal>,
    project_path: &str,
    current_session_id: &str,
    incoming_recorded_at: &str,
    gc_reference_time: Option<DateTime<Utc>>,
) {
    let project_path = normalize_path_for_matching(project_path);
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
        .filter(|session| normalize_path_for_matching(&session.project_path) == project_path)
        .filter(|session| is_session_evictable(session, reference_time, shells))
        .map(|session| session.session_id.clone())
        .collect();

    for session_id in expired_session_ids {
        sessions.remove(&session_id);
    }
}

fn is_sole_session_conclusively_dead(
    session: &SessionSummary,
    now: DateTime<Utc>,
    shells: &HashMap<u32, ShellSignal>,
) -> bool {
    // Only active states (Working/Waiting/Compacting) can be dead — Idle and
    // Ready are resting states that represent terminal windows the user may
    // return to.
    if !session.state.is_active() {
        return false;
    }
    // Shell corroboration means the process is (or was recently) alive.
    if session.pid > 0 && shells.contains_key(&session.pid) {
        return false;
    }
    // No corroboration + active state + well beyond the generous grace period = dead.
    let anchor = orphaned_session_gc_anchor_at(session);
    parse_rfc3339(anchor)
        .map(|ts| now.signed_duration_since(ts) > SOLE_DEAD_SESSION_GRACE)
        .unwrap_or(false)
}

fn is_session_evictable(
    session: &SessionSummary,
    reference_time: DateTime<Utc>,
    shells: &HashMap<u32, ShellSignal>,
) -> bool {
    // Idle sessions are never evictable — they represent terminal windows
    // the user may return to.
    if session.state == SessionState::Idle {
        return false;
    }
    let anchor = orphaned_session_gc_anchor_at(session);
    let age_expired = parse_rfc3339(anchor)
        .map(|ts| reference_time.signed_duration_since(ts) > ORPHANED_SESSION_GRACE)
        .unwrap_or(false);
    if !age_expired {
        return false;
    }
    // Active sessions with a corroborating shell signal are protected.
    // The shell signal proves the process is (or was recently) alive.
    // Stale shell signals are cleaned by cleanup_shells during GC,
    // so this protection expires naturally within one GC cycle after PID death.
    if session.state.is_active() && session.pid > 0 && shells.contains_key(&session.pid) {
        return false;
    }
    true
}

fn orphaned_session_gc_anchor_at(session: &SessionSummary) -> &str {
    if session.state == SessionState::Ready {
        let Some(last_activity_at) = session
            .last_activity_at
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        else {
            return session.state_changed_at.as_str();
        };

        if compare_timestamp_strings(last_activity_at, session.state_changed_at.as_str())
            == Ordering::Less
        {
            session.state_changed_at.as_str()
        } else {
            last_activity_at
        }
    } else {
        session.updated_at.as_str()
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
                .map(|ts| now.signed_duration_since(ts) > SHELL_GC_RETENTION)
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
    shells: &HashMap<u32, ShellSignal>,
    now: DateTime<Utc>,
) -> HashMap<String, bool> {
    sessions
        .values()
        .map(|session| {
            let has_recent_hook_activity =
                parse_rfc3339(&session.updated_at).is_some_and(|updated| {
                    now.signed_duration_since(updated).num_seconds() < HOOK_ACTIVITY_ALIVE_SECS
                });

            let has_shell_match = {
                let normalized_project = normalize_path_for_matching(&session.project_path);
                !normalized_project.is_empty()
                    && shells.values().any(|shell| {
                        shell.cwd == normalized_project
                            || shell
                                .cwd
                                .strip_prefix(normalized_project.as_str())
                                .is_some_and(|rest| rest.starts_with('/'))
                            || normalized_project
                                .strip_prefix(shell.cwd.as_str())
                                .is_some_and(|rest| rest.starts_with('/'))
                    })
            };

            (
                session.session_id.clone(),
                has_shell_match || has_recent_hook_activity,
            )
        })
        .collect()
}
