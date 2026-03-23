//! Run executor for the method runner.
//!
//! Orchestrates a complete method run: definition normalization, event
//! emission, serial phase/step execution with fake adapters, handoff
//! ingestion, output binding, and state projection.

use std::collections::BTreeMap;
use std::path::Path;

use crate::method_runner::adapters::{
    AdapterError, InteractiveIO, InteractivePrompt, PromptBuildRequest, PromptBuilder,
    WorkerDispatchRequest, WorkerDispatcher,
};
use crate::method_runner::definition::{
    write_snapshot, write_step_json, ActionKind, DefinitionSource, NormalizationError,
    NormalizedDefinitionFile, NormalizedStep, Normalizer, StepActionConfig,
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

    // 10. Execute phases serially
    for phase in &normalized.method.phases {
        // PhaseStarted
        {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseStarted);
            env.phase_id = Some(phase.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }

        // Execute steps serially
        for step in &phase.steps {
            // Check for pipeline_execute — blocked
            if step.action == ActionKind::PipelineExecute {
                // Emit StepBlocked event before returning error
                let mut env = make_envelope(&run_id, MethodEventKind::StepBlocked);
                env.phase_id = Some(phase.id.clone());
                env.step_id = Some(step.id.clone());
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

        // PhaseCompleted
        {
            let mut env = make_envelope(&run_id, MethodEventKind::PhaseCompleted);
            env.phase_id = Some(phase.id.clone());
            append_event(&events_path, &mut env, &mut current_seq)?;
        }
    }

    // 11. Resolve method-level outputs
    resolve_method_outputs(&paths, &events_path, &run_id, &mut current_seq, &normalized)?;

    // 12. RunCompleted
    {
        let mut env = make_envelope(&run_id, MethodEventKind::RunCompleted);
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
// Dispatch step execution
// ---------------------------------------------------------------------------

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

    let attempt: u32 = 1;
    let worker_id = "primary";

    // Create attempt dir and worker relay dir
    let attempt_dir = paths.attempt_dir(phase_id, &step.id, attempt);
    std::fs::create_dir_all(&attempt_dir)?;
    let relay_root = paths.worker_relay_root(phase_id, &step.id, attempt, worker_id);
    std::fs::create_dir_all(&relay_root)?;

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

    // Extract instructions for prompt builder
    let instructions = match &step.config {
        StepActionConfig::Dispatch { instructions } => instructions.clone(),
        _ => String::new(),
    };

    // Build prompt
    let prompt_request = PromptBuildRequest {
        phase_id: phase_id.to_string(),
        step_id: step.id.clone(),
        attempt,
        relay_root: relay_root.clone(),
        instructions,
    };
    prompt_builder.build_prompt(&prompt_request)?;

    // AttemptStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // WorkerDispatched
    {
        let mut env = make_envelope(run_id, MethodEventKind::WorkerDispatched);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.worker_id = Some(worker_id.to_string());
        append_event(events_path, &mut env, current_seq)?;
    }

    // Dispatch worker
    let dispatch_request = WorkerDispatchRequest {
        phase_id: phase_id.to_string(),
        step_id: step.id.clone(),
        attempt,
        worker_id: worker_id.to_string(),
        relay_root: relay_root.clone(),
    };
    dispatcher.dispatch(&dispatch_request)?;

    // WorkerCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::WorkerCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.worker_id = Some(worker_id.to_string());
        append_event(events_path, &mut env, current_seq)?;
    }

    // Look for handoff at relay root (HANDOFF.md or handoff.md)
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
        {
            let mut env = make_envelope(run_id, MethodEventKind::HandoffIngested);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.worker_id = Some(worker_id.to_string());
            append_event(events_path, &mut env, current_seq)?;
        }
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
                    "worker_id": worker_id,
                }),
            );

            // OutputBound event
            let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.worker_id = Some(worker_id.to_string());
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
            "worker_id": worker_id,
            "status": "completed",
            "started_at": chrono::Utc::now().to_rfc3339(),
            "completed_at": chrono::Utc::now().to_rfc3339(),
        });
        let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("attempt.json"), json)?;
    }

    // AttemptCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
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

    // Write stub output artifacts for each declared output
    for output_def in step.outputs.values() {
        let output_path = attempt_dir.join(&output_def.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let instructions = match &step.config {
            StepActionConfig::Synthesis { instructions, .. } => instructions.clone(),
            _ => String::new(),
        };
        let content = format!(
            "# Synthesized\n\nInstructions: {}\n\n(stub output from tracer bullet)\n",
            instructions
        );
        std::fs::write(&output_path, content)?;
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

    // SynthesisCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::SynthesisCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
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

    // AttemptCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
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

    // AttemptStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // Extract prompt from interactive config
    let prompt_message = match &step.config {
        StepActionConfig::Interactive { prompt, .. } => prompt.clone(),
        _ => String::new(),
    };

    // InteractivePrompted
    {
        let mut env = make_envelope(run_id, MethodEventKind::InteractivePrompted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({ "prompt": prompt_message });
        // No worker_id for interactive
        append_event(events_path, &mut env, current_seq)?;
    }

    // Emit prompt and capture response via InteractiveIO
    interactive_io.emit_prompt(&InteractivePrompt {
        message: prompt_message,
    });
    let response = interactive_io.capture_response();

    // InteractiveResponseReceived
    {
        let mut env = make_envelope(run_id, MethodEventKind::InteractiveResponseReceived);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({ "response_length": response.body.len() });
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

    // AttemptCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
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
