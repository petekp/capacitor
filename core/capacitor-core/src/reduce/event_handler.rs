use chrono::{DateTime, Utc};

use crate::domain::{
    normalize_path_for_matching, now_rfc3339, IngestHookEventCommand, IngestShellSignalCommand,
    MutationOutcome, ShellSignal,
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
        updated_at,
    };

    state.shells.insert(shell.pid, shell);
    state.recompute_routing();

    MutationOutcome {
        ok: true,
        message: "shell signal ingested".to_string(),
    }
}
