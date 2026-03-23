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

    // Verify the phase exists in state
    let phase_state = state
        .phases
        .get(&loc.phase_id)
        .ok_or_else(|| ResolveError::PhaseNotFound(loc.phase_id.clone()))?;

    // Verify the step exists in state
    let step_state = phase_state
        .steps
        .get(&loc.step_id)
        .ok_or_else(|| ResolveError::StepNotFound(loc.step_id.clone()))?;

    // Check the step is in a terminal state
    if step_state.status != StepStatus::Completed && step_state.status != StepStatus::Failed {
        return Err(ResolveError::OutputNotAvailable(format!(
            "step '{}' is not in a terminal state (status: {:?})",
            loc.step_id, step_state.status
        )));
    }

    // Verify the output is declared in the definition
    let _phase_def = definition
        .phases
        .iter()
        .find(|p| p.id == loc.phase_id)
        .ok_or_else(|| ResolveError::PhaseNotFound(loc.phase_id.clone()))?;

    // Find output binding from the completed attempt
    let resolved_path = step_state
        .outputs
        .get(&loc.output_name)
        .ok_or_else(|| ResolveError::OutputNotAvailable(loc.output_name.clone()))?
        .clone();

    // Find the worker_id from the completed attempt
    let mut resolved_worker_id = loc.worker_id.clone();
    if resolved_worker_id.is_none() {
        // Find the first completed attempt and its first completed worker
        for attempt in step_state.attempts.values() {
            if attempt.status == AttemptStatus::Completed
                || attempt.status == AttemptStatus::OutputBound
            {
                if let Some(wid) = attempt.workers.keys().next() {
                    resolved_worker_id = Some(wid.clone());
                }
                if resolved_worker_id.is_some() {
                    break;
                }
            }
        }
    }

    let record = OutputRecord {
        locator: locator.to_string(),
        resolved_path,
        binding_policy: "single_worker".to_string(),
        resolved_at: chrono::Utc::now().to_rfc3339(),
        worker_id: resolved_worker_id,
    };

    // Write the output record
    let record_path = paths.output_record(name);
    if let Some(parent) = record_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(&record)?;
    std::fs::write(&record_path, json)?;

    Ok(record)
}
