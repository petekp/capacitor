//! Run executor for the method runner.
//!
//! Orchestrates a complete method run: definition normalization, event
//! emission, serial phase/step execution with fake adapters, handoff
//! ingestion, output binding, and state projection.

use std::collections::BTreeMap;
use std::path::Path;

use crate::domain::{CheckpointKind, MediaArtifact, MediaArtifactType, MermaidSource};
use crate::method_runner::adapters::{
    validate_interactive_response, AdapterError, GateCheckpointContext, InteractiveIO,
    InteractivePrompt, PromptBuildRequest, PromptBuilder, WorkerDispatchRequest, WorkerDispatcher,
};
use crate::method_runner::checkpoint_manifest::CheckpointManifest;
use crate::method_runner::definition::{
    write_snapshot, write_step_json, ActionKind, CompletionPolicy, DefinitionSource, ExecutionMode,
    NormalizationError, NormalizedDefinitionFile, NormalizedGate, NormalizedPhase, NormalizedStep,
    Normalizer, StepActionConfig,
};
use crate::method_runner::events::{append_event, make_envelope, AppendError, MethodEventKind};
use crate::method_runner::handoff::{ingest_handoff, HandoffParseError};
use crate::method_runner::output::{resolve_and_write_output, ResolveError};
use crate::method_runner::state::{project, write_state_atomic, MethodRunState, ProjectionError};
use crate::method_runner::storage::{acquire_lock, LockError, MethodRunPaths};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum RunError {
    #[error("normalization error: {0}")]
    NormalizationError(#[from] NormalizationError),

    #[error("event append error: {0}")]
    AppendError(#[from] AppendError),

    #[error("lock error: {0}")]
    LockError(#[from] LockError),

    #[error("handoff parse error: {0}")]
    HandoffParseError(#[from] HandoffParseError),

    #[error("output resolve error: {0}")]
    ResolveError(#[from] ResolveError),

    #[error("adapter error: {0}")]
    AdapterError(#[from] AdapterError),

    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("projection error: {0}")]
    ProjectionError(#[from] ProjectionError),

    #[error("pipeline_execute step '{0}' requires external pipeline — run blocked")]
    PipelineExecuteBlocked(String),

    #[error("step '{step_id}' blocked: {reason}")]
    StepBlocked { step_id: String, reason: String },

    #[error("phase '{phase_id}' blocked by gate '{gate_id}': {reason}")]
    PhaseGateBlocked {
        phase_id: String,
        gate_id: String,
        reason: String,
    },
}

// ---------------------------------------------------------------------------
// Gate evaluation
// ---------------------------------------------------------------------------

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
///
/// Gate types:
/// - `approval` — prompts via InteractiveIO, expects "approved" or "rejected"
/// - `outputs_present` — checks that all named outputs in gate.outputs exist in state
/// - `handoff_verdict` — checks all steps have handoffs with CLEAN verdict
/// - `completion_claim` — checks all steps have COMPLETE claim
/// - `manual_test_complete` — prompts via InteractiveIO (same as approval)
/// - `pipeline_clean` — v1-deferred, always returns blocked (waiting)
pub fn evaluate_gate(
    gate: &NormalizedGate,
    phase: &NormalizedPhase,
    state: &MethodRunState,
    paths: &MethodRunPaths,
    interactive_io: &dyn InteractiveIO,
) -> GateOutcome {
    match gate.gate_type.as_str() {
        "approval" | "manual_test_complete" => {
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
                "rejected" => GateOutcome::Rejected,
                _ => GateOutcome::Rejected,
            }
        }
        "outputs_present" => {
            // Check that all named outputs in gate.outputs exist in the state
            let phase_id = &phase.id;
            if let Some(phase_state) = state.phases.get(phase_id) {
                for output_name in &gate.outputs {
                    // Search for the output across all steps in this phase
                    let mut found = false;
                    for step_state in phase_state.steps.values() {
                        if step_state.outputs.contains_key(output_name) {
                            found = true;
                            break;
                        }
                    }
                    if !found {
                        return GateOutcome::ValidationFailed {
                            reason: format!(
                                "output '{}' not found in phase '{}'",
                                output_name, phase_id
                            ),
                        };
                    }
                }
                GateOutcome::Approved
            } else {
                GateOutcome::ValidationFailed {
                    reason: format!("phase '{}' not found in state", phase_id),
                }
            }
        }
        "handoff_verdict" => {
            // Check that all steps in the phase have handoffs with CLEAN verdict
            for step_def in &phase.steps {
                if step_def.action != ActionKind::Dispatch {
                    continue; // Only dispatch steps have handoffs
                }
                // Find the completed attempt's handoff
                let phase_state = match state.phases.get(&phase.id) {
                    Some(ps) => ps,
                    None => {
                        return GateOutcome::ValidationFailed {
                            reason: format!("phase '{}' not found in state", phase.id),
                        }
                    }
                };
                let step_state = match phase_state.steps.get(&step_def.id) {
                    Some(ss) => ss,
                    None => {
                        return GateOutcome::ValidationFailed {
                            reason: format!("step '{}' not found in state", step_def.id),
                        }
                    }
                };
                // Find the latest completed attempt
                let completed_attempt = step_state.attempts.iter().rev().find(|(_, a)| {
                    a.status == crate::method_runner::state::AttemptStatus::Completed
                        || a.status == crate::method_runner::state::AttemptStatus::OutputBound
                });
                if let Some((attempt_num, attempt_state)) = completed_attempt {
                    // Check each worker's handoff
                    for worker_id in attempt_state.workers.keys() {
                        let handoff_path = paths.canonical_handoff(
                            &phase.id,
                            &step_def.id,
                            *attempt_num,
                            worker_id,
                        );
                        if handoff_path.exists() {
                            let content = match std::fs::read_to_string(&handoff_path) {
                                Ok(c) => c,
                                Err(_) => {
                                    return GateOutcome::ValidationFailed {
                                        reason: format!(
                                            "cannot read handoff for worker '{}'",
                                            worker_id
                                        ),
                                    }
                                }
                            };
                            let parsed = match crate::method_runner::handoff::parse_handoff(
                                &content, worker_id,
                            ) {
                                Ok(p) => p,
                                Err(_) => {
                                    return GateOutcome::ValidationFailed {
                                        reason: format!(
                                            "cannot parse handoff for worker '{}'",
                                            worker_id
                                        ),
                                    }
                                }
                            };
                            if parsed.verdict.as_deref() != Some("CLEAN") {
                                return GateOutcome::ValidationFailed {
                                    reason: format!(
                                        "worker '{}' has verdict '{}'",
                                        worker_id,
                                        parsed.verdict.as_deref().unwrap_or("none")
                                    ),
                                };
                            }
                        } else {
                            return GateOutcome::ValidationFailed {
                                reason: format!("no handoff found for worker '{}'", worker_id),
                            };
                        }
                    }
                } else {
                    return GateOutcome::ValidationFailed {
                        reason: format!("no completed attempt for step '{}'", step_def.id),
                    };
                }
            }
            GateOutcome::Approved
        }
        "completion_claim" => {
            // Check that all steps have COMPLETE claim in their handoffs
            for step_def in &phase.steps {
                if step_def.action != ActionKind::Dispatch {
                    continue;
                }
                let phase_state = match state.phases.get(&phase.id) {
                    Some(ps) => ps,
                    None => {
                        return GateOutcome::ValidationFailed {
                            reason: format!("phase '{}' not found in state", phase.id),
                        }
                    }
                };
                let step_state = match phase_state.steps.get(&step_def.id) {
                    Some(ss) => ss,
                    None => {
                        return GateOutcome::ValidationFailed {
                            reason: format!("step '{}' not found in state", step_def.id),
                        }
                    }
                };
                let completed_attempt = step_state.attempts.iter().rev().find(|(_, a)| {
                    a.status == crate::method_runner::state::AttemptStatus::Completed
                        || a.status == crate::method_runner::state::AttemptStatus::OutputBound
                });
                if let Some((attempt_num, attempt_state)) = completed_attempt {
                    for worker_id in attempt_state.workers.keys() {
                        let handoff_path = paths.canonical_handoff(
                            &phase.id,
                            &step_def.id,
                            *attempt_num,
                            worker_id,
                        );
                        if handoff_path.exists() {
                            let content = match std::fs::read_to_string(&handoff_path) {
                                Ok(c) => c,
                                Err(_) => {
                                    return GateOutcome::ValidationFailed {
                                        reason: format!(
                                            "cannot read handoff for worker '{}'",
                                            worker_id
                                        ),
                                    }
                                }
                            };
                            let parsed = match crate::method_runner::handoff::parse_handoff(
                                &content, worker_id,
                            ) {
                                Ok(p) => p,
                                Err(_) => {
                                    return GateOutcome::ValidationFailed {
                                        reason: format!(
                                            "cannot parse handoff for worker '{}'",
                                            worker_id
                                        ),
                                    }
                                }
                            };
                            if parsed.completion_claim.as_deref() != Some("COMPLETE") {
                                return GateOutcome::ValidationFailed {
                                    reason: format!(
                                        "worker '{}' has completion claim '{}'",
                                        worker_id,
                                        parsed.completion_claim.as_deref().unwrap_or("none")
                                    ),
                                };
                            }
                        } else {
                            return GateOutcome::ValidationFailed {
                                reason: format!("no handoff found for worker '{}'", worker_id),
                            };
                        }
                    }
                } else {
                    return GateOutcome::ValidationFailed {
                        reason: format!("no completed attempt for step '{}'", step_def.id),
                    };
                }
            }
            GateOutcome::Approved
        }
        "pipeline_clean" => {
            // v1-deferred: always returns waiting (blocked)
            GateOutcome::Waiting
        }
        _ => GateOutcome::ValidationFailed {
            reason: format!("unknown gate type '{}'", gate.gate_type),
        },
    }
}

// ---------------------------------------------------------------------------
// Normalize-only entrypoint
// ---------------------------------------------------------------------------

/// Normalize a definition and write the snapshot + step.json files.
/// Does not emit events or execute anything.
pub fn execute_normalize(source: &DefinitionSource) -> Result<(), RunError> {
    let yaml_content = std::fs::read_to_string(&source.definition_path)?;
    let normalized = Normalizer::normalize(&yaml_content)?;
    let paths = MethodRunPaths::new(&source.execution_root);

    // Create .method/ directories
    std::fs::create_dir_all(paths.method_root())?;

    // Write definition snapshot
    write_snapshot(&paths.definition_snapshot(), &normalized)?;

    // Write step.json for each step
    for phase in &normalized.method.phases {
        for step in &phase.steps {
            let step_dir = paths.step_dir(&phase.id, &step.id);
            write_step_json(&step_dir, &phase.id, step)?;
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Full run entrypoint
// ---------------------------------------------------------------------------

/// Execute a complete method run: normalize, emit events, dispatch workers,
/// ingest handoffs, bind outputs, and project final state.
pub fn execute_run(
    source: &DefinitionSource,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
) -> Result<MethodRunState, RunError> {
    // 1. Read + normalize definition
    let yaml_content = std::fs::read_to_string(&source.definition_path)?;
    let normalized = Normalizer::normalize(&yaml_content)?;
    let paths = MethodRunPaths::new(&source.execution_root);

    // 2. Create .method/ directories
    create_method_dirs(&paths)?;

    // 3. Write definition snapshot
    write_snapshot(&paths.definition_snapshot(), &normalized)?;

    // 4. Write step.json for each step
    for phase in &normalized.method.phases {
        for step in &phase.steps {
            let step_dir = paths.step_dir(&phase.id, &step.id);
            write_step_json(&step_dir, &phase.id, step)?;
        }
    }

    // 5. Generate run_id
    let run_id = ulid::Ulid::new().to_string();

    // 6. Initialize sequence counter
    let mut current_seq: u64 = 0;
    let events_path = paths.events_log();

    // 7. Acquire lock
    let _lock = acquire_lock(&paths.lock_file(), std::time::Duration::from_secs(10))?;

    // 8. DefinitionFrozen event
    {
        let mut env = make_envelope(&run_id, MethodEventKind::DefinitionFrozen);
        append_event(&events_path, &mut env, &mut current_seq)?;
    }

    // 9. RunStarted event
    {
        let mut env = make_envelope(&run_id, MethodEventKind::RunStarted);
        append_event(&events_path, &mut env, &mut current_seq)?;
    }

    // 10. Execute phases (serial or parallel depending on mode)
    let run_start = std::time::Instant::now();
    for phase in &normalized.method.phases {
        // PhaseStarted
        {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseStarted);
            env.phase_id = Some(phase.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }

        if phase.execution == ExecutionMode::Parallel {
            // Parallel: execute all steps regardless of individual failures
            let mut step_results: Vec<(&NormalizedStep, Result<(), RunError>)> = Vec::new();
            for step in &phase.steps {
                let result = if step.action == ActionKind::PipelineExecute {
                    let mut env = make_envelope(&run_id, MethodEventKind::StepBlocked);
                    env.phase_id = Some(phase.id.clone());
                    env.step_id = Some(step.id.clone());
                    env.payload = serde_json::json!({
                        "blocked_reason": {
                            "category": "pipeline_blocked",
                            "details": "pipeline_execute not supported in v1"
                        }
                    });
                    append_event(&events_path, &mut env, &mut current_seq)?;
                    Err(RunError::PipelineExecuteBlocked(step.id.clone()))
                } else {
                    execute_step(
                        &paths,
                        &events_path,
                        &run_id,
                        &mut current_seq,
                        &phase.id,
                        step,
                        prompt_builder,
                        dispatcher,
                        interactive_io,
                    )
                };
                step_results.push((step, result));
            }

            // Join semantics: check outcomes
            let mut any_failed = false;
            let mut any_blocked = false;
            let mut all_ok = true;
            for (_step, result) in &step_results {
                match result {
                    Ok(()) => {}
                    Err(RunError::StepBlocked { .. })
                    | Err(RunError::PipelineExecuteBlocked(_)) => {
                        any_blocked = true;
                        all_ok = false;
                    }
                    Err(_) => {
                        any_failed = true;
                        all_ok = false;
                    }
                }
            }

            if any_blocked {
                // Phase blocked
                let mut env = make_envelope(&run_id, MethodEventKind::PhaseBlocked);
                env.phase_id = Some(phase.id.clone());
                env.payload = serde_json::json!({ "reason": "one or more parallel steps blocked" });
                append_event(&events_path, &mut env, &mut current_seq)?;

                // Emit RunBlocked with summary
                {
                    let summary = build_run_summary(&events_path, &normalized, run_start)?;
                    let mut env = make_envelope(&run_id, MethodEventKind::RunBlocked);
                    env.payload = summary;
                    append_event(&events_path, &mut env, &mut current_seq)?;
                }

                let events = crate::method_runner::events::recover_events(&events_path)?;
                let state = project(&events)?;
                write_state_atomic(&paths.state_json(), &state).map_err(RunError::IoError)?;
                return Ok(state);
            } else if any_failed && !all_ok {
                // Phase failed
                let mut env = make_envelope(&run_id, MethodEventKind::PhaseFailed);
                env.phase_id = Some(phase.id.clone());
                env.payload = serde_json::json!({ "reason": "one or more parallel steps failed" });
                append_event(&events_path, &mut env, &mut current_seq)?;

                // Emit RunFailed with summary
                {
                    let summary = build_run_summary(&events_path, &normalized, run_start)?;
                    let mut env = make_envelope(&run_id, MethodEventKind::RunFailed);
                    env.payload = summary;
                    append_event(&events_path, &mut env, &mut current_seq)?;
                }

                let events = crate::method_runner::events::recover_events(&events_path)?;
                let state = project(&events)?;
                write_state_atomic(&paths.state_json(), &state).map_err(RunError::IoError)?;
                return Ok(state);
            }
            // all_ok: fall through to gate evaluation and PhaseCompleted
        } else {
            // Serial: existing behavior — step failure stops the phase
            for step in &phase.steps {
                // Check for pipeline_execute — blocked
                if step.action == ActionKind::PipelineExecute {
                    // Emit StepBlocked event before returning error
                    let mut env = make_envelope(&run_id, MethodEventKind::StepBlocked);
                    env.phase_id = Some(phase.id.clone());
                    env.step_id = Some(step.id.clone());
                    env.payload = serde_json::json!({
                        "blocked_reason": {
                            "category": "pipeline_blocked",
                            "details": "pipeline_execute not supported in v1"
                        }
                    });
                    append_event(&events_path, &mut env, &mut current_seq)?;

                    return Err(RunError::PipelineExecuteBlocked(step.id.clone()));
                }

                execute_step(
                    &paths,
                    &events_path,
                    &run_id,
                    &mut current_seq,
                    &phase.id,
                    step,
                    prompt_builder,
                    dispatcher,
                    interactive_io,
                )?;
            }
        }

        // Evaluate phase gate (if present) after all steps complete
        if let Some(ref gate) = phase.gate {
            // Project current state to evaluate gate against
            let current_events = crate::method_runner::events::recover_events(&events_path)?;
            let current_state = project(&current_events)?;

            let outcome = evaluate_gate(gate, phase, &current_state, &paths, interactive_io);

            // Emit GateEvaluated event
            {
                let mut env = make_envelope(&run_id, MethodEventKind::GateEvaluated);
                env.phase_id = Some(phase.id.clone());
                let mut payload = serde_json::json!({
                    "gate_id": gate.id,
                    "gate_type": gate.gate_type,
                    "outcome": outcome.as_str(),
                });
                if let Some(reason) = outcome.reason() {
                    payload["reason"] = serde_json::Value::String(reason.to_string());
                }
                env.payload = payload;
                append_event(&events_path, &mut env, &mut current_seq)?;
            }

            match outcome {
                GateOutcome::Approved => {
                    // Phase completes normally — fall through to PhaseCompleted
                }
                GateOutcome::Rejected
                | GateOutcome::ValidationFailed { .. }
                | GateOutcome::TimedOut
                | GateOutcome::Waiting => {
                    let reason = match &outcome {
                        GateOutcome::Rejected => "gate rejected".to_string(),
                        GateOutcome::ValidationFailed { reason } => {
                            format!("validation failed: {}", reason)
                        }
                        GateOutcome::TimedOut => "gate timed out".to_string(),
                        GateOutcome::Waiting => {
                            "pipeline_clean requires pipeline-execute, not implemented in v1"
                                .to_string()
                        }
                        _ => unreachable!(),
                    };

                    // Emit PhaseBlocked
                    {
                        let mut env = make_envelope(&run_id, MethodEventKind::PhaseBlocked);
                        env.phase_id = Some(phase.id.clone());
                        env.payload = serde_json::json!({ "reason": reason });
                        append_event(&events_path, &mut env, &mut current_seq)?;
                    }

                    return Err(RunError::PhaseGateBlocked {
                        phase_id: phase.id.clone(),
                        gate_id: gate.id.clone(),
                        reason,
                    });
                }
            }
        }

        // PhaseCompleted
        {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseCompleted);
            env.phase_id = Some(phase.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }
    }

    // 11. Resolve method-level outputs
    resolve_method_outputs(&paths, &events_path, &run_id, &mut current_seq, &normalized)?;

    // 12. RunCompleted with summary payload
    {
        let summary = build_run_summary(&events_path, &normalized, run_start)?;
        let mut env = make_envelope(&run_id, MethodEventKind::RunCompleted);
        env.payload = summary;
        append_event(&events_path, &mut env, &mut current_seq)?;
    }

    // 13. Project state from events and write state.json
    let events = crate::method_runner::events::recover_events(&events_path)?;
    let state = project(&events)?;
    write_state_atomic(&paths.state_json(), &state).map_err(RunError::IoError)?;

    // 14. Lock released on drop
    Ok(state)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn create_method_dirs(paths: &MethodRunPaths) -> Result<(), std::io::Error> {
    std::fs::create_dir_all(paths.method_root())?;
    std::fs::create_dir_all(paths.method_root().join("steps"))?;
    std::fs::create_dir_all(paths.method_root().join("locks"))?;
    std::fs::create_dir_all(paths.method_root().join("artifacts").join("handoffs"))?;
    std::fs::create_dir_all(paths.method_root().join("artifacts").join("outputs"))?;
    Ok(())
}

/// Public wrapper for `execute_step` used by the resume module.
#[allow(clippy::too_many_arguments)]
pub fn execute_step_public(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
) -> Result<(), RunError> {
    // Check for pipeline_execute at the public boundary
    if step.action == ActionKind::PipelineExecute {
        let mut env = make_envelope(run_id, MethodEventKind::StepBlocked);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
        return Err(RunError::PipelineExecuteBlocked(step.id.clone()));
    }
    execute_step(
        paths,
        events_path,
        run_id,
        current_seq,
        phase_id,
        step,
        prompt_builder,
        dispatcher,
        interactive_io,
    )
}

#[allow(clippy::too_many_arguments)]
fn execute_step(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
) -> Result<(), RunError> {
    match step.action {
        ActionKind::Dispatch => execute_dispatch_step(
            paths,
            events_path,
            run_id,
            current_seq,
            phase_id,
            step,
            prompt_builder,
            dispatcher,
        ),
        ActionKind::Synthesis => {
            execute_synthesis_step(paths, events_path, run_id, current_seq, phase_id, step)
        }
        ActionKind::Interactive => execute_interactive_step(
            paths,
            events_path,
            run_id,
            current_seq,
            phase_id,
            step,
            interactive_io,
        ),
        ActionKind::PipelineExecute => {
            unreachable!("pipeline_execute is blocked before execute_step is called")
        }
    }
}

// ---------------------------------------------------------------------------
// Dispatch step execution (with retry loop, circuit breaker, multi-worker)
// ---------------------------------------------------------------------------

/// Result of dispatching all workers in a single attempt.
#[derive(Debug)]
enum AttemptOutcome {
    /// All workers completed cleanly according to completion policy.
    Success,
    /// At least one worker failed (adapter error or non-zero exit without handoff).
    Failed { reason: String },
}

#[allow(clippy::too_many_arguments)]
fn execute_dispatch_step(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
) -> Result<(), RunError> {
    // StepStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }

    // Extract workers from config (always at least one: implicit "primary")
    let workers = match &step.config {
        StepActionConfig::Dispatch { workers, .. } => workers.clone(),
        _ => vec![],
    };

    // Extract step-level instructions
    let step_instructions = match &step.config {
        StepActionConfig::Dispatch { instructions, .. } => instructions.clone(),
        _ => String::new(),
    };

    let mut last_failure_reason = String::new();

    // Retry loop: attempt 1..=max_attempts
    for attempt in 1..=step.max_attempts {
        let attempt_dir = paths.attempt_dir(phase_id, &step.id, attempt);
        std::fs::create_dir_all(&attempt_dir)?;

        // Write input-bindings.json
        write_input_bindings(&attempt_dir, &step.inputs)?;

        let attempt_start = std::time::Instant::now();

        // AttemptStarted
        {
            let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            append_event(events_path, &mut env, current_seq)?;
        }

        // Dispatch all workers in this attempt
        let outcome = dispatch_attempt_workers(
            paths,
            events_path,
            run_id,
            current_seq,
            phase_id,
            step,
            &workers,
            &step_instructions,
            attempt,
            &last_failure_reason,
            prompt_builder,
            dispatcher,
        )?;

        let elapsed_ms = attempt_start.elapsed().as_millis() as u64;

        match outcome {
            AttemptOutcome::Success => {
                // Evaluate completion policy and bind outputs
                bind_attempt_outputs(
                    paths,
                    events_path,
                    run_id,
                    current_seq,
                    phase_id,
                    step,
                    attempt,
                    &workers,
                )?;

                // Write attempt.json (success)
                write_attempt_json(&attempt_dir, phase_id, &step.id, attempt, "completed")?;

                // AttemptCompleted with timing
                {
                    let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.payload = serde_json::json!({ "elapsed_ms": elapsed_ms });
                    append_event(events_path, &mut env, current_seq)?;
                }

                // StepCompleted
                {
                    let mut env = make_envelope(run_id, MethodEventKind::StepCompleted);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    append_event(events_path, &mut env, current_seq)?;
                }

                return Ok(());
            }
            AttemptOutcome::Failed { reason } => {
                // Write attempt.json (failed)
                write_attempt_json(&attempt_dir, phase_id, &step.id, attempt, "failed")?;

                // Categorize the error
                let error_category = categorize_attempt_error(&reason);

                // AttemptFailed with timing and error category
                {
                    let mut env = make_envelope(run_id, MethodEventKind::AttemptFailed);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.payload = serde_json::json!({
                        "reason": reason,
                        "elapsed_ms": elapsed_ms,
                        "error_category": error_category,
                    });
                    append_event(events_path, &mut env, current_seq)?;
                }

                last_failure_reason = reason;
                // Loop continues to next attempt (if any remain)
            }
        }
    }

    // Circuit breaker: all attempts exhausted without success → StepBlocked
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepBlocked);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.payload = serde_json::json!({
            "reason": format!(
                "circuit breaker: all {} attempts exhausted",
                step.max_attempts
            ),
            "last_failure": last_failure_reason,
            "blocked_reason": {
                "category": "circuit_breaker",
                "details": format!("all {} attempts exhausted", step.max_attempts),
            },
        });
        append_event(events_path, &mut env, current_seq)?;
    }

    // StepBlocked means the run cannot continue this step, but we don't
    // error out — we return Ok and let the caller decide (phase may block).
    // For now in serial execution, a blocked step is a run-stopping condition.
    Err(RunError::StepBlocked {
        step_id: step.id.clone(),
        reason: format!(
            "circuit breaker: all {} attempts exhausted",
            step.max_attempts
        ),
    })
}

/// Dispatch all workers for a single attempt. Returns Success if the completion
/// policy is satisfied, Failed otherwise.
#[allow(clippy::too_many_arguments)]
fn dispatch_attempt_workers(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    workers: &[crate::method_runner::definition::NormalizedWorkerSpec],
    step_instructions: &str,
    attempt: u32,
    prior_failure: &str,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
) -> Result<AttemptOutcome, RunError> {
    let mut worker_results: Vec<(String, bool)> = Vec::new(); // (worker_id, success)

    for worker in workers {
        let worker_id = &worker.id;

        // Create worker relay dir
        let relay_root = paths.worker_relay_root(phase_id, &step.id, attempt, worker_id);
        std::fs::create_dir_all(&relay_root)?;

        // Build prompt (use worker-specific instructions if available, else step-level)
        let instructions = if worker.instructions.is_empty() {
            step_instructions.to_string()
        } else {
            worker.instructions.clone()
        };

        // Include retry context in instructions if this is a retry
        let full_instructions = if attempt > 1 && !prior_failure.is_empty() {
            format!(
                "{}\n\n## Retry Context (attempt {})\nPrior failure: {}",
                instructions, attempt, prior_failure
            )
        } else {
            instructions
        };

        // Merge skills: step-level + worker-level, stable order, deduplicated
        let merged_skills = {
            let mut skills = step.skills.clone();
            for s in &worker.skills {
                if !skills.contains(s) {
                    skills.push(s.clone());
                }
            }
            skills
        };

        let prompt_request = PromptBuildRequest {
            phase_id: phase_id.to_string(),
            step_id: step.id.clone(),
            attempt,
            relay_root: relay_root.clone(),
            instructions: full_instructions,
            template: step.template.clone(),
            skills: merged_skills,
        };
        let prompt_result = prompt_builder.build_prompt(&prompt_request)?;

        // WorkerDispatched
        {
            let mut env = make_envelope(run_id, MethodEventKind::WorkerDispatched);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.worker_id = Some(worker_id.clone());
            append_event(events_path, &mut env, current_seq)?;
        }

        // Dispatch worker — prompt_path comes explicitly from IF1 result
        let dispatch_request = WorkerDispatchRequest {
            phase_id: phase_id.to_string(),
            step_id: step.id.clone(),
            attempt,
            worker_id: worker_id.clone(),
            relay_root: relay_root.clone(),
            prompt_path: prompt_result.prompt_path,
        };
        let dispatch_result = dispatcher.dispatch(&dispatch_request);

        match dispatch_result {
            Ok(result) => {
                let clean_exit = result.exit_code == 0;

                if clean_exit {
                    // WorkerCompleted
                    let mut env = make_envelope(run_id, MethodEventKind::WorkerCompleted);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.worker_id = Some(worker_id.clone());
                    append_event(events_path, &mut env, current_seq)?;
                } else {
                    // WorkerFailed (non-zero exit)
                    let mut env = make_envelope(run_id, MethodEventKind::WorkerFailed);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.worker_id = Some(worker_id.clone());
                    env.payload = serde_json::json!({ "exit_code": result.exit_code });
                    append_event(events_path, &mut env, current_seq)?;
                }

                // Ingest handoff if present (even for failed workers — we want the data)
                let handoff_path = find_handoff(&relay_root);
                if let Some(handoff_source) = handoff_path {
                    let _ingest_result = ingest_handoff(
                        paths,
                        phase_id,
                        &step.id,
                        attempt,
                        worker_id,
                        &handoff_source,
                    )?;

                    // HandoffIngested
                    let mut env = make_envelope(run_id, MethodEventKind::HandoffIngested);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.worker_id = Some(worker_id.clone());
                    append_event(events_path, &mut env, current_seq)?;
                }

                worker_results.push((worker_id.clone(), clean_exit));
            }
            Err(e) => {
                // WorkerFailed (adapter error — spawn failed, timeout, etc.)
                let mut env = make_envelope(run_id, MethodEventKind::WorkerFailed);
                env.phase_id = Some(phase_id.to_string());
                env.step_id = Some(step.id.clone());
                env.attempt = Some(attempt);
                env.worker_id = Some(worker_id.clone());
                env.payload = serde_json::json!({ "error": e.to_string() });
                append_event(events_path, &mut env, current_seq)?;

                worker_results.push((worker_id.clone(), false));
            }
        }
    }

    // Evaluate completion policy
    let succeeded = evaluate_completion_policy(step.completion_policy, &worker_results, workers);

    if succeeded {
        Ok(AttemptOutcome::Success)
    } else {
        let failed_workers: Vec<&str> = worker_results
            .iter()
            .filter(|(_, ok)| !ok)
            .map(|(id, _)| id.as_str())
            .collect();
        Ok(AttemptOutcome::Failed {
            reason: format!("workers failed: {}", failed_workers.join(", ")),
        })
    }
}

/// Evaluate whether the completion policy is satisfied given worker results.
fn evaluate_completion_policy(
    policy: CompletionPolicy,
    results: &[(String, bool)],
    workers: &[crate::method_runner::definition::NormalizedWorkerSpec],
) -> bool {
    match policy {
        CompletionPolicy::AllComplete => {
            // All workers must have succeeded
            results.iter().all(|(_, ok)| *ok)
        }
        CompletionPolicy::FirstClean => {
            // First worker in definition order that succeeded is enough.
            // We check workers in definition order, not results order.
            for worker_spec in workers {
                if let Some((_, ok)) = results.iter().find(|(id, _)| *id == worker_spec.id) {
                    if *ok {
                        return true;
                    }
                }
            }
            false
        }
    }
}

/// Bind outputs for a successful attempt. Emits OutputBound events.
#[allow(clippy::too_many_arguments)]
fn bind_attempt_outputs(
    _paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    attempt: u32,
    workers: &[crate::method_runner::definition::NormalizedWorkerSpec],
) -> Result<(), RunError> {
    let attempt_dir = _paths.attempt_dir(phase_id, &step.id, attempt);

    // Determine which worker to bind from based on completion policy
    let binding_worker_id = match step.completion_policy {
        CompletionPolicy::FirstClean => {
            // Use the first worker in definition order (for first-clean,
            // that's the winning worker)
            workers.first().map(|w| w.id.as_str()).unwrap_or("primary")
        }
        CompletionPolicy::AllComplete => {
            // For all_complete with single worker, use "primary"
            // For multi-worker all_complete, outputs come from each worker
            workers.first().map(|w| w.id.as_str()).unwrap_or("primary")
        }
    };

    let mut output_bindings: BTreeMap<String, serde_json::Value> = BTreeMap::new();
    for (output_name, output_def) in &step.outputs {
        let resolved_path = output_def.path.clone();
        output_bindings.insert(
            output_name.clone(),
            serde_json::json!({
                "path": resolved_path,
                "type": output_def.output_type,
                "worker_id": binding_worker_id,
            }),
        );

        // OutputBound event
        let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.worker_id = Some(binding_worker_id.to_string());
        env.payload = serde_json::json!({
            "name": output_name,
            "path": resolved_path,
            "type": output_def.output_type,
        });
        append_event(events_path, &mut env, current_seq)?;
    }

    let bindings_json = serde_json::json!({ "outputs": output_bindings });
    let json = serde_json::to_string_pretty(&bindings_json).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("output-bindings.json"), json)?;

    Ok(())
}

/// Write input-bindings.json to an attempt directory.
fn write_input_bindings(attempt_dir: &Path, inputs: &[String]) -> Result<(), std::io::Error> {
    let inputs_map: BTreeMap<String, String> = inputs
        .iter()
        .map(|input| (input.clone(), input.clone()))
        .collect();
    let bindings = serde_json::json!({ "inputs": inputs_map });
    let json = serde_json::to_string_pretty(&bindings).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("input-bindings.json"), json)
}

/// Write attempt.json with status and timestamps.
fn write_attempt_json(
    attempt_dir: &Path,
    phase_id: &str,
    step_id: &str,
    attempt: u32,
    status: &str,
) -> Result<(), std::io::Error> {
    let attempt_json = serde_json::json!({
        "phase_id": phase_id,
        "step_id": step_id,
        "attempt": attempt,
        "status": status,
        "started_at": chrono::Utc::now().to_rfc3339(),
        "completed_at": chrono::Utc::now().to_rfc3339(),
    });
    let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("attempt.json"), json)
}

// ---------------------------------------------------------------------------
// Synthesis step execution
// ---------------------------------------------------------------------------

fn execute_synthesis_step(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
) -> Result<(), RunError> {
    // StepStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }

    let attempt: u32 = 1;

    // Create attempt dir — NO relay directory (C3: synthesis has no relay root)
    let attempt_dir = paths.attempt_dir(phase_id, &step.id, attempt);
    std::fs::create_dir_all(&attempt_dir)?;

    // Write input-bindings.json
    {
        let inputs_map: BTreeMap<String, String> = step
            .inputs
            .iter()
            .map(|input| (input.clone(), input.clone()))
            .collect();
        let bindings = serde_json::json!({ "inputs": inputs_map });
        let json = serde_json::to_string_pretty(&bindings).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("input-bindings.json"), json)?;
    }

    let attempt_start = std::time::Instant::now();

    // AttemptStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // SynthesisStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::SynthesisStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        // No worker_id for synthesis
        append_event(events_path, &mut env, current_seq)?;
    }

    // Resolve declared inputs from current state (prior step outputs)
    let resolved_inputs: BTreeMap<String, String> = {
        let current_events = crate::method_runner::events::recover_events(events_path)?;
        let current_state = project(&current_events)?;
        let mut resolved = BTreeMap::new();
        for input_ref in &step.inputs {
            // Input refs are locator-style: "phase.step.output_name"
            let segments: Vec<&str> = input_ref.split('.').collect();
            if segments.len() >= 3 {
                let ref_phase = segments[0];
                let ref_step = segments[1];
                let ref_output = segments.last().unwrap();
                if let Some(phase_state) = current_state.phases.get(ref_phase) {
                    if let Some(step_state) = phase_state.steps.get(ref_step) {
                        if let Some(output_path) = step_state.outputs.get(*ref_output) {
                            resolved.insert(input_ref.clone(), output_path.clone());
                        }
                    }
                }
            }
            // If not resolved, record as unresolved
            if !resolved.contains_key(input_ref) {
                resolved.insert(input_ref.clone(), format!("(unresolved: {})", input_ref));
            }
        }
        resolved
    };

    // Write output artifacts for each declared output (with resolved inputs)
    for output_def in step.outputs.values() {
        let output_path = attempt_dir.join(&output_def.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let instructions = match &step.config {
            StepActionConfig::Synthesis { instructions, .. } => instructions.clone(),
            _ => String::new(),
        };

        // Build content with resolved input references
        let mut content = format!("# Synthesized\n\nInstructions: {}\n", instructions);
        if !resolved_inputs.is_empty() {
            content.push_str("\n## Consumed Inputs\n\n");
            for (input_name, input_path) in &resolved_inputs {
                content.push_str(&format!("- {}: {}\n", input_name, input_path));
            }
        }
        content.push('\n');
        std::fs::write(&output_path, content)?;
    }

    // SynthesisCompleted — emitted after output artifacts written, before OutputBound events
    {
        let mut env = make_envelope(run_id, MethodEventKind::SynthesisCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // Write output-bindings.json and emit OutputBound events
    {
        let mut output_bindings: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        for (output_name, output_def) in &step.outputs {
            let resolved_path = output_def.path.clone();
            output_bindings.insert(
                output_name.clone(),
                serde_json::json!({
                    "path": resolved_path,
                    "type": output_def.output_type,
                }),
            );

            // OutputBound event — no worker_id for synthesis
            let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.payload = serde_json::json!({
                "name": output_name,
                "path": resolved_path,
                "type": output_def.output_type,
            });
            append_event(events_path, &mut env, current_seq)?;
        }

        let bindings_json = serde_json::json!({ "outputs": output_bindings });
        let json = serde_json::to_string_pretty(&bindings_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("output-bindings.json"), json)?;
    }

    // Write attempt.json
    {
        let attempt_json = serde_json::json!({
            "phase_id": phase_id,
            "step_id": step.id,
            "attempt": attempt,
            "status": "completed",
            "action": "synthesis",
            "started_at": chrono::Utc::now().to_rfc3339(),
            "completed_at": chrono::Utc::now().to_rfc3339(),
        });
        let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("attempt.json"), json)?;
    }

    // AttemptCompleted with timing
    {
        let elapsed_ms = attempt_start.elapsed().as_millis() as u64;
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({ "elapsed_ms": elapsed_ms });
        append_event(events_path, &mut env, current_seq)?;
    }

    // StepCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Interactive step execution
// ---------------------------------------------------------------------------

fn execute_interactive_step(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    interactive_io: &dyn InteractiveIO,
) -> Result<(), RunError> {
    // StepStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }

    let attempt: u32 = 1;

    // Create attempt dir — NO relay directory (interactive has no relay root)
    let attempt_dir = paths.attempt_dir(phase_id, &step.id, attempt);
    std::fs::create_dir_all(&attempt_dir)?;

    // Write input-bindings.json
    {
        let inputs_map: BTreeMap<String, String> = step
            .inputs
            .iter()
            .map(|input| (input.clone(), input.clone()))
            .collect();
        let bindings = serde_json::json!({ "inputs": inputs_map });
        let json = serde_json::to_string_pretty(&bindings).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("input-bindings.json"), json)?;
    }

    let attempt_start = std::time::Instant::now();

    // AttemptStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // Extract prompt and response_type from interactive config
    let (prompt_message, response_type) = match &step.config {
        StepActionConfig::Interactive {
            prompt,
            response_type,
            ..
        } => (prompt.clone(), response_type.clone()),
        _ => (String::new(), String::new()),
    };

    // Persist prompt to attempt dir BEFORE collecting response (resume can re-display)
    std::fs::write(attempt_dir.join("prompt.txt"), &prompt_message)?;

    // InteractivePrompted
    {
        let mut env = make_envelope(run_id, MethodEventKind::InteractivePrompted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({
            "prompt": prompt_message,
            "response_type": response_type,
        });
        // No worker_id for interactive
        append_event(events_path, &mut env, current_seq)?;
    }

    // Emit prompt and capture response via InteractiveIO
    interactive_io.emit_prompt(&InteractivePrompt {
        message: prompt_message,
    });
    let response = interactive_io.capture_response();

    // Validate response against declared response_type
    if !response_type.is_empty() {
        if let Err(validation_err) = validate_interactive_response(&response_type, &response.body) {
            let elapsed_ms = attempt_start.elapsed().as_millis() as u64;
            // Emit AttemptFailed with timing and error category
            {
                let mut env = make_envelope(run_id, MethodEventKind::AttemptFailed);
                env.phase_id = Some(phase_id.to_string());
                env.step_id = Some(step.id.clone());
                env.attempt = Some(attempt);
                env.payload = serde_json::json!({
                    "reason": validation_err,
                    "elapsed_ms": elapsed_ms,
                    "error_category": "validation_failed",
                });
                append_event(events_path, &mut env, current_seq)?;
            }
            // Emit StepBlocked with structured blocked_reason
            {
                let mut env = make_envelope(run_id, MethodEventKind::StepBlocked);
                env.phase_id = Some(phase_id.to_string());
                env.step_id = Some(step.id.clone());
                env.payload = serde_json::json!({
                    "reason": format!("response validation failed: {}", validation_err),
                    "blocked_reason": {
                        "category": "gate_rejected",
                        "details": format!("response validation failed: {}", validation_err),
                    }
                });
                append_event(events_path, &mut env, current_seq)?;
            }
            return Err(RunError::StepBlocked {
                step_id: step.id.clone(),
                reason: format!("response validation failed: {}", validation_err),
            });
        }
    }

    // InteractiveResponseReceived
    {
        let mut env = make_envelope(run_id, MethodEventKind::InteractiveResponseReceived);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({
            "response_length": response.body.len(),
            "response_type": response_type,
        });
        append_event(events_path, &mut env, current_seq)?;
    }

    // Write response as output artifact for each declared output
    for output_def in step.outputs.values() {
        let output_path = attempt_dir.join(&output_def.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&output_path, &response.body)?;
    }

    // Write output-bindings.json and emit OutputBound events
    {
        let mut output_bindings: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        for (output_name, output_def) in &step.outputs {
            let resolved_path = output_def.path.clone();
            output_bindings.insert(
                output_name.clone(),
                serde_json::json!({
                    "path": resolved_path,
                    "type": output_def.output_type,
                }),
            );

            // OutputBound event — no worker_id for interactive
            let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.payload = serde_json::json!({
                "name": output_name,
                "path": resolved_path,
                "type": output_def.output_type,
            });
            append_event(events_path, &mut env, current_seq)?;
        }

        let bindings_json = serde_json::json!({ "outputs": output_bindings });
        let json = serde_json::to_string_pretty(&bindings_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("output-bindings.json"), json)?;
    }

    // Write attempt.json
    {
        let attempt_json = serde_json::json!({
            "phase_id": phase_id,
            "step_id": step.id,
            "attempt": attempt,
            "status": "completed",
            "action": "interactive",
            "started_at": chrono::Utc::now().to_rfc3339(),
            "completed_at": chrono::Utc::now().to_rfc3339(),
        });
        let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("attempt.json"), json)?;
    }

    // AttemptCompleted with timing
    {
        let elapsed_ms = attempt_start.elapsed().as_millis() as u64;
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({ "elapsed_ms": elapsed_ms });
        append_event(events_path, &mut env, current_seq)?;
    }

    // StepCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Error categorization
// ---------------------------------------------------------------------------

/// Categorize an attempt failure reason into a structured error category.
fn categorize_attempt_error(reason: &str) -> &'static str {
    let lower = reason.to_lowercase();
    if lower.contains("spawn failed") || lower.contains("timeout") || lower.contains("i/o error") {
        "adapter_error"
    } else if lower.contains("crash") || lower.contains("exit_code") || lower.contains("non-zero") {
        "worker_crash"
    } else if lower.contains("handoff") || lower.contains("no handoff") {
        "handoff_missing"
    } else if lower.contains("validation") {
        "validation_failed"
    } else {
        "adapter_error"
    }
}

// ---------------------------------------------------------------------------
// Run summary
// ---------------------------------------------------------------------------

/// Build a run summary payload with aggregate statistics from the run.
fn build_run_summary(
    events_path: &Path,
    normalized: &NormalizedDefinitionFile,
    run_start: std::time::Instant,
) -> Result<serde_json::Value, RunError> {
    let events = crate::method_runner::events::recover_events(events_path)?;
    let state = project(&events)?;
    let elapsed_ms = run_start.elapsed().as_millis() as u64;

    let total_phases = normalized.method.phases.len() as u64;
    let total_steps: u64 = normalized
        .method
        .phases
        .iter()
        .map(|p| p.steps.len() as u64)
        .sum();

    let mut completed_phases: u64 = 0;
    let mut blocked_phases: u64 = 0;
    let mut failed_phases: u64 = 0;
    let mut completed_steps: u64 = 0;
    let mut blocked_steps: u64 = 0;
    let mut failed_steps: u64 = 0;
    let mut total_attempts: u64 = 0;

    for phase_state in state.phases.values() {
        match phase_state.status {
            crate::method_runner::state::PhaseStatus::Completed => completed_phases += 1,
            crate::method_runner::state::PhaseStatus::Blocked => blocked_phases += 1,
            crate::method_runner::state::PhaseStatus::Failed => failed_phases += 1,
            _ => {}
        }
        for step_state in phase_state.steps.values() {
            match step_state.status {
                crate::method_runner::state::StepStatus::Completed => completed_steps += 1,
                crate::method_runner::state::StepStatus::Blocked => blocked_steps += 1,
                crate::method_runner::state::StepStatus::Failed => failed_steps += 1,
                _ => {}
            }
            total_attempts += step_state.attempts.len() as u64;
        }
    }

    let total_events = events.len() as u64;

    Ok(serde_json::json!({
        "summary": {
            "total_phases": total_phases,
            "completed_phases": completed_phases,
            "blocked_phases": blocked_phases,
            "failed_phases": failed_phases,
            "total_steps": total_steps,
            "completed_steps": completed_steps,
            "blocked_steps": blocked_steps,
            "failed_steps": failed_steps,
            "total_attempts": total_attempts,
            "total_events": total_events,
            "elapsed_ms": elapsed_ms,
        }
    }))
}

fn find_handoff(relay_root: &Path) -> Option<std::path::PathBuf> {
    let uppercase = relay_root.join("HANDOFF.md");
    if uppercase.exists() {
        return Some(uppercase);
    }
    let lowercase = relay_root.join("handoff.md");
    if lowercase.exists() {
        return Some(lowercase);
    }
    None
}

fn resolve_method_outputs(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    normalized: &NormalizedDefinitionFile,
) -> Result<(), RunError> {
    // Project current state to resolve outputs against
    let events = crate::method_runner::events::recover_events(events_path)?;
    let state = project(&events)?;

    for (name, output) in &normalized.method.outputs {
        match resolve_and_write_output(paths, name, &output.from, &state, &normalized.method) {
            Ok(_record) => {}
            Err(e) => {
                if output.required {
                    return Err(RunError::ResolveError(e));
                }
                // Non-required output — log warning but continue
                eprintln!(
                    "warning: could not resolve optional output '{}': {}",
                    name, e
                );
            }
        }
    }

    // Emit OutputBound events for method-level outputs (they're already bound at step level,
    // but we record the method-level resolution as well)
    for (name, output) in &normalized.method.outputs {
        let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
        env.payload = serde_json::json!({
            "method_output": name,
            "from": output.from,
        });
        append_event(events_path, &mut env, current_seq)?;
    }

    Ok(())
}
