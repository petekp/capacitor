//! Resume and reconciliation for interrupted method runs.
//!
//! Two-phase protocol:
//! 1. **Replay** — Read `events.ndjson` and project state via `rebuild_state()`.
//! 2. **Reconcile** — Scan the filesystem for persisted artifacts that exist
//!    without corresponding events. Emit missing events for each orphan.
//!
//! After replay+reconciliation, find the first non-terminal phase/step
//! and resume execution from there.

use std::path::Path;

use crate::method_runner::adapters::{InteractiveIO, PromptBuilder, WorkerDispatcher};
use crate::method_runner::definition::{DefinitionLoader, NormalizedDefinitionFile};
use crate::method_runner::events::{
    append_event, make_envelope, read_last_seq, recover_events, MethodEventKind,
};
use crate::method_runner::executor::RunError;
use crate::method_runner::run_status_reporter::{
    phase_started_message, report_status_kind, report_status_message, NoopRunStatusReporter,
    RunStatusEventKind, RunStatusReporter,
};
use crate::method_runner::state::{
    rebuild_state, MethodRunState, PhaseStatus, RunStatus, StepStatus,
};
use crate::method_runner::storage::MethodRunPaths;

// ---------------------------------------------------------------------------
// Reconciliation
// ---------------------------------------------------------------------------

/// Scan for orphan artifacts on disk that have no corresponding events,
/// and emit missing events to close the gap.
///
/// Currently checks:
/// - Handoff artifacts in `artifacts/handoffs/` without a `HandoffIngested` event
/// - Interactive response files without an `InteractiveResponseReceived` event
/// - Synthesis output files without a `SynthesisCompleted` event
fn reconcile(
    paths: &MethodRunPaths,
    events_path: &Path,
    current_seq: &mut u64,
    state: &MethodRunState,
    definition: &NormalizedDefinitionFile,
) -> Result<MethodRunState, RunError> {
    let run_id = &state.run_id;
    let mut emitted_any = false;

    // --- Handoff reconciliation ---
    let handoffs_dir = paths.method_root().join("artifacts").join("handoffs");
    if handoffs_dir.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&handoffs_dir) {
            for entry in entries.flatten() {
                let filename = entry.file_name();
                let filename = filename.to_string_lossy();
                if !filename.ends_with(".md") {
                    continue;
                }

                // Parse filename: phase--step--attempt--worker.md
                let stem = filename.trim_end_matches(".md");
                let parts: Vec<&str> = stem.split("--").collect();
                if parts.len() != 4 {
                    continue;
                }
                let (phase_id, step_id, attempt_str, worker_id) =
                    (parts[0], parts[1], parts[2], parts[3]);
                let attempt: u32 = match attempt_str.parse() {
                    Ok(a) => a,
                    Err(_) => continue,
                };

                // Check if there's already a HandoffIngested event for this combo
                let has_event = state
                    .phases
                    .get(phase_id)
                    .and_then(|p| p.steps.get(step_id))
                    .and_then(|s| s.attempts.get(&attempt))
                    .map(|a| {
                        a.workers
                            .get(worker_id)
                            .map(|w| w.handoff_received)
                            .unwrap_or(false)
                    })
                    .unwrap_or(false);

                if !has_event {
                    // Emit the missing HandoffIngested event
                    let mut env = make_envelope(run_id, MethodEventKind::HandoffIngested);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step_id.to_string());
                    env.attempt = Some(attempt);
                    env.worker_id = Some(worker_id.to_string());
                    env.payload = serde_json::json!({ "reconciled": true });
                    append_event(events_path, &mut env, current_seq)?;
                    emitted_any = true;
                }
            }
        }
    }

    // --- Interactive response reconciliation ---
    // Check for response artifacts in attempt dirs without InteractiveResponseReceived events
    for phase_def in &definition.method.phases {
        for step_def in &phase_def.steps {
            if step_def.action != crate::method_runner::definition::ActionKind::Interactive {
                continue;
            }

            let phase_state = state.phases.get(&phase_def.id);
            let step_state = phase_state.and_then(|p| p.steps.get(&step_def.id));

            // Check if there's an interactive prompt event but no response event
            // We look for the output artifact on disk
            let attempt_dir = paths.attempt_dir(&phase_def.id, &step_def.id, 1);
            for output_def in step_def.outputs.values() {
                let output_path = attempt_dir.join(&output_def.path);
                if output_path.exists() {
                    // Check if the step has an output binding for this already
                    let has_output = step_state
                        .map(|s| s.outputs.contains_key(&output_def.path))
                        .unwrap_or(false);

                    if !has_output {
                        // Emit InteractiveResponseReceived
                        let mut env =
                            make_envelope(run_id, MethodEventKind::InteractiveResponseReceived);
                        env.phase_id = Some(phase_def.id.clone());
                        env.step_id = Some(step_def.id.clone());
                        env.attempt = Some(1);
                        env.payload = serde_json::json!({ "reconciled": true });
                        append_event(events_path, &mut env, current_seq)?;
                        emitted_any = true;
                    }
                }
            }
        }
    }

    // --- Synthesis reconciliation ---
    for phase_def in &definition.method.phases {
        for step_def in &phase_def.steps {
            if step_def.action != crate::method_runner::definition::ActionKind::Synthesis {
                continue;
            }

            let phase_state = state.phases.get(&phase_def.id);
            let step_state = phase_state.and_then(|p| p.steps.get(&step_def.id));

            let attempt_dir = paths.attempt_dir(&phase_def.id, &step_def.id, 1);
            for output_def in step_def.outputs.values() {
                let output_path = attempt_dir.join(&output_def.path);
                if output_path.exists() {
                    let has_output = step_state
                        .map(|s| s.outputs.contains_key(&output_def.path))
                        .unwrap_or(false);

                    if !has_output {
                        // Emit SynthesisCompleted
                        let mut env = make_envelope(run_id, MethodEventKind::SynthesisCompleted);
                        env.phase_id = Some(phase_def.id.clone());
                        env.step_id = Some(step_def.id.clone());
                        env.attempt = Some(1);
                        env.payload = serde_json::json!({ "reconciled": true });
                        append_event(events_path, &mut env, current_seq)?;
                        emitted_any = true;
                    }
                }
            }
        }
    }

    // Re-project if we emitted any reconciliation events
    if emitted_any {
        let events = recover_events(events_path)?;
        let new_state = crate::method_runner::state::project(&events)?;
        Ok(new_state)
    } else {
        Ok(state.clone())
    }
}

// ---------------------------------------------------------------------------
// Resume point detection
// ---------------------------------------------------------------------------

/// Find the first non-terminal phase and step to resume from.
/// Returns `(phase_index, step_index)` or None if all phases are terminal.
fn find_resume_point(
    state: &MethodRunState,
    definition: &NormalizedDefinitionFile,
) -> Option<(usize, usize)> {
    for (pi, phase_def) in definition.method.phases.iter().enumerate() {
        let phase_state = state.phases.get(&phase_def.id);
        let phase_status = phase_state
            .map(|p| p.status)
            .unwrap_or(PhaseStatus::Pending);

        match phase_status {
            PhaseStatus::Completed | PhaseStatus::Skipped => continue,
            PhaseStatus::Failed | PhaseStatus::Blocked => {
                // Blocked/failed phase — resume from first non-terminal step
                if let Some(ps) = phase_state {
                    for (si, step_def) in phase_def.steps.iter().enumerate() {
                        let step_status = ps
                            .steps
                            .get(&step_def.id)
                            .map(|s| s.status)
                            .unwrap_or(StepStatus::Pending);
                        match step_status {
                            StepStatus::Completed => continue,
                            _ => return Some((pi, si)),
                        }
                    }
                }
                return Some((pi, 0));
            }
            PhaseStatus::Running => {
                // Running phase — find the first non-complete step
                if let Some(ps) = phase_state {
                    for (si, step_def) in phase_def.steps.iter().enumerate() {
                        let step_status = ps
                            .steps
                            .get(&step_def.id)
                            .map(|s| s.status)
                            .unwrap_or(StepStatus::Pending);
                        match step_status {
                            StepStatus::Completed => continue,
                            _ => return Some((pi, si)),
                        }
                    }
                }
                // All steps complete but phase still Running — gate may need eval
                return Some((pi, phase_def.steps.len()));
            }
            PhaseStatus::Pending => return Some((pi, 0)),
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Resume entrypoint
// ---------------------------------------------------------------------------

/// Resume an interrupted method run.
///
/// 1. Rebuild state from events (replay)
/// 2. Reconcile orphan artifacts
/// 3. Find resume point
/// 4. Re-execute from resume point using the same adapters
pub fn resume_run(
    execution_root: &Path,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
) -> Result<MethodRunState, RunError> {
    resume_run_with_reporter(
        execution_root,
        prompt_builder,
        dispatcher,
        interactive_io,
        &NoopRunStatusReporter,
    )
}

pub fn resume_run_with_reporter(
    execution_root: &Path,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
    reporter: &dyn RunStatusReporter,
) -> Result<MethodRunState, RunError> {
    let paths = MethodRunPaths::new(execution_root);
    let events_path = paths.events_log();

    // Phase 1: Replay — rebuild state from events
    let state = rebuild_state(&events_path)?;

    // If no events exist, this is not a resumable run
    if state.run_id.is_empty() {
        return Err(RunError::IoError(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "no events found — nothing to resume",
        )));
    }

    // Load definition from snapshot
    let definition = DefinitionLoader::load(&paths.definition_snapshot())?;

    // Get current sequence number
    let mut current_seq = read_last_seq(&events_path)?;

    // Phase 2: Reconcile orphan artifacts
    let state = reconcile(&paths, &events_path, &mut current_seq, &state, &definition)?;

    // If run is already complete, write state.json (may have been deleted) and return
    if state.status == RunStatus::Completed {
        crate::method_runner::state::write_state_atomic(&paths.state_json(), &state)
            .map_err(RunError::IoError)?;
        return Ok(state);
    }

    // Phase 3: Find resume point
    let resume_point = find_resume_point(&state, &definition);
    if resume_point.is_none() {
        // All phases terminal — finalize run if not already
        if state.status == RunStatus::Running {
            let mut env = make_envelope(&state.run_id, MethodEventKind::RunCompleted);
            append_event(&events_path, &mut env, &mut current_seq)?;
        }
        let events = recover_events(&events_path)?;
        let final_state = crate::method_runner::state::project(&events)?;
        crate::method_runner::state::write_state_atomic(&paths.state_json(), &final_state)
            .map_err(RunError::IoError)?;
        report_status_kind(reporter, RunStatusEventKind::Complete);
        return Ok(final_state);
    }

    let (phase_idx, _step_idx) = resume_point.unwrap();
    // If run status is not Running, transition it
    if state.status == RunStatus::Created || state.status == RunStatus::Blocked {
        // Created->Running or Blocked->Running are both legal transitions
        let mut env = make_envelope(&state.run_id, MethodEventKind::RunStarted);
        append_event(&events_path, &mut env, &mut current_seq)?;
        report_status_message(reporter, RunStatusEventKind::Start, "Run started");
    }
    let recovered_phase = &definition.method.phases[phase_idx];
    report_status_message(
        reporter,
        RunStatusEventKind::Heartbeat,
        phase_started_message(&recovered_phase.title),
    );
    let mut suppress_phase_started_heartbeat = true;

    // Phase 4: Continue execution from resume point
    // For each phase from resume_point forward, execute non-terminal steps
    let run_id = state.run_id.clone();

    // Acquire lock
    let _lock = crate::method_runner::storage::acquire_lock(
        &paths.lock_file(),
        std::time::Duration::from_secs(10),
    )?;

    for (pi, phase_def) in definition.method.phases.iter().enumerate() {
        if pi < phase_idx {
            continue; // Skip completed phases
        }

        // Re-project state at the start of each phase iteration
        let current_events = recover_events(&events_path)?;
        let current_state = crate::method_runner::state::project(&current_events)?;
        current_seq = current_state.seq;

        let phase_status = current_state
            .phases
            .get(&phase_def.id)
            .map(|p| p.status)
            .unwrap_or(PhaseStatus::Pending);

        if phase_status == PhaseStatus::Completed || phase_status == PhaseStatus::Skipped {
            continue;
        }

        // If phase hasn't started, emit PhaseStarted
        if phase_status == PhaseStatus::Pending {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseStarted);
            env.phase_id = Some(phase_def.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }
        if suppress_phase_started_heartbeat {
            suppress_phase_started_heartbeat = false;
        } else if phase_status == PhaseStatus::Pending {
            report_status_message(
                reporter,
                RunStatusEventKind::Heartbeat,
                phase_started_message(&phase_def.title),
            );
        }

        // Execute non-terminal steps
        for step_def in &phase_def.steps {
            // Re-project to get latest state
            let current_events = recover_events(&events_path)?;
            let current_state = crate::method_runner::state::project(&current_events)?;
            current_seq = current_state.seq;

            let step_status = current_state
                .phases
                .get(&phase_def.id)
                .and_then(|p| p.steps.get(&step_def.id))
                .map(|s| s.status)
                .unwrap_or(StepStatus::Pending);

            if step_status == StepStatus::Completed {
                continue; // Already done
            }

            // Execute this step
            if let Err(error) = crate::method_runner::executor::execute_step_public_with_reporter(
                &paths,
                &events_path,
                &run_id,
                &mut current_seq,
                &phase_def.id,
                step_def,
                prompt_builder,
                dispatcher,
                interactive_io,
                reporter,
            ) {
                report_status_kind(reporter, RunStatusEventKind::Fail);
                return Err(error);
            }
        }

        // Evaluate gate if present
        if let Some(ref gate) = phase_def.gate {
            let current_events = recover_events(&events_path)?;
            let current_state = crate::method_runner::state::project(&current_events)?;
            current_seq = current_state.seq;

            report_status_message(
                reporter,
                RunStatusEventKind::Heartbeat,
                "Waiting for checkpoint",
            );
            let outcome = crate::method_runner::executor::evaluate_gate(
                gate,
                phase_def,
                &current_state,
                &paths,
                interactive_io,
            );

            // Emit GateEvaluated
            {
                let mut env = make_envelope(&run_id, MethodEventKind::GateEvaluated);
                env.phase_id = Some(phase_def.id.clone());
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
                crate::method_runner::executor::GateOutcome::Approved => {}
                other => {
                    let reason = match &other {
                        crate::method_runner::executor::GateOutcome::Rejected => {
                            "gate rejected".to_string()
                        }
                        crate::method_runner::executor::GateOutcome::ValidationFailed {
                            reason,
                        } => format!("validation failed: {}", reason),
                        crate::method_runner::executor::GateOutcome::TimedOut => {
                            "gate timed out".to_string()
                        }
                        crate::method_runner::executor::GateOutcome::Waiting => {
                            "pipeline_clean requires pipeline-execute, not implemented in v1"
                                .to_string()
                        }
                        _ => unreachable!(),
                    };

                    let mut env = make_envelope(&run_id, MethodEventKind::PhaseBlocked);
                    env.phase_id = Some(phase_def.id.clone());
                    env.payload = serde_json::json!({ "reason": reason });
                    append_event(&events_path, &mut env, &mut current_seq)?;

                    report_status_kind(reporter, RunStatusEventKind::Fail);
                    return Err(RunError::PhaseGateBlocked {
                        phase_id: phase_def.id.clone(),
                        gate_id: gate.id.clone(),
                        reason,
                    });
                }
            }
        }

        // PhaseCompleted
        {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseCompleted);
            env.phase_id = Some(phase_def.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }
        if let Some(next_phase) = definition.method.phases.get(pi + 1) {
            report_status_kind(reporter, RunStatusEventKind::AdvancePhase);
            report_status_message(
                reporter,
                RunStatusEventKind::Heartbeat,
                phase_started_message(&next_phase.title),
            );
            suppress_phase_started_heartbeat = true;
        }
    }

    // Resolve method-level outputs
    {
        let current_events = recover_events(&events_path)?;
        let current_state = crate::method_runner::state::project(&current_events)?;
        current_seq = current_state.seq;

        for (name, output) in &definition.method.outputs {
            match crate::method_runner::output::resolve_and_write_output(
                &paths,
                name,
                &output.from,
                &current_state,
                &definition.method,
            ) {
                Ok(_) => {}
                Err(e) => {
                    if output.required {
                        report_status_kind(reporter, RunStatusEventKind::Fail);
                        return Err(RunError::ResolveError(e));
                    }
                }
            }
        }
    }

    // RunCompleted
    {
        let mut env = make_envelope(&run_id, MethodEventKind::RunCompleted);
        append_event(&events_path, &mut env, &mut current_seq)?;
    }
    report_status_kind(reporter, RunStatusEventKind::Complete);

    // Final state projection
    let events = recover_events(&events_path)?;
    let final_state = crate::method_runner::state::project(&events)?;
    crate::method_runner::state::write_state_atomic(&paths.state_json(), &final_state)
        .map_err(RunError::IoError)?;

    Ok(final_state)
}
