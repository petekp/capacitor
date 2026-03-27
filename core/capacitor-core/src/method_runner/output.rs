//! Output resolver and binding for the method runner.
//!
//! Resolves method-level output locators (e.g. "phase.step.output_name")
//! against projected state and writes output records as artifacts.

use serde::{Deserialize, Serialize};

use crate::method_runner::definition::NormalizedMethodDefinition;
use crate::method_runner::state::{AttemptStatus, MethodRunState, StepStatus};
use crate::method_runner::storage::MethodRunPaths;

// ---------------------------------------------------------------------------
// Locator types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputLocator {
    pub phase_id: String,
    pub step_id: String,
    pub worker_id: Option<String>,
    pub output_name: String,
}

#[derive(Debug, thiserror::Error)]
pub enum LocatorError {
    #[error("invalid locator format: {0}")]
    InvalidFormat(String),

    #[error("empty segment in locator")]
    EmptySegment,
}

/// Parse a locator string into an `OutputLocator`.
/// Format: "phase.step.output" (3 segments) or "phase.step.worker.output" (4 segments).
pub fn parse_locator(locator: &str) -> Result<OutputLocator, LocatorError> {
    let segments: Vec<&str> = locator.split('.').collect();
    match segments.len() {
        3 => {
            for seg in &segments {
                if seg.is_empty() {
                    return Err(LocatorError::EmptySegment);
                }
            }
            Ok(OutputLocator {
                phase_id: segments[0].to_string(),
                step_id: segments[1].to_string(),
                worker_id: None,
                output_name: segments[2].to_string(),
            })
        }
        4 => {
            for seg in &segments {
                if seg.is_empty() {
                    return Err(LocatorError::EmptySegment);
                }
            }
            Ok(OutputLocator {
                phase_id: segments[0].to_string(),
                step_id: segments[1].to_string(),
                worker_id: Some(segments[2].to_string()),
                output_name: segments[3].to_string(),
            })
        }
        _ => Err(LocatorError::InvalidFormat(format!(
            "expected 3 or 4 segments, got {}",
            segments.len()
        ))),
    }
}

// ---------------------------------------------------------------------------
// Resolve errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum ResolveError {
    #[error("phase not found: {0}")]
    PhaseNotFound(String),

    #[error("step not found: {0}")]
    StepNotFound(String),

    #[error("output not declared: {0}")]
    OutputNotDeclared(String),

    #[error("output not available: {0}")]
    OutputNotAvailable(String),

    #[error("worker not found: {0}")]
    WorkerNotFound(String),

    #[error("no clean worker for step")]
    NoCleanWorker,

    #[error("locator error: {0}")]
    LocatorError(#[from] LocatorError),

    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),
}

// ---------------------------------------------------------------------------
// Output record
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputRecord {
    pub locator: String,
    pub resolved_path: String,
    pub binding_policy: String,
    pub resolved_at: String,
    pub worker_id: Option<String>,
}

// ---------------------------------------------------------------------------
// Resolve + write
// ---------------------------------------------------------------------------

/// Resolve a method-level output by locator and write an output record artifact.
pub fn resolve_and_write_output(
    paths: &MethodRunPaths,
    name: &str,
    locator: &str,
    state: &MethodRunState,
    definition: &NormalizedMethodDefinition,
) -> Result<OutputRecord, ResolveError> {
    let loc = parse_locator(locator)?;
    let step_state = resolve_step_state(state, &loc)?;
    ensure_step_is_terminal(step_state, &loc)?;
    ensure_phase_declared(definition, &loc)?;
    let resolved_path = resolve_output_path(step_state, &loc)?;
    let resolved_worker_id = resolve_worker_id(step_state, &loc);

    let record = OutputRecord {
        locator: locator.to_string(),
        resolved_path,
        binding_policy: "single_worker".to_string(),
        resolved_at: chrono::Utc::now().to_rfc3339(),
        worker_id: resolved_worker_id,
    };
    write_output_record(paths, name, &record)?;

    Ok(record)
}

fn resolve_step_state<'a>(
    state: &'a MethodRunState,
    locator: &OutputLocator,
) -> Result<&'a crate::method_runner::state::StepState, ResolveError> {
    let phase_state = state
        .phases
        .get(&locator.phase_id)
        .ok_or_else(|| ResolveError::PhaseNotFound(locator.phase_id.clone()))?;
    phase_state
        .steps
        .get(&locator.step_id)
        .ok_or_else(|| ResolveError::StepNotFound(locator.step_id.clone()))
}

fn ensure_step_is_terminal(
    step_state: &crate::method_runner::state::StepState,
    locator: &OutputLocator,
) -> Result<(), ResolveError> {
    if step_state.status == StepStatus::Completed || step_state.status == StepStatus::Failed {
        return Ok(());
    }

    Err(ResolveError::OutputNotAvailable(format!(
        "step '{}' is not in a terminal state (status: {:?})",
        locator.step_id, step_state.status
    )))
}

fn ensure_phase_declared(
    definition: &NormalizedMethodDefinition,
    locator: &OutputLocator,
) -> Result<(), ResolveError> {
    definition
        .phases
        .iter()
        .find(|phase| phase.id == locator.phase_id)
        .ok_or_else(|| ResolveError::PhaseNotFound(locator.phase_id.clone()))?;
    Ok(())
}

fn resolve_output_path(
    step_state: &crate::method_runner::state::StepState,
    locator: &OutputLocator,
) -> Result<String, ResolveError> {
    step_state
        .outputs
        .get(&locator.output_name)
        .cloned()
        .ok_or_else(|| ResolveError::OutputNotAvailable(locator.output_name.clone()))
}

fn resolve_worker_id(
    step_state: &crate::method_runner::state::StepState,
    locator: &OutputLocator,
) -> Option<String> {
    let mut resolved_worker_id = locator.worker_id.clone();
    if resolved_worker_id.is_some() {
        return resolved_worker_id;
    }

    for attempt in step_state.attempts.values() {
        if attempt.status == AttemptStatus::Completed
            || attempt.status == AttemptStatus::OutputBound
        {
            if let Some(worker_id) = attempt.workers.keys().next() {
                resolved_worker_id = Some(worker_id.clone());
            }
            if resolved_worker_id.is_some() {
                break;
            }
        }
    }

    resolved_worker_id
}

fn write_output_record(
    paths: &MethodRunPaths,
    name: &str,
    record: &OutputRecord,
) -> Result<(), ResolveError> {
    let record_path = paths.output_record(name);
    if let Some(parent) = record_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(record)?;
    std::fs::write(&record_path, json)?;
    Ok(())
}
