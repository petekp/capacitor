use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::domain::{
    normalize_path_for_matching, now_rfc3339, DelegationMutationKind, DelegationReviewState,
    DelegationStatus, MutateDelegationCommand, MutationOutcome, ProjectDelegationState,
};

use super::utils::trimmed_value;

/// Apply a delegation mutation, dispatching to the appropriate variant handler.
pub(crate) fn apply_delegation_mutation(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
) -> MutationOutcome {
    let project_path = normalize_path_for_matching(command.project_path.as_str());
    if project_path.is_empty() {
        *last_error = Some("mutate_delegation missing project_path".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing project_path".to_string(),
        };
    }

    let Some(worker_id) = trimmed_value(Some(command.worker_id.as_str())) else {
        *last_error = Some("mutate_delegation missing worker_id".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing worker_id".to_string(),
        };
    };

    let updated_at = now_rfc3339();

    match command.kind {
        DelegationMutationKind::Start => handle_start(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::AttachSession => handle_attach_session(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::ReviewReady => handle_review_ready(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::SubmitReview => handle_submit_review(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::Resume => handle_resume(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::ResumeFailed => handle_resume_failed(
            delegations,
            last_error,
            command,
            project_path,
            worker_id,
            updated_at,
        ),
        DelegationMutationKind::Complete => {
            handle_complete(delegations, last_error, project_path, worker_id)
        }
    }
}

fn handle_start(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    if delegations.contains_key(project_path.as_str()) {
        *last_error = Some(format!(
            "mutate_delegation duplicate active delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation already active for project".to_string(),
        };
    }

    let Some(worktree_name) = trimmed_value(command.worktree_name.as_deref()) else {
        *last_error = Some("mutate_delegation missing worktree_name".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing worktree_name".to_string(),
        };
    };
    let Some(worktree_path) = trimmed_value(command.worktree_path.as_deref()) else {
        *last_error = Some("mutate_delegation missing worktree_path".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing worktree_path".to_string(),
        };
    };

    delegations.insert(
        project_path.clone(),
        ProjectDelegationState {
            project_path,
            worker_id,
            idea_id: trimmed_value(command.idea_id.as_deref()),
            worktree_name,
            worktree_path,
            session_id: trimmed_value(command.session_id.as_deref()),
            status: DelegationStatus::Working,
            started_at: updated_at.clone(),
            updated_at,
            submitted_milestone_id: None,
            current_review: None,
        },
    );

    MutationOutcome {
        ok: true,
        message: "delegation started".to_string(),
    }
}

fn handle_attach_session(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get_mut(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation attach_session missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation attach_session worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    let Some(session_id) = trimmed_value(command.session_id.as_deref()) else {
        *last_error = Some("mutate_delegation missing session_id".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing session_id".to_string(),
        };
    };

    existing.session_id = Some(session_id);
    existing.updated_at = updated_at;

    MutationOutcome {
        ok: true,
        message: "delegation session attached".to_string(),
    }
}

fn handle_review_ready(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get_mut(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation review_ready missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation review_ready worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    let Some(milestone_id) = trimmed_value(command.milestone_id.as_deref()) else {
        *last_error = Some("mutate_delegation missing milestone_id".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing milestone_id".to_string(),
        };
    };
    let Some(brief_path) = trimmed_value(command.brief_path.as_deref()) else {
        *last_error = Some("mutate_delegation missing brief_path".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing brief_path".to_string(),
        };
    };
    let Some(manifest_path) = trimmed_value(command.manifest_path.as_deref()) else {
        *last_error = Some("mutate_delegation missing manifest_path".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing manifest_path".to_string(),
        };
    };

    if is_review_suppressed_during_resume_pending(existing, milestone_id.as_str()) {
        *last_error = Some(format!(
            "mutate_delegation review_ready suppressed during resume_pending project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "review suppressed during resume_pending".to_string(),
        };
    }

    if let Some(session_id) = trimmed_value(command.session_id.as_deref()) {
        existing.session_id = Some(session_id);
    }
    existing.status = DelegationStatus::ReviewNeeded;
    existing.updated_at = updated_at.clone();
    existing.current_review = Some(DelegationReviewState {
        milestone_id,
        brief_path,
        manifest_path,
        requested_at: updated_at,
    });

    MutationOutcome {
        ok: true,
        message: "delegation review ready".to_string(),
    }
}

fn handle_submit_review(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get_mut(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation submit_review missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation submit_review worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    // SubmitReview is valid from ReviewNeeded (normal) or ResumeFailed (retry)
    if existing.status != DelegationStatus::ReviewNeeded
        && existing.status != DelegationStatus::ResumeFailed
    {
        *last_error = Some(format!(
            "mutate_delegation submit_review invalid status={:?} project_path={project_path}",
            existing.status
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation status must be review_needed or resume_failed".to_string(),
        };
    }

    let Some(current_review) = existing.current_review.as_ref() else {
        *last_error = Some(format!(
            "mutate_delegation submit_review without pending review project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation review is not pending".to_string(),
        };
    };

    if command.review_decision.is_none() {
        *last_error = Some("mutate_delegation missing review_decision".to_string());
        return MutationOutcome {
            ok: false,
            message: "missing review_decision".to_string(),
        };
    }

    if let Some(session_id) = trimmed_value(command.session_id.as_deref()) {
        existing.session_id = Some(session_id);
    }
    existing.status = DelegationStatus::ResumePending;
    existing.updated_at = updated_at;
    existing.submitted_milestone_id = Some(current_review.milestone_id.clone());

    MutationOutcome {
        ok: true,
        message: "delegation review submitted".to_string(),
    }
}

fn handle_resume(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get_mut(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation resume missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation resume worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    if existing.status != DelegationStatus::ResumePending {
        *last_error = Some(format!(
            "mutate_delegation resume without resume_pending project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation resume is not pending".to_string(),
        };
    }

    if existing.current_review.is_none() {
        *last_error = Some(format!(
            "mutate_delegation resume missing review context project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation review context missing".to_string(),
        };
    }

    if let Some(session_id) = trimmed_value(command.session_id.as_deref()) {
        existing.session_id = Some(session_id);
    }
    existing.status = DelegationStatus::Working;
    existing.updated_at = updated_at;
    existing.current_review = None;

    MutationOutcome {
        ok: true,
        message: "delegation resumed".to_string(),
    }
}

fn handle_resume_failed(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    command: MutateDelegationCommand,
    project_path: String,
    worker_id: String,
    updated_at: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get_mut(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation resume_failed missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation resume_failed worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    if existing.status != DelegationStatus::ResumePending {
        *last_error = Some(format!(
            "mutate_delegation resume_failed without resume_pending project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation resume is not pending".to_string(),
        };
    }

    if existing.current_review.is_none() {
        *last_error = Some(format!(
            "mutate_delegation resume_failed missing review context project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation review context missing".to_string(),
        };
    }

    if let Some(session_id) = trimmed_value(command.session_id.as_deref()) {
        existing.session_id = Some(session_id);
    }
    existing.status = DelegationStatus::ResumeFailed;
    existing.updated_at = updated_at;

    MutationOutcome {
        ok: true,
        message: "delegation resume failed".to_string(),
    }
}

fn handle_complete(
    delegations: &mut BTreeMap<String, ProjectDelegationState>,
    last_error: &mut Option<String>,
    project_path: String,
    worker_id: String,
) -> MutationOutcome {
    let Some(existing) = delegations.get(project_path.as_str()) else {
        *last_error = Some(format!(
            "mutate_delegation complete missing delegation project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "delegation not found".to_string(),
        };
    };

    if existing.worker_id != worker_id {
        *last_error = Some(format!(
            "mutate_delegation complete worker mismatch project_path={project_path}"
        ));
        return MutationOutcome {
            ok: false,
            message: "worker_id does not match active delegation".to_string(),
        };
    }

    delegations.remove(project_path.as_str());

    MutationOutcome {
        ok: true,
        message: "delegation completed".to_string(),
    }
}

fn is_review_suppressed_during_resume_pending(
    existing: &ProjectDelegationState,
    milestone_id: &str,
) -> bool {
    existing.status == DelegationStatus::ResumePending
        && existing
            .submitted_milestone_id
            .as_deref()
            .is_some_and(|submitted| {
                compare_milestone_ids(milestone_id, submitted) != Ordering::Greater
            })
}

fn compare_milestone_ids(left: &str, right: &str) -> Ordering {
    match (left.parse::<u64>(), right.parse::<u64>()) {
        (Ok(left), Ok(right)) => left.cmp(&right),
        _ => left.cmp(right),
    }
}
