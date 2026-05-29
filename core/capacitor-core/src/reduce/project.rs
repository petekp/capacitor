//! Project reducer.
//!
//! Owns the `MutateProjectCommand` (Add/Remove/Rename) transitions against the
//! project/delegation/session maps. Mirrors the `delegation` reducer so that
//! `CoreRuntime::mutate_project` is a thin `commit(|s| s.apply_project_mutation(..))`
//! shell with no inline state mutation in the FFI facade.

use std::collections::{BTreeMap, HashMap};

use crate::domain::{
    default_workspace_id, display_name, normalize_path_for_matching, now_rfc3339,
    resolve_project_identity, MutateProjectCommand, MutationOutcome, ProjectDelegationState,
    ProjectMutationKind, ProjectSummary, SessionState, SessionSummary,
};

/// Apply a project mutation, dispatching to the appropriate variant handler.
///
/// Lifted verbatim from the former inline reducer in `core_ingest.rs`; this is
/// a pure structural single-owner restoration with no logic change. Unlike the
/// delegation/run reducers, project mutations do NOT bump `events_ingested`.
pub(crate) fn apply_project_mutation(
    projects: &mut BTreeMap<String, ProjectSummary>,
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    sessions: &mut HashMap<String, SessionSummary>,
    command: MutateProjectCommand,
) -> MutationOutcome {
    match command.kind {
        ProjectMutationKind::Add => {
            let normalized_path = normalize_path_for_matching(&command.project_path);
            if normalized_path.is_empty() {
                MutationOutcome {
                    ok: false,
                    message: "project_path cannot be empty".to_string(),
                }
            } else {
                let project_id = resolve_project_identity(&normalized_path)
                    .map(|identity| identity.project_id)
                    .unwrap_or_else(|| normalized_path.clone());
                let workspace_id = default_workspace_id(&normalized_path);
                let display_name = command
                    .display_name
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| display_name(&normalized_path));

                projects.insert(
                    normalized_path.clone(),
                    ProjectSummary {
                        project_path: normalized_path,
                        project_id,
                        workspace_id,
                        display_name,
                        state: SessionState::Idle,
                        state_changed_at: now_rfc3339(),
                        updated_at: now_rfc3339(),
                        representative_session_id: None,
                        latest_session_id: None,
                        session_count: 0,
                        active_count: 0,
                        has_session: false,
                    },
                );

                MutationOutcome {
                    ok: true,
                    message: "project added".to_string(),
                }
            }
        }
        ProjectMutationKind::Remove => {
            let normalized_path = normalize_path_for_matching(&command.project_path);
            projects.remove(&normalized_path);
            delegations.remove(&normalized_path);
            sessions.retain(|_, session| session.project_path != normalized_path);
            MutationOutcome {
                ok: true,
                message: "project removed".to_string(),
            }
        }
        ProjectMutationKind::Rename => {
            let normalized_path = normalize_path_for_matching(&command.project_path);
            if let Some(project) = projects.get_mut(&normalized_path) {
                if let Some(name) = command.display_name {
                    if !name.trim().is_empty() {
                        project.display_name = name;
                    }
                }
                project.updated_at = now_rfc3339();
                MutationOutcome {
                    ok: true,
                    message: "project renamed".to_string(),
                }
            } else {
                MutationOutcome {
                    ok: false,
                    message: "project not found".to_string(),
                }
            }
        }
    }
}
