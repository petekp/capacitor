//! Run executor for the method runner.
//!
//! Orchestrates a complete method run: definition normalization, event
//! emission, serial phase/step execution with fake adapters, handoff
//! ingestion, output binding, and state projection.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Instant;

use crate::domain::{CheckpointKind, MediaArtifact, MediaArtifactType, MermaidSource};
use crate::method_runner::adapters::{
    validate_interactive_response, AdapterError, GateCheckpointContext, InteractiveIO,
    InteractivePrompt, PromptBuildRequest, PromptBuilder, WorkerDispatchRequest, WorkerDispatcher,
};
use crate::method_runner::checkpoint_manifest::CheckpointManifest;
use crate::method_runner::definition::{
    write_snapshot, write_step_json, ActionKind, CompletionPolicy, DefinitionSource, ExecutionMode,
    NormalizationError, NormalizedDefinitionFile, NormalizedGate, NormalizedPhase, NormalizedStep,
    NormalizedWorkerSpec, Normalizer, StepActionConfig,
};
use crate::method_runner::events::{append_event, make_envelope, AppendError, MethodEventKind};
use crate::method_runner::handoff::{ingest_handoff, HandoffParseError};
use crate::method_runner::output::{resolve_and_write_output, ResolveError};
use crate::method_runner::run_status_reporter::{
    phase_started_message, report_status_kind, report_status_message, NoopRunStatusReporter,
    RunStatusEventKind, RunStatusReporter,
};
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
}

include!("executor_gate_support.rs");

struct ExecutionContext<'a> {
    paths: &'a MethodRunPaths,
    events_path: &'a Path,
    run_id: &'a str,
    current_seq: &'a mut u64,
    normalized: &'a NormalizedDefinitionFile,
    run_start: Instant,
    prompt_builder: &'a dyn PromptBuilder,
    dispatcher: &'a dyn WorkerDispatcher,
    interactive_io: &'a dyn InteractiveIO,
    reporter: &'a dyn RunStatusReporter,
}

/// Caller-provided execution inputs for a single step.
pub struct StepExecutionContext<'a> {
    pub paths: &'a MethodRunPaths,
    pub events_path: &'a Path,
    pub run_id: &'a str,
    pub current_seq: &'a mut u64,
    pub phase_id: &'a str,
    pub step_definition: &'a NormalizedStep,
    pub prompt_builder: &'a dyn PromptBuilder,
    pub dispatcher: &'a dyn WorkerDispatcher,
    pub interactive_io: &'a dyn InteractiveIO,
}

struct ReportedStepExecutionContext<'a> {
    step: StepExecutionContext<'a>,
    reporter: &'a dyn RunStatusReporter,
}

struct DispatchContext<'a> {
    execution: ReportedStepExecutionContext<'a>,
    workers: &'a [NormalizedWorkerSpec],
    step_instructions: &'a str,
    attempt: u32,
    prior_failure: &'a str,
}

struct AttemptContext<'a> {
    events_path: &'a Path,
    run_id: &'a str,
    current_seq: &'a mut u64,
    phase_id: &'a str,
    step_id: &'a str,
    attempt: u32,
    attempt_start: Instant,
}

impl<'a> ExecutionContext<'a> {
    fn step_context<'b>(
        &'b mut self,
        phase_id: &'b str,
        step_definition: &'b NormalizedStep,
    ) -> ReportedStepExecutionContext<'b> {
        ReportedStepExecutionContext {
            step: StepExecutionContext {
                paths: self.paths,
                events_path: self.events_path,
                run_id: self.run_id,
                current_seq: &mut *self.current_seq,
                phase_id,
                step_definition,
                prompt_builder: self.prompt_builder,
                dispatcher: self.dispatcher,
                interactive_io: self.interactive_io,
            },
            reporter: self.reporter,
        }
    }
}

impl<'a> StepExecutionContext<'a> {
    fn with_reporter(
        self,
        reporter: &'a dyn RunStatusReporter,
    ) -> ReportedStepExecutionContext<'a> {
        ReportedStepExecutionContext {
            step: self,
            reporter,
        }
    }
}

impl<'a> ReportedStepExecutionContext<'a> {
    fn reborrow<'b>(&'b mut self) -> ReportedStepExecutionContext<'b> {
        ReportedStepExecutionContext {
            step: StepExecutionContext {
                paths: self.step.paths,
                events_path: self.step.events_path,
                run_id: self.step.run_id,
                current_seq: &mut *self.step.current_seq,
                phase_id: self.step.phase_id,
                step_definition: self.step.step_definition,
                prompt_builder: self.step.prompt_builder,
                dispatcher: self.step.dispatcher,
                interactive_io: self.step.interactive_io,
            },
            reporter: self.reporter,
        }
    }

    fn dispatch_context<'b>(
        &'b mut self,
        workers: &'b [NormalizedWorkerSpec],
        step_instructions: &'b str,
        attempt: u32,
        prior_failure: &'b str,
    ) -> DispatchContext<'b> {
        DispatchContext {
            execution: self.reborrow(),
            workers,
            step_instructions,
            attempt,
            prior_failure,
        }
    }

    fn attempt_context<'b>(
        &'b mut self,
        attempt: u32,
        attempt_start: Instant,
    ) -> AttemptContext<'b> {
        AttemptContext {
            events_path: self.step.events_path,
            run_id: self.step.run_id,
            current_seq: &mut *self.step.current_seq,
            phase_id: self.step.phase_id,
            step_id: self.step.step_definition.id.as_str(),
            attempt,
            attempt_start,
        }
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
    execute_run_with_reporter(
        source,
        prompt_builder,
        dispatcher,
        interactive_io,
        &NoopRunStatusReporter,
    )
}

/// Execute a complete method run and mirror progress through a reporter seam.
pub fn execute_run_with_reporter(
    source: &DefinitionSource,
    prompt_builder: &dyn PromptBuilder,
    dispatcher: &dyn WorkerDispatcher,
    interactive_io: &dyn InteractiveIO,
    reporter: &dyn RunStatusReporter,
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
    report_status_message(reporter, RunStatusEventKind::Start, "Run started");

    // 10. Execute phases
    let mut execution_context = ExecutionContext {
        paths: &paths,
        events_path: &events_path,
        run_id: &run_id,
        current_seq: &mut current_seq,
        normalized: &normalized,
        run_start: Instant::now(),
        prompt_builder,
        dispatcher,
        interactive_io,
        reporter,
    };
    if let Some(early_state) = execute_all_phases(&mut execution_context)? {
        return Ok(early_state);
    }

    // 11. Resolve method-level outputs
    if let Err(error) = resolve_method_outputs(&mut execution_context) {
        report_status_kind(reporter, RunStatusEventKind::Fail);
        return Err(error);
    }

    // 12. RunCompleted with summary payload
    {
        let summary = build_run_summary(&events_path, &normalized, execution_context.run_start)?;
        let mut env = make_envelope(&run_id, MethodEventKind::RunCompleted);
        env.payload = summary;
        append_event(&events_path, &mut env, &mut current_seq)?;
    }
    report_status_kind(reporter, RunStatusEventKind::Complete);

    // 13. Project state from events and write state.json
    let events = crate::method_runner::events::recover_events(&events_path)?;
    let state = project(&events)?;
    write_state_atomic(&paths.state_json(), &state).map_err(RunError::IoError)?;

    // 14. Lock released on drop
    Ok(state)
}

/// Execute all phases in the method definition. Returns `Ok(Some(state))`
/// for early termination from a parallel phase (blocked/failed), or `Ok(None)` on success.
fn execute_all_phases(ctx: &mut ExecutionContext<'_>) -> Result<Option<MethodRunState>, RunError> {
    let normalized = ctx.normalized;
    let mut suppress_phase_started_heartbeat = false;
    for (phase_index, phase) in normalized.method.phases.iter().enumerate() {
        // PhaseStarted
        {
            let mut env = make_envelope(ctx.run_id, MethodEventKind::PhaseStarted);
            env.phase_id = Some(phase.id.clone());
            append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
        }
        if suppress_phase_started_heartbeat {
            suppress_phase_started_heartbeat = false;
        } else {
            report_status_message(
                ctx.reporter,
                RunStatusEventKind::Heartbeat,
                phase_started_message(&phase.title),
            );
        }

        if phase.execution == ExecutionMode::Parallel {
            if let Some(early_state) = execute_parallel_phase_steps(ctx, phase)? {
                return Ok(Some(early_state));
            }
        } else {
            execute_serial_phase_steps(ctx, phase)?;
        }

        // Evaluate phase gate (if present) after all steps complete
        if let Some(ref gate) = phase.gate {
            if let Some(early_state) = emit_and_enforce_gate(ctx, phase, gate)? {
                return Ok(Some(early_state));
            }
        }

        // PhaseCompleted
        {
            let mut env = make_envelope(ctx.run_id, MethodEventKind::PhaseCompleted);
            env.phase_id = Some(phase.id.clone());
            append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
        }
        if let Some(next_phase) = normalized.method.phases.get(phase_index + 1) {
            report_status_kind(ctx.reporter, RunStatusEventKind::AdvancePhase);
            report_status_message(
                ctx.reporter,
                RunStatusEventKind::Heartbeat,
                phase_started_message(&next_phase.title),
            );
            suppress_phase_started_heartbeat = true;
        }
    }
    Ok(None)
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

/// Execute all steps in a parallel phase. Returns `Ok(Some(state))` for early
/// termination (blocked/failed), or `Ok(None)` when all steps succeeded.
fn execute_parallel_phase_steps(
    ctx: &mut ExecutionContext<'_>,
    phase: &NormalizedPhase,
) -> Result<Option<MethodRunState>, RunError> {
    let mut step_results: Vec<(&NormalizedStep, Result<(), RunError>)> = Vec::new();
    for step in &phase.steps {
        let result = if step.action == ActionKind::PipelineExecute {
            emit_pipeline_blocked(
                ctx.events_path,
                ctx.run_id,
                &mut *ctx.current_seq,
                &phase.id,
                &step.id,
            )?;
            Err(RunError::PipelineExecuteBlocked(step.id.clone()))
        } else {
            let mut step_context = ctx.step_context(&phase.id, step);
            execute_step(&mut step_context)
        };
        step_results.push((step, result));
    }

    let mut any_failed = false;
    let mut any_blocked = false;
    for (_step, result) in &step_results {
        match result {
            Ok(()) => {}
            Err(RunError::StepBlocked { .. }) | Err(RunError::PipelineExecuteBlocked(_)) => {
                any_blocked = true;
            }
            Err(_) => {
                any_failed = true;
            }
        }
    }

    if any_blocked {
        return emit_parallel_phase_terminal(
            ctx,
            &phase.id,
            "one or more parallel steps blocked",
            MethodEventKind::PhaseBlocked,
            MethodEventKind::RunBlocked,
        );
    }
    if any_failed {
        return emit_parallel_phase_terminal(
            ctx,
            &phase.id,
            "one or more parallel steps failed",
            MethodEventKind::PhaseFailed,
            MethodEventKind::RunFailed,
        );
    }

    Ok(None)
}

/// Emit phase-terminal + run-terminal events for a parallel phase that
/// blocked or failed, then project and return the state for early exit.
fn emit_parallel_phase_terminal(
    ctx: &mut ExecutionContext<'_>,
    phase_id: &str,
    reason: &str,
    phase_event: MethodEventKind,
    run_event: MethodEventKind,
) -> Result<Option<MethodRunState>, RunError> {
    let mut env = make_envelope(ctx.run_id, phase_event);
    env.phase_id = Some(phase_id.to_string());
    env.payload = serde_json::json!({ "reason": reason });
    append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;

    {
        let summary = build_run_summary(ctx.events_path, ctx.normalized, ctx.run_start)?;
        let mut env = make_envelope(ctx.run_id, run_event);
        env.payload = summary;
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }
    report_status_kind(ctx.reporter, RunStatusEventKind::Fail);

    let events = crate::method_runner::events::recover_events(ctx.events_path)?;
    let state = project(&events)?;
    write_state_atomic(&ctx.paths.state_json(), &state).map_err(RunError::IoError)?;
    Ok(Some(state))
}

/// Execute steps serially within a phase. Returns early on blocked or failure.
fn execute_serial_phase_steps(
    ctx: &mut ExecutionContext<'_>,
    phase: &NormalizedPhase,
) -> Result<(), RunError> {
    for step in &phase.steps {
        if step.action == ActionKind::PipelineExecute {
            emit_pipeline_blocked(
                ctx.events_path,
                ctx.run_id,
                &mut *ctx.current_seq,
                &phase.id,
                &step.id,
            )?;
            report_status_kind(ctx.reporter, RunStatusEventKind::Fail);
            return Err(RunError::PipelineExecuteBlocked(step.id.clone()));
        }

        let mut step_context = ctx.step_context(&phase.id, step);
        if let Err(error) = execute_step(&mut step_context) {
            report_status_kind(ctx.reporter, RunStatusEventKind::Fail);
            return Err(error);
        }
    }
    Ok(())
}

fn emit_pipeline_blocked(
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step_id: &str,
) -> Result<(), RunError> {
    let mut env = make_envelope(run_id, MethodEventKind::StepBlocked);
    env.phase_id = Some(phase_id.to_string());
    env.step_id = Some(step_id.to_string());
    env.payload = serde_json::json!({
        "blocked_reason": {
            "category": "pipeline_blocked",
            "details": "pipeline_execute not supported in v1"
        }
    });
    append_event(events_path, &mut env, current_seq)?;
    Ok(())
}

/// Evaluate a phase gate, emit the GateEvaluated event, and block if not approved.
fn emit_and_enforce_gate(
    ctx: &mut ExecutionContext<'_>,
    phase: &NormalizedPhase,
    gate: &NormalizedGate,
) -> Result<Option<MethodRunState>, RunError> {
    let current_events = crate::method_runner::events::recover_events(ctx.events_path)?;
    let current_state = project(&current_events)?;

    report_status_message(
        ctx.reporter,
        RunStatusEventKind::Heartbeat,
        "Waiting for checkpoint",
    );
    let outcome = evaluate_gate(gate, phase, &current_state, ctx.paths, ctx.interactive_io);

    // Emit GateEvaluated event
    {
        let mut env = make_envelope(ctx.run_id, MethodEventKind::GateEvaluated);
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
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }

    if outcome == GateOutcome::Approved {
        return Ok(None);
    }

    let reason = gate_outcome_reason(&outcome);

    {
        let mut env = make_envelope(ctx.run_id, MethodEventKind::PhaseBlocked);
        env.phase_id = Some(phase.id.clone());
        env.payload = serde_json::json!({ "reason": reason });
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }

    {
        let summary = build_run_summary(ctx.events_path, ctx.normalized, ctx.run_start)?;
        let mut env = make_envelope(ctx.run_id, MethodEventKind::RunBlocked);
        env.payload = summary;
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }
    report_status_message(
        ctx.reporter,
        RunStatusEventKind::Pause,
        format!("Run blocked: {reason}"),
    );

    let events = crate::method_runner::events::recover_events(ctx.events_path)?;
    let state = project(&events)?;
    write_state_atomic(&ctx.paths.state_json(), &state).map_err(RunError::IoError)?;
    Ok(Some(state))
}

/// Public wrapper for `execute_step` used by the resume module.
pub fn execute_step_public(context: StepExecutionContext<'_>) -> Result<(), RunError> {
    execute_step_public_with_reporter(context, &NoopRunStatusReporter)
}

pub(crate) fn execute_step_public_with_reporter(
    context: StepExecutionContext<'_>,
    reporter: &dyn RunStatusReporter,
) -> Result<(), RunError> {
    execute_step_public_with_reporter_from_attempt(context, reporter, 1)
}

pub(crate) fn execute_step_public_with_reporter_from_attempt(
    context: StepExecutionContext<'_>,
    reporter: &dyn RunStatusReporter,
    first_attempt: u32,
) -> Result<(), RunError> {
    let step = context.step_definition;
    let mut context = context.with_reporter(reporter);

    // Check for pipeline_execute at the public boundary
    if step.action == ActionKind::PipelineExecute {
        let mut env = make_envelope(context.step.run_id, MethodEventKind::StepBlocked);
        env.phase_id = Some(context.step.phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(
            context.step.events_path,
            &mut env,
            &mut *context.step.current_seq,
        )?;
        return Err(RunError::PipelineExecuteBlocked(step.id.clone()));
    }
    execute_step_with_first_attempt(&mut context, first_attempt)
}

fn execute_step(ctx: &mut ReportedStepExecutionContext<'_>) -> Result<(), RunError> {
    execute_step_with_first_attempt(ctx, 1)
}

fn execute_step_with_first_attempt(
    ctx: &mut ReportedStepExecutionContext<'_>,
    first_attempt: u32,
) -> Result<(), RunError> {
    match ctx.step.step_definition.action {
        ActionKind::Dispatch => execute_dispatch_step(ctx, first_attempt),
        ActionKind::Synthesis => execute_synthesis_step(
            ctx.step.paths,
            ctx.step.events_path,
            ctx.step.run_id,
            &mut *ctx.step.current_seq,
            ctx.step.phase_id,
            ctx.step.step_definition,
            first_attempt,
        ),
        ActionKind::Interactive => execute_interactive_step(ctx, first_attempt),
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

fn execute_dispatch_step(
    ctx: &mut ReportedStepExecutionContext<'_>,
    first_attempt: u32,
) -> Result<(), RunError> {
    let paths = ctx.step.paths;
    let events_path = ctx.step.events_path;
    let run_id = ctx.step.run_id;
    let phase_id = ctx.step.phase_id;
    let step = ctx.step.step_definition;

    // StepStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
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

    // Retry loop: max_attempts attempts, starting after any previous review round.
    let last_attempt = first_attempt.saturating_add(step.max_attempts.saturating_sub(1));
    for attempt in first_attempt..=last_attempt {
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
            append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
        }

        // Dispatch all workers in this attempt
        let outcome = {
            let mut dispatch_context =
                ctx.dispatch_context(&workers, &step_instructions, attempt, &last_failure_reason);
            dispatch_attempt_workers(&mut dispatch_context)?
        };

        let elapsed_ms = attempt_start.elapsed().as_millis() as u64;

        match outcome {
            AttemptOutcome::Success => {
                // Evaluate completion policy and bind outputs
                bind_attempt_outputs(
                    paths,
                    events_path,
                    run_id,
                    &mut *ctx.step.current_seq,
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
                    append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
                }

                // StepCompleted
                {
                    let mut env = make_envelope(run_id, MethodEventKind::StepCompleted);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
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
                    append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
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
        append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
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
fn dispatch_attempt_workers(ctx: &mut DispatchContext<'_>) -> Result<AttemptOutcome, RunError> {
    let paths = ctx.execution.step.paths;
    let events_path = ctx.execution.step.events_path;
    let run_id = ctx.execution.step.run_id;
    let phase_id = ctx.execution.step.phase_id;
    let step = ctx.execution.step.step_definition;
    let prompt_builder = ctx.execution.step.prompt_builder;
    let dispatcher = ctx.execution.step.dispatcher;
    let reporter = ctx.execution.reporter;
    let attempt = ctx.attempt;
    let workers = ctx.workers;
    let step_instructions = ctx.step_instructions;
    let prior_failure = ctx.prior_failure;

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

        // Check for context.json in the execution root (written by Swift coordinator)
        let context_path = paths.root().join("context.json");
        let context_file = if context_path.exists() {
            Some(context_path)
        } else {
            None
        };

        let prompt_request = PromptBuildRequest {
            phase_id: phase_id.to_string(),
            step_id: step.id.clone(),
            attempt,
            relay_root: relay_root.clone(),
            instructions: full_instructions,
            template: step.template.clone(),
            skills: merged_skills,
            context_file,
        };
        report_status_message(reporter, RunStatusEventKind::Heartbeat, "Composing prompt");
        let prompt_result = prompt_builder.build_prompt(&prompt_request)?;

        // WorkerDispatched
        {
            let mut env = make_envelope(run_id, MethodEventKind::WorkerDispatched);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.worker_id = Some(worker_id.clone());
            append_event(events_path, &mut env, &mut *ctx.execution.step.current_seq)?;
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
        report_status_message(reporter, RunStatusEventKind::Heartbeat, "Dispatching Codex");
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
                    append_event(events_path, &mut env, &mut *ctx.execution.step.current_seq)?;
                } else {
                    // WorkerFailed (non-zero exit)
                    let mut env = make_envelope(run_id, MethodEventKind::WorkerFailed);
                    env.phase_id = Some(phase_id.to_string());
                    env.step_id = Some(step.id.clone());
                    env.attempt = Some(attempt);
                    env.worker_id = Some(worker_id.clone());
                    env.payload = serde_json::json!({ "exit_code": result.exit_code });
                    append_event(events_path, &mut env, &mut *ctx.execution.step.current_seq)?;
                }

                // Ingest handoff if present (even for failed workers — we want the data)
                let repo_handoffs_dir = paths.root().join("handoffs");
                let handoff_path = find_handoff(&relay_root, &[repo_handoffs_dir.as_path()]);
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
                    append_event(events_path, &mut env, &mut *ctx.execution.step.current_seq)?;
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
                append_event(events_path, &mut env, &mut *ctx.execution.step.current_seq)?;

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

include!("executor_step_support.rs");

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
    first_attempt: u32,
) -> Result<(), RunError> {
    let attempt = first_attempt;
    let (attempt_dir, attempt_start) = emit_step_and_attempt_start(
        paths,
        events_path,
        run_id,
        current_seq,
        phase_id,
        step,
        attempt,
    )?;

    // SynthesisStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::SynthesisStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    // Resolve declared inputs and write output artifacts
    let resolved_inputs = resolve_step_inputs(events_path, &step.inputs)?;
    write_synthesis_output_artifacts(&attempt_dir, step, &resolved_inputs)?;

    // SynthesisCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::SynthesisCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }

    emit_output_bindings_and_complete(
        &attempt_dir,
        events_path,
        run_id,
        current_seq,
        phase_id,
        step,
        attempt,
        attempt_start,
        "synthesis",
    )
}

// ---------------------------------------------------------------------------
// Interactive step execution
// ---------------------------------------------------------------------------

fn execute_interactive_step(
    ctx: &mut ReportedStepExecutionContext<'_>,
    first_attempt: u32,
) -> Result<(), RunError> {
    let paths = ctx.step.paths;
    let events_path = ctx.step.events_path;
    let run_id = ctx.step.run_id;
    let phase_id = ctx.step.phase_id;
    let step = ctx.step.step_definition;

    let attempt = first_attempt;
    let (attempt_dir, attempt_start) = emit_step_and_attempt_start(
        paths,
        events_path,
        run_id,
        &mut *ctx.step.current_seq,
        phase_id,
        step,
        attempt,
    )?;

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
        append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
    }

    // Emit prompt and capture response via InteractiveIO
    ctx.step.interactive_io.emit_prompt(&InteractivePrompt {
        message: prompt_message,
    });
    let response = ctx.step.interactive_io.capture_response();

    // Validate response against declared response_type
    if !response_type.is_empty() {
        if let Err(validation_err) = validate_interactive_response(&response_type, &response.body) {
            let mut attempt_context = ctx.attempt_context(attempt, attempt_start);
            emit_interactive_validation_failure(&mut attempt_context, &validation_err)?;
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
        append_event(events_path, &mut env, &mut *ctx.step.current_seq)?;
    }

    // Write response as output artifact for each declared output
    for output_def in step.outputs.values() {
        let output_path = attempt_dir.join(&output_def.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&output_path, &response.body)?;
    }

    emit_output_bindings_and_complete(
        &attempt_dir,
        events_path,
        run_id,
        &mut *ctx.step.current_seq,
        phase_id,
        step,
        attempt,
        attempt_start,
        "interactive",
    )
}

/// Emit AttemptFailed + StepBlocked events for interactive validation failure.
fn emit_interactive_validation_failure(
    ctx: &mut AttemptContext<'_>,
    validation_err: &str,
) -> Result<(), RunError> {
    let elapsed_ms = ctx.attempt_start.elapsed().as_millis() as u64;
    {
        let mut env = make_envelope(ctx.run_id, MethodEventKind::AttemptFailed);
        env.phase_id = Some(ctx.phase_id.to_string());
        env.step_id = Some(ctx.step_id.to_string());
        env.attempt = Some(ctx.attempt);
        env.payload = serde_json::json!({
            "reason": validation_err,
            "elapsed_ms": elapsed_ms,
            "error_category": "validation_failed",
        });
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }
    {
        let mut env = make_envelope(ctx.run_id, MethodEventKind::StepBlocked);
        env.phase_id = Some(ctx.phase_id.to_string());
        env.step_id = Some(ctx.step_id.to_string());
        env.payload = serde_json::json!({
            "reason": format!("response validation failed: {}", validation_err),
            "blocked_reason": {
                "category": "gate_rejected",
                "details": format!("response validation failed: {}", validation_err),
            }
        });
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
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

fn find_handoff(relay_root: &Path, fallback_dirs: &[&Path]) -> Option<std::path::PathBuf> {
    let uppercase = relay_root.join("HANDOFF.md");
    if uppercase.exists() {
        return Some(uppercase);
    }
    let lowercase = relay_root.join("handoff.md");
    if lowercase.exists() {
        return Some(lowercase);
    }

    for dir in fallback_dirs {
        let uppercase = dir.join("HANDOFF.md");
        if uppercase.exists() {
            return Some(uppercase);
        }

        let lowercase = dir.join("handoff.md");
        if lowercase.exists() {
            return Some(lowercase);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::find_handoff;

    #[test]
    fn test_find_handoff_checks_fallback_dirs() {
        let temp = tempfile::tempdir().expect("tempdir");
        let relay_root = temp.path().join("relay");
        let fallback = temp.path().join("handoffs");
        std::fs::create_dir_all(&relay_root).expect("relay dir");
        std::fs::create_dir_all(&fallback).expect("fallback dir");

        let expected = fallback.join("HANDOFF.md");
        std::fs::write(&expected, "# handoff").expect("write handoff");

        let found = find_handoff(&relay_root, &[fallback.as_path()]);

        assert_eq!(found, Some(expected));
    }

    #[test]
    fn test_find_handoff_prefers_relay_root() {
        let temp = tempfile::tempdir().expect("tempdir");
        let relay_root = temp.path().join("relay");
        let fallback = temp.path().join("handoffs");
        std::fs::create_dir_all(&relay_root).expect("relay dir");
        std::fs::create_dir_all(&fallback).expect("fallback dir");

        let relay_handoff = relay_root.join("HANDOFF.md");
        let fallback_handoff = fallback.join("HANDOFF.md");
        std::fs::write(&relay_handoff, "# relay handoff").expect("write relay handoff");
        std::fs::write(&fallback_handoff, "# fallback handoff").expect("write fallback handoff");

        let found = find_handoff(&relay_root, &[fallback.as_path()]);

        assert_eq!(found, Some(relay_handoff));
    }
}

fn resolve_method_outputs(ctx: &mut ExecutionContext<'_>) -> Result<(), RunError> {
    let normalized = ctx.normalized;

    // Project current state to resolve outputs against
    let events = crate::method_runner::events::recover_events(ctx.events_path)?;
    let state = project(&events)?;

    for (name, output) in &normalized.method.outputs {
        match resolve_and_write_output(ctx.paths, name, &output.from, &state, &normalized.method) {
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
        let mut env = make_envelope(ctx.run_id, MethodEventKind::OutputBound);
        env.payload = serde_json::json!({
            "method_output": name,
            "from": output.from,
        });
        append_event(ctx.events_path, &mut env, &mut *ctx.current_seq)?;
    }

    Ok(())
}
