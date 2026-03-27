/// Outcome of evaluating a phase or step gate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GateOutcome {
    Approved,
    Rejected,
    Waiting,
    TimedOut,
    ValidationFailed { reason: String },
}

impl GateOutcome {
    pub fn as_str(&self) -> &str {
        match self {
            GateOutcome::Approved => "approved",
            GateOutcome::Rejected => "rejected",
            GateOutcome::Waiting => "waiting",
            GateOutcome::TimedOut => "timed_out",
            GateOutcome::ValidationFailed { .. } => "validation_failed",
        }
    }

    pub fn reason(&self) -> Option<&str> {
        match self {
            GateOutcome::ValidationFailed { reason } => Some(reason.as_str()),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct HumanGateArtifacts {
    manifest: CheckpointManifest,
    media_artifacts: Vec<MediaArtifact>,
    mermaid_sources: Vec<MermaidSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReviewArtifactKind {
    Text,
    Screenshot,
    Recording,
    Mermaid,
}

impl ReviewArtifactKind {
    fn manifest_type(self) -> &'static str {
        match self {
            ReviewArtifactKind::Text => "text",
            ReviewArtifactKind::Screenshot => "screenshot",
            ReviewArtifactKind::Recording => "recording",
            ReviewArtifactKind::Mermaid => "mermaid",
        }
    }

    fn media_artifact_type(self) -> Option<MediaArtifactType> {
        match self {
            ReviewArtifactKind::Screenshot => Some(MediaArtifactType::Screenshot),
            ReviewArtifactKind::Recording => Some(MediaArtifactType::Recording),
            ReviewArtifactKind::Text | ReviewArtifactKind::Mermaid => None,
        }
    }
}

fn human_gate_prompt_message(gate: &NormalizedGate) -> String {
    if gate.gate_type == "approval" {
        format!("Gate '{}': Do you approve this phase?", gate.id)
    } else {
        format!("Gate '{}': Have manual tests been completed?", gate.id)
    }
}

fn human_gate_checkpoint_kind(gate_type: &str) -> CheckpointKind {
    match gate_type {
        "approval" => CheckpointKind::AlignmentReview,
        "manual_test_complete" => CheckpointKind::ImplementationMilestone,
        other => CheckpointKind::Custom {
            label: other.to_string(),
        },
    }
}

fn latest_completed_attempt(
    step_state: &crate::method_runner::state::StepState,
) -> Option<(u32, &crate::method_runner::state::AttemptState)> {
    step_state
        .attempts
        .iter()
        .rev()
        .find(|(_, attempt)| {
            attempt.status == crate::method_runner::state::AttemptStatus::Completed
                || attempt.status == crate::method_runner::state::AttemptStatus::OutputBound
        })
        .map(|(attempt_num, attempt)| (*attempt_num, attempt))
}

fn output_attempt_number(step_state: &crate::method_runner::state::StepState) -> Option<u32> {
    if step_state.current_attempt > 0
        && step_state
            .attempts
            .contains_key(&step_state.current_attempt)
    {
        Some(step_state.current_attempt)
    } else {
        latest_completed_attempt(step_state).map(|(attempt_num, _)| attempt_num)
    }
}

fn review_artifact_kind(output_type: &str, artifact_path: &Path) -> ReviewArtifactKind {
    let normalized_type = output_type.trim().to_ascii_lowercase();
    match normalized_type.as_str() {
        "screenshot" => ReviewArtifactKind::Screenshot,
        "recording" => ReviewArtifactKind::Recording,
        "mermaid" | "mermaid_diagram" => ReviewArtifactKind::Mermaid,
        _ => match artifact_path.extension().and_then(|ext| ext.to_str()) {
            Some("png" | "jpg" | "jpeg" | "webp") => ReviewArtifactKind::Screenshot,
            Some("mov" | "mp4" | "gif" | "webm") => ReviewArtifactKind::Recording,
            Some("mmd") => ReviewArtifactKind::Mermaid,
            _ => ReviewArtifactKind::Text,
        },
    }
}

fn apply_human_gate_decision_hints(
    manifest: CheckpointManifest,
    gate_type: &str,
) -> CheckpointManifest {
    match gate_type {
        "manual_test_complete" => manifest
            .decision_hint_approve(
                "Tests complete",
                "Manual verification is complete and the phase can continue.",
            )
            .decision_hint_request_changes(
                "Needs fixes",
                "Manual verification found issues that need another pass.",
            ),
        _ => manifest
            .decision_hint_approve(
                "Approve phase",
                "This phase is aligned and ready to continue.",
            )
            .decision_hint_request_changes(
                "Request changes",
                "This phase needs changes before continuing.",
            ),
    }
}

fn build_human_gate_artifacts(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
) -> HumanGateArtifacts {
    let mut manifest = CheckpointManifest::new(&gate.id);
    if !phase.description.trim().is_empty() {
        manifest = manifest.summary(&phase.description);
    }
    manifest = apply_human_gate_decision_hints(manifest, &gate.gate_type);
    let mut media_artifacts = Vec::new();
    let mut mermaid_sources = Vec::new();
    let Some(phase_state) = state.phases.get(&phase.id) else {
        return HumanGateArtifacts {
            manifest,
            media_artifacts,
            mermaid_sources,
        };
    };

    for step in &phase.steps {
        let Some(step_state) = phase_state.steps.get(&step.id) else {
            continue;
        };
        if step.action == ActionKind::Dispatch {
            if let Some((attempt_num, attempt_state)) = latest_completed_attempt(step_state) {
                for worker_id in attempt_state.workers.keys() {
                    let handoff_path =
                        paths.canonical_handoff(&phase.id, &step.id, attempt_num, worker_id);
                    if handoff_path.exists() {
                        let label = if attempt_state.workers.len() > 1 {
                            format!("{} handoff ({worker_id})", step.title)
                        } else {
                            format!("{} handoff", step.title)
                        };
                        manifest = manifest.artifact(
                            &label,
                            handoff_path.to_string_lossy().as_ref(),
                            ReviewArtifactKind::Text.manifest_type(),
                        );
                    }
                }
            }
        }

        let Some(attempt_num) = output_attempt_number(step_state) else {
            continue;
        };
        for (output_name, relative_path) in &step_state.outputs {
            let Some(output_def) = step.outputs.get(output_name) else {
                continue;
            };
            let output_path = paths
                .attempt_dir(&phase.id, &step.id, attempt_num)
                .join(relative_path);
            let label = format!("{}: {}", step.title, output_name);
            let artifact_kind = review_artifact_kind(&output_def.output_type, &output_path);
            manifest = manifest.artifact(
                &label,
                output_path.to_string_lossy().as_ref(),
                artifact_kind.manifest_type(),
            );

            if let Some(media_type) = artifact_kind.media_artifact_type() {
                media_artifacts.push(MediaArtifact {
                    artifact_type: media_type,
                    path: output_path.to_string_lossy().into_owned(),
                    label: label.clone(),
                    width: None,
                    height: None,
                    duration_secs: None,
                });
            }

            if artifact_kind == ReviewArtifactKind::Mermaid {
                match std::fs::read_to_string(&output_path) {
                    Ok(source) => mermaid_sources.push(MermaidSource {
                        label: label.clone(),
                        source,
                    }),
                    Err(error) => eprintln!(
                        "warning: failed to read mermaid source for phase '{}' step '{}' output '{}' at {:?}: {}",
                        phase.id, step.id, output_name, output_path, error
                    ),
                }
            }
        }
    }

    HumanGateArtifacts {
        manifest,
        media_artifacts,
        mermaid_sources,
    }
}

fn build_human_gate_checkpoint_context(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
) -> Result<GateCheckpointContext, std::io::Error> {
    let prompt_message = human_gate_prompt_message(gate);
    let artifacts = build_human_gate_artifacts(gate, phase, state, paths);
    let manifest_path = paths.gate_manifest_path(&phase.id, &gate.id);
    artifacts.manifest.write_to_path(&manifest_path)?;

    Ok(GateCheckpointContext {
        gate_id: gate.id.clone(),
        gate_type: gate.gate_type.clone(),
        phase_id: phase.id.clone(),
        checkpoint_kind: human_gate_checkpoint_kind(&gate.gate_type),
        checkpoint_title: phase.title.clone(),
        checkpoint_summary: phase.description.clone(),
        manifest_path,
        media_artifacts: artifacts.media_artifacts,
        mermaid_sources: artifacts.mermaid_sources,
        prompt_message,
    })
}

/// Evaluate a phase gate after all steps in the phase have completed.
pub fn evaluate_gate(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
    interactive_io: &dyn InteractiveIO,
) -> GateOutcome {
    match gate.gate_type.as_str() {
        "approval" | "manual_test_complete" => {
            evaluate_human_gate(gate, phase, state, paths, interactive_io)
        }
        "outputs_present" => evaluate_outputs_present_gate(gate, phase, state),
        "handoff_verdict" => evaluate_handoff_verdict_gate(phase, state, paths),
        "completion_claim" => evaluate_completion_claim_gate(phase, state, paths),
        "pipeline_clean" => GateOutcome::Waiting,
        _ => GateOutcome::ValidationFailed {
            reason: format!("unknown gate type '{}'", gate.gate_type),
        },
    }
}

fn evaluate_human_gate(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
    interactive_io: &dyn InteractiveIO,
) -> GateOutcome {
    let prompt_msg = human_gate_prompt_message(gate);
    match build_human_gate_checkpoint_context(gate, phase, state, paths) {
        Ok(context) => interactive_io.emit_gate_checkpoint(&context),
        Err(error) => {
            eprintln!(
                "warning: failed to synthesize gate checkpoint for phase '{}' gate '{}': {}",
                phase.id, gate.id, error
            );
            interactive_io.emit_prompt(&InteractivePrompt {
                message: prompt_msg.clone(),
            });
        }
    }
    let response = interactive_io.capture_response();
    let normalized = response.body.trim().to_lowercase();
    match normalized.as_str() {
        "approved" => GateOutcome::Approved,
        _ => GateOutcome::Rejected,
    }
}

fn evaluate_outputs_present_gate(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
) -> GateOutcome {
    let phase_id = &phase.id;
    let Some(phase_state) = state.phases.get(phase_id) else {
        return GateOutcome::ValidationFailed {
            reason: format!("phase '{}' not found in state", phase_id),
        };
    };
    for output_name in &gate.outputs {
        let found = phase_state
            .steps
            .values()
            .any(|step_state| step_state.outputs.contains_key(output_name));
        if !found {
            return GateOutcome::ValidationFailed {
                reason: format!("output '{}' not found in phase '{}'", output_name, phase_id),
            };
        }
    }
    GateOutcome::Approved
}

fn evaluate_handoff_verdict_gate(
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
) -> GateOutcome {
    for step_def in &phase.steps {
        if step_def.action != ActionKind::Dispatch {
            continue;
        }
        if let Some(outcome) = check_step_handoff_field(phase, step_def, state, paths, |p, wid| {
            if p.verdict.as_deref() != Some("CLEAN") {
                Some(GateOutcome::ValidationFailed {
                    reason: format!(
                        "worker '{}' has verdict '{}'",
                        wid,
                        p.verdict.as_deref().unwrap_or("none")
                    ),
                })
            } else {
                None
            }
        }) {
            return outcome;
        }
    }
    GateOutcome::Approved
}

fn evaluate_completion_claim_gate(
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
) -> GateOutcome {
    for step_def in &phase.steps {
        if step_def.action != ActionKind::Dispatch {
            continue;
        }
        if let Some(outcome) = check_step_handoff_field(phase, step_def, state, paths, |p, wid| {
            if p.completion_claim.as_deref() != Some("COMPLETE") {
                Some(GateOutcome::ValidationFailed {
                    reason: format!(
                        "worker '{}' has completion claim '{}'",
                        wid,
                        p.completion_claim.as_deref().unwrap_or("none")
                    ),
                })
            } else {
                None
            }
        }) {
            return outcome;
        }
    }
    GateOutcome::Approved
}

fn check_step_handoff_field<F>(
    phase: &NormalizedPhase,
    step_def: &NormalizedStep,
    state: &MethodRunState,
    paths: &MethodRunPaths,
    check_fn: F,
) -> Option<GateOutcome>
where
    F: Fn(&crate::method_runner::handoff::ParsedHandoff, &str) -> Option<GateOutcome>,
{
    let phase_state = state.phases.get(&phase.id)?;
    let step_state = phase_state.steps.get(&step_def.id);
    let step_state = match step_state {
        Some(step_state) => step_state,
        None => {
            return Some(GateOutcome::ValidationFailed {
                reason: format!("step '{}' not found in state", step_def.id),
            });
        }
    };
    let completed_attempt = step_state.attempts.iter().rev().find(|(_, attempt)| {
        attempt.status == crate::method_runner::state::AttemptStatus::Completed
            || attempt.status == crate::method_runner::state::AttemptStatus::OutputBound
    });
    let Some((attempt_num, attempt_state)) = completed_attempt else {
        return Some(GateOutcome::ValidationFailed {
            reason: format!("no completed attempt for step '{}'", step_def.id),
        });
    };

    for worker_id in attempt_state.workers.keys() {
        let handoff_path =
            paths.canonical_handoff(&phase.id, &step_def.id, *attempt_num, worker_id);
        if !handoff_path.exists() {
            return Some(GateOutcome::ValidationFailed {
                reason: format!("no handoff found for worker '{}'", worker_id),
            });
        }
        let content = match std::fs::read_to_string(&handoff_path) {
            Ok(content) => content,
            Err(_) => {
                return Some(GateOutcome::ValidationFailed {
                    reason: format!("cannot read handoff for worker '{}'", worker_id),
                });
            }
        };
        let parsed = match crate::method_runner::handoff::parse_handoff(&content, worker_id) {
            Ok(parsed) => parsed,
            Err(_) => {
                return Some(GateOutcome::ValidationFailed {
                    reason: format!("cannot parse handoff for worker '{}'", worker_id),
                });
            }
        };
        if let Some(outcome) = check_fn(&parsed, worker_id) {
            return Some(outcome);
        }
    }
    None
}

fn gate_outcome_reason(outcome: &GateOutcome) -> String {
    match outcome {
        GateOutcome::Rejected => "gate rejected".to_string(),
        GateOutcome::ValidationFailed { reason } => format!("validation failed: {}", reason),
        GateOutcome::TimedOut => "gate timed out".to_string(),
        GateOutcome::Waiting => {
            "pipeline_clean requires pipeline-execute, not implemented in v1".to_string()
        }
        GateOutcome::Approved => unreachable!(),
    }
}
