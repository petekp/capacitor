use chrono::{DateTime, Utc};

use std::collections::HashMap;

use crate::domain::{
    normalize_path_for_matching, now_rfc3339, IngestHookEventCommand, IngestOsLivenessCommand,
    IngestShellSignalCommand, MutationOutcome, ShellSignal, ShellUnregisterCommand,
};

use super::gc::cleanup_orphaned_same_project_sessions;
use super::session::{
    is_event_stale, is_informational_skip_reason, is_shell_signal_stale, reduce_session,
};
use super::{ReducerState, SessionUpdate};

pub(super) fn apply_hook_event_with_gc_reference_time(
    state: &mut ReducerState,
    command: IngestHookEventCommand,
    gc_reference_time: Option<DateTime<Utc>>,
) -> MutationOutcome {
    state.events_ingested = state.events_ingested.saturating_add(1);

    if command.event_id.is_empty() {
        state.last_error = Some("ingest_hook_event missing event_id".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing event_id".to_string(),
        };
    }

    if command.session_id.is_empty() {
        state.last_error = Some("ingest_hook_event missing session_id".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing session_id".to_string(),
        };
    }

    state.last_hook_event_at = Some(if command.recorded_at.is_empty() {
        now_rfc3339()
    } else {
        command.recorded_at.clone()
    });

    let current = state.sessions.get(&command.session_id).cloned();
    if is_event_stale(current.as_ref(), &command) {
        state.stale_events_skipped += 1;
        return MutationOutcome {
            ok: true,
            message: "stale event skipped".to_string(),
        };
    }

    let recorded_at = if command.recorded_at.is_empty() {
        now_rfc3339()
    } else {
        command.recorded_at.clone()
    };

    let update = reduce_session(current.as_ref(), &state.shells, &command);
    match &update {
        SessionUpdate::Upsert(session) => {
            state
                .sessions
                .insert(session.session_id.clone(), session.clone());
        }
        SessionUpdate::Delete(session_id) => {
            state.sessions.remove(session_id);
        }
        SessionUpdate::Skip(reason) => {
            if is_informational_skip_reason(reason) {
                state.informational_events_skipped += 1;
            } else {
                state.reducer_events_skipped += 1;
            }
        }
    }

    if matches!(&update, SessionUpdate::Upsert(_)) {
        if let Some(session) = state.sessions.get(&command.session_id).cloned() {
            cleanup_orphaned_same_project_sessions(
                &mut state.sessions,
                &state.shells,
                &session.project_path,
                &session.session_id,
                recorded_at.as_str(),
                gc_reference_time,
            );
        }
    }

    state.recompute_projects();
    state.recompute_routing();

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

pub(super) fn apply_shell_signal(
    state: &mut ReducerState,
    command: IngestShellSignalCommand,
) -> MutationOutcome {
    state.events_ingested = state.events_ingested.saturating_add(1);

    if command.cwd.is_empty() || command.tty.is_empty() {
        state.last_error = Some("ingest_shell_signal missing cwd or tty".to_string());
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

    let current = state.shells.get(&command.pid);
    if is_shell_signal_stale(current, updated_at.as_str()) {
        state.stale_events_skipped += 1;
        return MutationOutcome {
            ok: true,
            message: "stale shell signal skipped".to_string(),
        };
    }

    let shell = ShellSignal {
        pid: command.pid,
        cwd: normalize_path_for_matching(&command.cwd),
        tty: command.tty,
        parent_app: command.parent_app,
        tmux_session: command.tmux_session,
        tmux_client_tty: command.tmux_client_tty,
        tmux_pane: command.tmux_pane,
        tmux_panes: command.tmux_panes,
        proc_start: command.proc_start,
        updated_at,
    };

    state.shells.insert(shell.pid, shell);
    state.recompute_routing();

    MutationOutcome {
        ok: true,
        message: "shell signal ingested".to_string(),
    }
}

pub(super) fn apply_shell_unregister(
    state: &mut ReducerState,
    command: ShellUnregisterCommand,
) -> MutationOutcome {
    state.events_ingested = state.events_ingested.saturating_add(1);

    if state.shells.remove(&command.pid).is_some() {
        state.recompute_routing();
        MutationOutcome {
            ok: true,
            message: format!("shell {} unregistered", command.pid),
        }
    } else {
        MutationOutcome {
            ok: true,
            message: format!("shell {} not found (already removed)", command.pid),
        }
    }
}

/// PURE OS-liveness reducer. Records the per-PID OS facts gathered by the
/// hud-hook sweep onto matching sessions. This function performs NO operating
/// system calls (no `sysinfo`, no process probing) — it only consumes the facts
/// the caller already gathered, which keeps the reducer replay-deterministic.
///
/// For each tracked session:
/// - Find the sweep entry whose `pid` matches the session `pid`.
/// - PID-reuse defense: if BOTH the session's `process_start_time` and the
///   entry's `process_start_time` are known and they DIFFER, the live process
///   is a different process that reused the PID — resolve `alive = false`.
/// - `os_process_alive` is set to the OR-aggregation of the resolved (and
///   possibly reuse-corrected) `alive` flags across every tracked record
///   sharing the same session id: a session id is alive if any of its records
///   resolved alive.
///
/// This deliberately does NOT touch `is_alive` (event-decay liveness) — the two
/// liveness notions are distinct facts.
pub(super) fn apply_os_liveness(
    state: &mut ReducerState,
    command: IngestOsLivenessCommand,
) -> MutationOutcome {
    state.events_ingested = state.events_ingested.saturating_add(1);

    // Index the sweep facts by pid for O(1) lookup.
    let mut by_pid: HashMap<u32, &crate::domain::OsLivenessEntry> = HashMap::new();
    for entry in &command.entries {
        by_pid.insert(entry.pid, entry);
    }

    let mut changed = false;

    // First pass: resolve per-session alive (with PID-reuse gating) and
    // OR-aggregate by session id. A session id can in principle map to more
    // than one tracked record across resurrections, so a session id is alive
    // if any record under it resolved alive.
    let mut alive_by_session: HashMap<String, bool> = HashMap::new();
    for session in state.sessions.values() {
        let resolved_alive = resolve_os_alive(session, by_pid.get(&session.pid).copied());
        let slot = alive_by_session
            .entry(session.session_id.clone())
            .or_insert(false);
        *slot = *slot || resolved_alive;
    }

    for session in state.sessions.values_mut() {
        let resolved_alive = alive_by_session
            .get(&session.session_id)
            .copied()
            .unwrap_or(false);

        let new_alive = Some(resolved_alive);
        if session.os_process_alive != new_alive {
            changed = true;
        }
        session.os_process_alive = new_alive;
    }

    if changed {
        // Liveness facts feed projection/derived state; recompute so projects
        // reflect the latest fact set. Routing is shell-derived and unaffected.
        state.recompute_projects();
    }

    MutationOutcome {
        ok: true,
        message: "os liveness recorded".to_string(),
    }
}

/// Resolve a single session's OS-alive fact from its matching sweep entry,
/// applying PID-reuse gating. Returns false when there is no matching entry.
fn resolve_os_alive(
    session: &crate::domain::SessionSummary,
    entry: Option<&crate::domain::OsLivenessEntry>,
) -> bool {
    let Some(entry) = entry else {
        return false;
    };
    if !entry.alive {
        return false;
    }
    // PID-reuse defense: when both start times are known and differ, the live
    // process at this pid is NOT the session's original process.
    if let (Some(session_start), Some(observed_start)) =
        (session.process_start_time, entry.process_start_time)
    {
        if session_start != observed_start {
            return false;
        }
    }
    true
}
