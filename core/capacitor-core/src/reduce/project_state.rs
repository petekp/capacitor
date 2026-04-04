use std::collections::{BTreeMap, HashMap};

use crate::domain::{
    display_name, normalize_path_for_matching, workspace_id, ProjectSummary, SessionState,
    SessionSummary,
};

use super::utils::compare_timestamp_strings;
use super::ReducerState;

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

pub(super) fn recompute_projects(state: &mut ReducerState) {
    let mut next = BTreeMap::new();

    for existing in state.projects.values() {
        let normalized_key = normalize_path_for_matching(&existing.project_path);
        next.insert(
            normalized_key.clone(),
            ProjectSummary {
                project_path: normalized_key,
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
    for session in state.sessions.values() {
        if session.project_path.is_empty() {
            continue;
        }
        by_project
            .entry(normalize_path_for_matching(&session.project_path))
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

    state.projects = next;
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
