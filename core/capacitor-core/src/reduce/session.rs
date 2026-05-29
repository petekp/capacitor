use std::collections::HashMap;

use crate::domain::{
    normalize_path_for_matching, now_rfc3339, resolve_project_identity, workspace_id,
    HookEventType, IngestHookEventCommand, SessionState, SessionSummary, ShellSignal,
    SignalAuthority, StateSource,
};

use super::utils::is_timestamp_stale;
use super::{
    SessionUpdate, AUTHORITY_NONTERMINAL_FRESHNESS_SECS, AUTHORITY_TERMINAL_FRESHNESS_SECS,
    IDLE_PROMPT_GRACE_SECS,
};

pub(super) fn reduce_session(
    current: Option<&SessionSummary>,
    shells: &HashMap<u32, ShellSignal>,
    event: &IngestHookEventCommand,
) -> SessionUpdate {
    // ADR-005 Phase 3 step 9: DefinitiveTerminal is sticky. Once a session
    // receives a `DefinitiveTerminal` event (SessionEnd), strictly lower
    // authority events cannot override the terminal state within the
    // terminal freshness window. `SessionStart` is the one exception — it
    // explicitly resurrects a terminated session (the /clear path). Other
    // authority tiers use the lighter state_source preservation inside
    // `upsert_session` instead, which allows state transitions (Working →
    // Stop → Ready) without regressing `state_source.authority`.
    if terminal_authority_blocks_event(current, event) {
        return SessionUpdate::Skip("lower_authority_within_freshness_window");
    }

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
                SessionUpdate::Upsert(upsert_session(current, shells, event, SessionState::Ready))
            }
        }
        HookEventType::UserPromptSubmit | HookEventType::PreToolUse => SessionUpdate::Upsert(
            upsert_session(current, shells, event, SessionState::Working),
        ),
        HookEventType::PostToolUse | HookEventType::PostToolUseFailure => SessionUpdate::Upsert(
            upsert_session(current, shells, event, SessionState::Working),
        ),
        HookEventType::PermissionRequest => {
            // Guard: if tools_in_flight == 0, the tool already completed and this
            // PermissionRequest arrived late. Skip it to avoid overwriting Working.
            if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                SessionUpdate::Skip("permission_request_no_tools_in_flight")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    shells,
                    event,
                    SessionState::Waiting,
                ))
            }
        }
        HookEventType::PreCompact => SessionUpdate::Upsert(upsert_session(
            current,
            shells,
            event,
            SessionState::Compacting,
        )),
        HookEventType::Notification => match event.notification_type.as_deref() {
            Some("idle_prompt") => {
                if current
                    .map(|record| record.tools_in_flight > 0)
                    .unwrap_or(false)
                {
                    let mut corrected = upsert_session(
                        current,
                        shells,
                        event,
                        current
                            .map(|record| record.state)
                            .unwrap_or(SessionState::Working),
                    );
                    corrected.tools_in_flight = 0;
                    SessionUpdate::Upsert(corrected)
                } else if is_recently_active(current, event) {
                    SessionUpdate::Skip("idle_prompt_recent_activity")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        shells,
                        event,
                        SessionState::Ready,
                    ))
                }
            }
            Some("auth_success") => {
                SessionUpdate::Upsert(upsert_session(current, shells, event, SessionState::Ready))
            }
            Some("permission_prompt") => {
                // Guard: if tools_in_flight == 0, the tool already completed and
                // this notification arrived late. Skip to avoid overwriting Working.
                if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                    SessionUpdate::Skip("permission_prompt_no_tools_in_flight")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        shells,
                        event,
                        SessionState::Waiting,
                    ))
                }
            }
            Some("elicitation_dialog") => {
                // Guard: if tools_in_flight == 0, the tool already completed and
                // this notification arrived late. Skip to avoid overwriting Working.
                if current.map(|r| r.tools_in_flight).unwrap_or(0) == 0 {
                    SessionUpdate::Skip("elicitation_dialog_no_tools_in_flight")
                } else {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        shells,
                        event,
                        SessionState::Waiting,
                    ))
                }
            }
            _ => SessionUpdate::Skip("notification_non_stateful"),
        },
        HookEventType::Stop => {
            if should_skip_stop(event) {
                SessionUpdate::Skip("stop_guard")
            } else {
                SessionUpdate::Upsert(upsert_session(current, shells, event, SessionState::Ready))
            }
        }
        HookEventType::TaskCompleted => {
            if has_auxiliary_task_metadata(event) {
                SessionUpdate::Skip("auxiliary_task_metadata")
            } else {
                SessionUpdate::Skip("task_completed_intent_preserved")
            }
        }
        HookEventType::SessionEnd => {
            if current.is_none() {
                SessionUpdate::Skip("session_end_no_session")
            } else {
                SessionUpdate::Upsert(upsert_session(current, shells, event, SessionState::Idle))
            }
        }
        HookEventType::SubagentStart => {
            if current_has_higher_priority_state(current) {
                SessionUpdate::Skip("subagent_start_higher_priority_active")
            } else {
                SessionUpdate::Upsert(upsert_session(
                    current,
                    shells,
                    event,
                    SessionState::Working,
                ))
            }
        }
        HookEventType::SubagentStop => {
            if current_has_higher_priority_state(current) {
                SessionUpdate::Skip("subagent_stop_higher_priority_active")
            } else if current
                .map(|record| record.state == SessionState::Working && record.tools_in_flight > 0)
                .unwrap_or(false)
            {
                // Other tools are still in flight — the session is genuinely active.
                SessionUpdate::Upsert(upsert_session(
                    current,
                    shells,
                    event,
                    SessionState::Working,
                ))
            } else if current
                .map(|record| record.state == SessionState::Working)
                .unwrap_or(false)
            {
                // Working with no tools in flight: if the session was recently
                // active, refresh the timestamp to prevent is_alive decay during
                // subagent-heavy workflows. If stale, preserve the skip to
                // maintain the staleness safety net for abandoned sessions.
                if is_recently_active(current, event) {
                    SessionUpdate::Upsert(upsert_session(
                        current,
                        shells,
                        event,
                        SessionState::Working,
                    ))
                } else {
                    SessionUpdate::Skip("subagent_stop_working_no_tools_stale")
                }
            } else {
                // Late background-agent completions must not upgrade or create a session.
                SessionUpdate::Skip("subagent_stop_session_not_working")
            }
        }
        HookEventType::TeammateIdle => SessionUpdate::Skip("teammate_idle_informational"),
        HookEventType::WorktreeCreate => {
            if let Some(record) = current {
                SessionUpdate::Upsert(upsert_session(current, shells, event, record.state))
            } else {
                SessionUpdate::Skip("worktree_create_no_session")
            }
        }
        HookEventType::WorktreeRemove => SessionUpdate::Skip("worktree_remove_informational"),
        HookEventType::ConfigChange => {
            if let Some(record) = current {
                SessionUpdate::Upsert(upsert_session(current, shells, event, record.state))
            } else {
                SessionUpdate::Skip("config_change_no_session")
            }
        }
        HookEventType::TranscriptActivity => {
            SessionUpdate::Skip("transcript_activity_not_a_hook_event")
        }
        HookEventType::Unknown => SessionUpdate::Skip("unknown_event_type"),
    }
}

fn is_recently_active(current: Option<&SessionSummary>, event: &IngestHookEventCommand) -> bool {
    let Some(session) = current else {
        return false;
    };
    let Some(event_time) = super::utils::parse_rfc3339(&event.recorded_at) else {
        return false;
    };
    let Some(session_time) = super::utils::parse_rfc3339(&session.updated_at) else {
        return false;
    };
    event_time.signed_duration_since(session_time).num_seconds() < IDLE_PROMPT_GRACE_SECS
}

fn upsert_session(
    current: Option<&SessionSummary>,
    shells: &HashMap<u32, ShellSignal>,
    event: &IngestHookEventCommand,
    new_state: SessionState,
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

    let terminated_at = match event.event_type {
        HookEventType::SessionEnd => Some(updated_at.clone()),
        HookEventType::SessionStart => None,
        _ => current.and_then(|record| record.terminated_at.clone()),
    };

    let authority = classify_signal(event.event_type);
    // ADR-005 Phase 3 step 9: within a higher-authority freshness window,
    // preserve the existing state_source rather than regressing it to a
    // strictly lower authority. The state itself may still transition
    // (Working → Stop → Ready, drift-correction adjustments, etc) — this
    // guard only enforces that the provenance record tracks the strongest
    // authority observed in the window, not the most recent event.
    let state_source = if should_preserve_state_source(current, event, authority) {
        current.and_then(|record| record.state_source.clone())
    } else {
        Some(StateSource {
            event_kind: event.event_type,
            authority,
            observed_at: updated_at.clone(),
        })
    };
    let last_authoritative_event_at = match authority {
        SignalAuthority::DefinitiveTerminal | SignalAuthority::DefinitiveTransient => {
            Some(updated_at.clone())
        }
        _ => current.and_then(|record| record.last_authoritative_event_at.clone()),
    };

    // Carry the OS process start time from the matching shell signal when
    // available; otherwise preserve whatever the current session already had.
    // Used purely as a PID-reuse discriminator for the OS-liveness sweep.
    let process_start_time = shells
        .get(&pid)
        .and_then(|shell| shell.proc_start)
        .or_else(|| current.and_then(|record| record.process_start_time));

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
        terminated_at,
        tools_in_flight,
        state_source,
        last_authoritative_event_at,
        is_alive: pid > 0 && shells.contains_key(&pid),
        gc_reason: None,
        process_start_time,
        // OS-liveness facts are recorded only by the dedicated sweep ingest path
        // (ingest_os_liveness); a hook-event upsert preserves the prior probe
        // result rather than fabricating one.
        os_process_alive: current.and_then(|record| record.os_process_alive),
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

    // When event.project_path is present, use it as the authoritative anchor.
    // file_path identity is only accepted if it resolves to the same project_id
    // (i.e. same git common_dir) AND the file's project_path is a descendant of
    // the anchor's project_path. This prevents both cross-repo leaks and
    // cross-package leaks within a monorepo (sibling packages share project_id
    // but are not descendants of each other).
    let has_project_path = !event.project_path.trim().is_empty();

    let identity = if has_project_path {
        let mut anchor = resolve_project_identity(&event.project_path);

        // Block lateral sibling drift: if the session already has a project_path
        // and the new event's anchor resolves to the same git repo (project_id)
        // but neither path is an ancestor of the other, keep the established path.
        // This prevents successive events with different CWDs (e.g., packages/api
        // then packages/web) from bouncing the session between monorepo siblings.
        if let Some(current_record) = current {
            if !current_record.project_path.trim().is_empty() {
                if let Some(ref anchor_id) = anchor {
                    if let Some(current_id) = resolve_project_identity(&current_record.project_path)
                    {
                        if anchor_id.project_id == current_id.project_id
                            && !path_is_parent_or_self(
                                &anchor_id.project_path,
                                &current_id.project_path,
                            )
                            && !path_is_parent_or_self(
                                &current_id.project_path,
                                &anchor_id.project_path,
                            )
                        {
                            anchor = Some(current_id);
                        }
                    }
                }
            }
        }

        if let Some(ref anchor_id) = anchor {
            // Only use file_path identity if it stays within the anchor's boundary:
            // same git repo AND the file's resolved project_path is the anchor or
            // a descendant of it (not a sibling package).
            let refined = identity_from_file.as_ref().and_then(|file_id| {
                if file_id.project_id == anchor_id.project_id
                    && path_is_parent_or_self(&anchor_id.project_path, &file_id.project_path)
                {
                    Some(file_id.clone())
                } else {
                    None
                }
            });
            refined.or(anchor)
        } else {
            // Anchor unresolvable (stale/deleted path). Fall back to file_path -> cwd.
            identity_from_file.or_else(|| {
                if cwd.trim().is_empty() {
                    None
                } else {
                    resolve_project_identity(cwd)
                }
            })
        }
    } else {
        // Fallback when event.project_path is empty: file_path -> cwd.
        identity_from_file.or_else(|| {
            if cwd.trim().is_empty() {
                None
            } else {
                resolve_project_identity(cwd)
            }
        })
    };

    let mut project_path = identity
        .as_ref()
        .map(|value| value.project_path.clone())
        .or_else(|| {
            current
                .map(|record| record.project_path.clone())
                .filter(|value| !value.trim().is_empty())
        })
        .or_else(|| {
            // When project_path is present, prefer it over cwd for the fallback.
            if has_project_path {
                Some(event.project_path.clone())
            } else if cwd.trim().is_empty() {
                None
            } else {
                Some(cwd.to_string())
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

fn current_has_higher_priority_state(current: Option<&SessionSummary>) -> bool {
    current
        .map(|record| {
            record.state == SessionState::Waiting || record.state == SessionState::Compacting
        })
        .unwrap_or(false)
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

pub(super) fn is_informational_skip_reason(reason: &str) -> bool {
    matches!(
        reason,
        "informational_event"
            | "teammate_idle_informational"
            | "worktree_create_informational"
            | "worktree_remove_informational"
            | "config_change_informational"
    )
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

pub(super) fn should_skip_stop(event: &IngestHookEventCommand) -> bool {
    if event.stop_hook_active == Some(true) {
        return true;
    }

    event
        .agent_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty())
}

pub(super) fn is_event_stale(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
) -> bool {
    let Some(current) = current else { return false };
    is_timestamp_stale(current.updated_at.as_str(), event.recorded_at.as_str())
}

pub(super) fn is_shell_signal_stale(
    current: Option<&ShellSignal>,
    incoming_recorded_at: &str,
) -> bool {
    let Some(current) = current else { return false };
    is_timestamp_stale(current.updated_at.as_str(), incoming_recorded_at)
}

/// Authority matrix. Single source of truth for `HookEventType` → `SignalAuthority`.
/// Ordered by tier (highest authority first), alphabetically within tier.
/// ADR-005 Phase 3 step 11 — do not hand-edit without updating the contract tests
/// in `reduce/tests.rs::authority_matrix_contract_tests`.
pub(super) const AUTHORITY_MATRIX: &[(HookEventType, SignalAuthority)] = &[
    // DefinitiveTerminal — the system ended
    (
        HookEventType::SessionEnd,
        SignalAuthority::DefinitiveTerminal,
    ),
    // DefinitiveTransient — hook reports concrete activity
    (
        HookEventType::PermissionRequest,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::PostToolUse,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::PostToolUseFailure,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::PreToolUse,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::SessionStart,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::SubagentStart,
        SignalAuthority::DefinitiveTransient,
    ),
    (
        HookEventType::UserPromptSubmit,
        SignalAuthority::DefinitiveTransient,
    ),
    // AmbiguousPerTurn — could mean idle or still working
    (HookEventType::Stop, SignalAuthority::AmbiguousPerTurn),
    (
        HookEventType::SubagentStop,
        SignalAuthority::AmbiguousPerTurn,
    ),
    (
        HookEventType::TaskCompleted,
        SignalAuthority::AmbiguousPerTurn,
    ),
    // MetaAwaitingInput — user prompt / permission UI
    (
        HookEventType::Notification,
        SignalAuthority::MetaAwaitingInput,
    ),
    // Inferential — contextual, not a direct hook event
    (HookEventType::ConfigChange, SignalAuthority::Inferential),
    (HookEventType::PreCompact, SignalAuthority::Inferential),
    (
        HookEventType::TranscriptActivity,
        SignalAuthority::Inferential,
    ),
    (HookEventType::TeammateIdle, SignalAuthority::Inferential),
    (HookEventType::Unknown, SignalAuthority::Inferential),
    (HookEventType::WorktreeCreate, SignalAuthority::Inferential),
    (HookEventType::WorktreeRemove, SignalAuthority::Inferential),
];

pub(super) fn classify_signal(event_type: HookEventType) -> SignalAuthority {
    AUTHORITY_MATRIX
        .iter()
        .find_map(|(kind, authority)| {
            if *kind == event_type {
                Some(*authority)
            } else {
                None
            }
        })
        .expect(
            "AUTHORITY_MATRIX missing HookEventType variant; see classify_signal_covers_all_event_types",
        )
}

/// Total ordering over `SignalAuthority` for override decisions. Higher
/// numeric rank means stronger authority; strict inequality gates override.
/// ADR-005 Phase 3 step 9.
fn authority_rank(authority: SignalAuthority) -> u8 {
    match authority {
        SignalAuthority::DefinitiveTerminal => 5,
        SignalAuthority::DefinitiveTransient => 4,
        SignalAuthority::AmbiguousPerTurn => 3,
        SignalAuthority::MetaAwaitingInput => 2,
        SignalAuthority::Inferential => 1,
    }
}

/// Freshness window (in seconds) during which the given authority tier
/// suppresses strictly lower-authority overrides of `state_source`.
/// `DefinitiveTerminal` is sticky (session termination is a long-lived
/// fact); non-terminal tiers use a short window so the state machine can
/// progress through natural hook transitions while retaining provenance.
fn authority_freshness_window_secs(authority: SignalAuthority) -> i64 {
    match authority {
        SignalAuthority::DefinitiveTerminal => AUTHORITY_TERMINAL_FRESHNESS_SECS,
        SignalAuthority::DefinitiveTransient
        | SignalAuthority::AmbiguousPerTurn
        | SignalAuthority::MetaAwaitingInput
        | SignalAuthority::Inferential => AUTHORITY_NONTERMINAL_FRESHNESS_SECS,
    }
}

/// Returns true iff the event was observed at or within the freshness window
/// anchored on `observed_at`. Used to decide whether an established
/// authority record still suppresses lower-authority signals. Returns false
/// when either timestamp fails to parse (permissive fallback).
fn within_freshness_window(observed_at: &str, event_recorded_at: &str, window_secs: i64) -> bool {
    let Some(event_time) = super::utils::parse_rfc3339(event_recorded_at) else {
        return false;
    };
    let Some(observed_time) = super::utils::parse_rfc3339(observed_at) else {
        return false;
    };
    let delta_secs = event_time
        .signed_duration_since(observed_time)
        .num_seconds();
    // Reordered or duplicate events (delta <= 0) are treated as still
    // within the window — they must not override newer higher-authority
    // state even when they land out of order.
    delta_secs <= 0 || delta_secs < window_secs
}

/// Top-level guard. `DefinitiveTerminal` is the one authority tier that
/// blocks state transitions (not just state_source) from lower-authority
/// events. Applies only when:
/// - Current state_source is DefinitiveTerminal and within its sticky window.
/// - Incoming event is strictly lower authority.
/// - Incoming event is NOT `SessionStart` (explicit resurrection — the
///   /clear path legitimately revives a terminated session).
fn terminal_authority_blocks_event(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
) -> bool {
    if event.event_type == HookEventType::SessionStart {
        return false;
    }
    let Some(session) = current else {
        return false;
    };
    let Some(source) = session.state_source.as_ref() else {
        return false;
    };
    if source.authority != SignalAuthority::DefinitiveTerminal {
        return false;
    }

    let incoming_authority = classify_signal(event.event_type);
    if authority_rank(incoming_authority) >= authority_rank(source.authority) {
        return false;
    }

    within_freshness_window(
        &source.observed_at,
        &event.recorded_at,
        AUTHORITY_TERMINAL_FRESHNESS_SECS,
    )
}

/// `upsert_session` guard. When an incoming event carries strictly lower
/// authority than the current state_source and arrives within the current
/// authority's freshness window, preserve the existing state_source rather
/// than regressing it. The session's state, `tools_in_flight`, and
/// `updated_at` still transition as the per-event branch requests — only
/// the provenance record is pinned.
fn should_preserve_state_source(
    current: Option<&SessionSummary>,
    event: &IngestHookEventCommand,
    incoming_authority: SignalAuthority,
) -> bool {
    let Some(session) = current else {
        return false;
    };
    let Some(source) = session.state_source.as_ref() else {
        return false;
    };
    if authority_rank(incoming_authority) >= authority_rank(source.authority) {
        return false;
    }
    if event.event_type == HookEventType::SessionStart
        && source.authority == SignalAuthority::DefinitiveTerminal
    {
        return false;
    }
    let window_secs = authority_freshness_window_secs(source.authority);
    within_freshness_window(&source.observed_at, &event.recorded_at, window_secs)
}
