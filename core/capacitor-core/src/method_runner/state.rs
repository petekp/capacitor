//! State machines and projection for the method runner.
//!
//! Status enums enforce legal transitions. The `project` function replays
//! an event stream into a stable `MethodRunState` snapshot.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

use crate::method_runner::events::{
    recover_events, AppendError, MethodEventEnvelope, MethodEventKind,
};

// ---------------------------------------------------------------------------
// Status enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Created,
    Running,
    Completed,
    Failed,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PhaseStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Blocked,
    Skipped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptStatus {
    Created,
    Dispatching,
    Running,
    HandoffReceived,
    OutputBound,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerStatus {
    Pending,
    Dispatched,
    Running,
    Completed,
    Failed,
}

// ---------------------------------------------------------------------------
// Transition error
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, thiserror::Error)]
#[error("illegal transition for {entity_type} '{entity_id}': {from} -> {to}")]
pub struct TransitionError {
    pub entity_type: String,
    pub entity_id: String,
    pub from: String,
    pub to: String,
}

fn transition_err(entity_type: &str, entity_id: &str, from: &str, to: &str) -> TransitionError {
    TransitionError {
        entity_type: entity_type.to_string(),
        entity_id: entity_id.to_string(),
        from: from.to_string(),
        to: to.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Transition enforcement
// ---------------------------------------------------------------------------

impl RunStatus {
    pub fn transition_to(self, next: Self, id: &str) -> Result<Self, TransitionError> {
        let legal = matches!(
            (self, next),
            (RunStatus::Created, RunStatus::Running)
                | (RunStatus::Running, RunStatus::Completed)
                | (RunStatus::Running, RunStatus::Failed)
                | (RunStatus::Running, RunStatus::Blocked)
                | (RunStatus::Blocked, RunStatus::Running)
                | (RunStatus::Blocked, RunStatus::Failed)
        );
        if legal {
            Ok(next)
        } else {
            Err(transition_err(
                "run",
                id,
                &format!("{self:?}"),
                &format!("{next:?}"),
            ))
        }
    }
}

impl PhaseStatus {
    pub fn transition_to(self, next: Self, id: &str) -> Result<Self, TransitionError> {
        let legal = matches!(
            (self, next),
            (PhaseStatus::Pending, PhaseStatus::Running)
                | (PhaseStatus::Running, PhaseStatus::Completed)
                | (PhaseStatus::Running, PhaseStatus::Failed)
                | (PhaseStatus::Running, PhaseStatus::Blocked)
                | (PhaseStatus::Running, PhaseStatus::Skipped)
                | (PhaseStatus::Blocked, PhaseStatus::Running)
                | (PhaseStatus::Blocked, PhaseStatus::Failed)
        );
        if legal {
            Ok(next)
        } else {
            Err(transition_err(
                "phase",
                id,
                &format!("{self:?}"),
                &format!("{next:?}"),
            ))
        }
    }
}

impl StepStatus {
    pub fn transition_to(self, next: Self, id: &str) -> Result<Self, TransitionError> {
        let legal = matches!(
            (self, next),
            (StepStatus::Pending, StepStatus::Running)
                | (StepStatus::Running, StepStatus::Completed)
                | (StepStatus::Running, StepStatus::Failed)
                | (StepStatus::Running, StepStatus::Blocked)
                | (StepStatus::Blocked, StepStatus::Running)
                | (StepStatus::Blocked, StepStatus::Failed)
        );
        if legal {
            Ok(next)
        } else {
            Err(transition_err(
                "step",
                id,
                &format!("{self:?}"),
                &format!("{next:?}"),
            ))
        }
    }
}

impl AttemptStatus {
    pub fn transition_to(self, next: Self, id: &str) -> Result<Self, TransitionError> {
        let legal = matches!(
            (self, next),
            (AttemptStatus::Created, AttemptStatus::Dispatching)
                | (AttemptStatus::Created, AttemptStatus::OutputBound) // synthesis/interactive: no worker dispatch
                | (AttemptStatus::Created, AttemptStatus::Failed) // adapter error before any dispatch
                | (AttemptStatus::Dispatching, AttemptStatus::Running)
                | (AttemptStatus::Dispatching, AttemptStatus::Failed) // all workers failed during dispatch
                | (AttemptStatus::Running, AttemptStatus::HandoffReceived)
                | (AttemptStatus::Running, AttemptStatus::Failed)
                | (AttemptStatus::HandoffReceived, AttemptStatus::OutputBound)
                | (AttemptStatus::HandoffReceived, AttemptStatus::Failed)
                | (AttemptStatus::OutputBound, AttemptStatus::Completed)
                | (AttemptStatus::OutputBound, AttemptStatus::Failed)
        );
        if legal {
            Ok(next)
        } else {
            Err(transition_err(
                "attempt",
                id,
                &format!("{self:?}"),
                &format!("{next:?}"),
            ))
        }
    }
}

impl WorkerStatus {
    pub fn transition_to(self, next: Self, id: &str) -> Result<Self, TransitionError> {
        let legal = matches!(
            (self, next),
            (WorkerStatus::Pending, WorkerStatus::Dispatched)
                | (WorkerStatus::Dispatched, WorkerStatus::Running)
                | (WorkerStatus::Running, WorkerStatus::Completed)
                | (WorkerStatus::Running, WorkerStatus::Failed)
        );
        if legal {
            Ok(next)
        } else {
            Err(transition_err(
                "worker",
                id,
                &format!("{self:?}"),
                &format!("{next:?}"),
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// State projection types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MethodRunState {
    pub run_id: String,
    pub status: RunStatus,
    pub definition_frozen: bool,
    pub phases: BTreeMap<String, PhaseState>,
    pub seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PhaseState {
    pub status: PhaseStatus,
    pub steps: BTreeMap<String, StepState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepState {
    pub status: StepStatus,
    pub current_attempt: u32,
    pub attempts: BTreeMap<u32, AttemptState>,
    pub outputs: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptState {
    pub status: AttemptStatus,
    pub workers: BTreeMap<String, WorkerState>,
    pub output_bindings: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerState {
    pub status: WorkerStatus,
    pub handoff_received: bool,
}

// ---------------------------------------------------------------------------
// Projection error
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum ProjectionError {
    #[error("transition error at event seq {seq}: {source}")]
    TransitionError {
        seq: u64,
        #[source]
        source: TransitionError,
    },

    #[error("event recovery error: {0}")]
    RecoveryError(#[from] AppendError),
}

// ---------------------------------------------------------------------------
// Projection
// ---------------------------------------------------------------------------

/// Apply a sequence of events to build a `MethodRunState`.
pub fn project(events: &[MethodEventEnvelope]) -> Result<MethodRunState, ProjectionError> {
    let mut state = MethodRunState {
        run_id: String::new(),
        status: RunStatus::Created,
        definition_frozen: false,
        phases: BTreeMap::new(),
        seq: 0,
    };

    for event in events {
        apply_event(&mut state, event)?;
        state.seq = event.seq;
    }

    Ok(state)
}

fn apply_event(
    state: &mut MethodRunState,
    event: &MethodEventEnvelope,
) -> Result<(), ProjectionError> {
    let seq = event.seq;
    match event.kind {
        MethodEventKind::DefinitionFrozen => {
            state.definition_frozen = true;
            state.run_id.clone_from(&event.run_id);
        }
        MethodEventKind::RunStarted => {
            state.run_id.clone_from(&event.run_id);
            state.status = state
                .status
                .transition_to(RunStatus::Running, &state.run_id.clone())
                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
        }
        MethodEventKind::RunCompleted => {
            state.status = state
                .status
                .transition_to(RunStatus::Completed, &state.run_id.clone())
                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
        }
        MethodEventKind::RunFailed => {
            state.status = state
                .status
                .transition_to(RunStatus::Failed, &state.run_id.clone())
                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
        }
        MethodEventKind::RunBlocked => {
            state.status = state
                .status
                .transition_to(RunStatus::Blocked, &state.run_id.clone())
                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
        }
        MethodEventKind::PhaseStarted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let phase = state
                .phases
                .entry(phase_id.to_string())
                .or_insert_with(|| PhaseState {
                    status: PhaseStatus::Pending,
                    steps: BTreeMap::new(),
                });
            phase.status = phase
                .status
                .transition_to(PhaseStatus::Running, phase_id)
                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
        }
        MethodEventKind::PhaseCompleted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                phase.status = phase
                    .status
                    .transition_to(PhaseStatus::Completed, phase_id)
                    .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
            }
        }
        MethodEventKind::PhaseFailed => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                phase.status = phase
                    .status
                    .transition_to(PhaseStatus::Failed, phase_id)
                    .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
            }
        }
        MethodEventKind::PhaseBlocked => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                phase.status = phase
                    .status
                    .transition_to(PhaseStatus::Blocked, phase_id)
                    .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
            }
        }
        MethodEventKind::StepStarted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                let step = phase
                    .steps
                    .entry(step_id.to_string())
                    .or_insert_with(|| StepState {
                        status: StepStatus::Pending,
                        current_attempt: 0,
                        attempts: BTreeMap::new(),
                        outputs: BTreeMap::new(),
                    });
                step.status = step
                    .status
                    .transition_to(StepStatus::Running, step_id)
                    .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
            }
        }
        MethodEventKind::StepCompleted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    step.status = step
                        .status
                        .transition_to(StepStatus::Completed, step_id)
                        .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                }
            }
        }
        MethodEventKind::StepFailed => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    step.status = step
                        .status
                        .transition_to(StepStatus::Failed, step_id)
                        .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                }
            }
        }
        MethodEventKind::StepBlocked => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    step.status = step
                        .status
                        .transition_to(StepStatus::Blocked, step_id)
                        .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                }
            }
        }
        MethodEventKind::AttemptStarted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    step.current_attempt = attempt_num;
                    step.attempts.insert(
                        attempt_num,
                        AttemptState {
                            status: AttemptStatus::Created,
                            workers: BTreeMap::new(),
                            output_bindings: BTreeMap::new(),
                        },
                    );
                }
            }
        }
        MethodEventKind::AttemptCompleted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        attempt.status = attempt
                            .status
                            .transition_to(AttemptStatus::Completed, &attempt_id)
                            .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                    }
                }
            }
        }
        MethodEventKind::AttemptFailed => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        attempt.status = attempt
                            .status
                            .transition_to(AttemptStatus::Failed, &attempt_id)
                            .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                    }
                }
            }
        }
        MethodEventKind::WorkerDispatched => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let worker_id = event.worker_id.as_deref().unwrap_or("primary");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        // Transition attempt Created → Dispatching
                        if attempt.status == AttemptStatus::Created {
                            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
                            attempt.status = attempt
                                .status
                                .transition_to(AttemptStatus::Dispatching, &attempt_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                        attempt.workers.insert(
                            worker_id.to_string(),
                            WorkerState {
                                status: WorkerStatus::Dispatched,
                                handoff_received: false,
                            },
                        );
                    }
                }
            }
        }
        MethodEventKind::WorkerCompleted => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let worker_id = event.worker_id.as_deref().unwrap_or("primary");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        // Transition attempt Dispatching → Running if needed
                        if attempt.status == AttemptStatus::Dispatching {
                            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
                            attempt.status = attempt
                                .status
                                .transition_to(AttemptStatus::Running, &attempt_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                        if let Some(worker) = attempt.workers.get_mut(worker_id) {
                            // Dispatched → Running → Completed
                            if worker.status == WorkerStatus::Dispatched {
                                worker.status = worker
                                    .status
                                    .transition_to(WorkerStatus::Running, worker_id)
                                    .map_err(|e| ProjectionError::TransitionError {
                                        seq,
                                        source: e,
                                    })?;
                            }
                            worker.status = worker
                                .status
                                .transition_to(WorkerStatus::Completed, worker_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                    }
                }
            }
        }
        MethodEventKind::WorkerFailed => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let worker_id = event.worker_id.as_deref().unwrap_or("primary");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        if let Some(worker) = attempt.workers.get_mut(worker_id) {
                            if worker.status == WorkerStatus::Dispatched {
                                worker.status = worker
                                    .status
                                    .transition_to(WorkerStatus::Running, worker_id)
                                    .map_err(|e| ProjectionError::TransitionError {
                                        seq,
                                        source: e,
                                    })?;
                            }
                            worker.status = worker
                                .status
                                .transition_to(WorkerStatus::Failed, worker_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                    }
                }
            }
        }
        MethodEventKind::HandoffIngested => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            let worker_id = event.worker_id.as_deref().unwrap_or("primary");
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        // Transition attempt Running → HandoffReceived
                        if attempt.status == AttemptStatus::Running {
                            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
                            attempt.status = attempt
                                .status
                                .transition_to(AttemptStatus::HandoffReceived, &attempt_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                        if let Some(worker) = attempt.workers.get_mut(worker_id) {
                            worker.handoff_received = true;
                        }
                    }
                }
            }
        }
        MethodEventKind::OutputBound => {
            let phase_id = event.phase_id.as_deref().unwrap_or("unknown");
            let step_id = event.step_id.as_deref().unwrap_or("unknown");
            let attempt_num = event.attempt.unwrap_or(1);
            if let Some(phase) = state.phases.get_mut(phase_id) {
                if let Some(step) = phase.steps.get_mut(step_id) {
                    if let Some(attempt) = step.attempts.get_mut(&attempt_num) {
                        // Transition attempt → OutputBound
                        // HandoffReceived → OutputBound (dispatch path)
                        // Created → OutputBound (synthesis/interactive path: no worker dispatch)
                        if attempt.status == AttemptStatus::HandoffReceived
                            || attempt.status == AttemptStatus::Created
                        {
                            let attempt_id = format!("{step_id}:attempt:{attempt_num}");
                            attempt.status = attempt
                                .status
                                .transition_to(AttemptStatus::OutputBound, &attempt_id)
                                .map_err(|e| ProjectionError::TransitionError { seq, source: e })?;
                        }
                        // Record the binding from payload
                        if let Some(name) = event.payload.get("name").and_then(|v| v.as_str()) {
                            if let Some(path) = event.payload.get("path").and_then(|v| v.as_str()) {
                                attempt
                                    .output_bindings
                                    .insert(name.to_string(), path.to_string());
                                step.outputs.insert(name.to_string(), path.to_string());
                            }
                        }
                    }
                }
            }
        }
        // Events we acknowledge but don't need special state for in tracer bullet
        MethodEventKind::GateEvaluated
        | MethodEventKind::InteractivePrompted
        | MethodEventKind::InteractiveResponseReceived
        | MethodEventKind::SynthesisStarted
        | MethodEventKind::SynthesisCompleted
        | MethodEventKind::PipelineExecuteBlocked => {}
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Atomic state persistence
// ---------------------------------------------------------------------------

/// Write state to a temporary file then atomically rename.
pub fn write_state_atomic(state_path: &Path, state: &MethodRunState) -> Result<(), std::io::Error> {
    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp_path = state_path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(state).map_err(std::io::Error::other)?;
    std::fs::write(&tmp_path, json)?;
    std::fs::rename(&tmp_path, state_path)?;
    Ok(())
}

/// Rebuild state by recovering events from disk and projecting.
pub fn rebuild_state(events_path: &Path) -> Result<MethodRunState, ProjectionError> {
    let events = recover_events(events_path)?;
    project(&events)
}
