//! Event model and persistence for the method runner.
//!
//! `events.ndjson` is the authoritative state source for a method run.
//! This module defines the typed event envelope, append/recover operations,
//! and the ndjson persistence format.

use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::path::Path;

// ---------------------------------------------------------------------------
// Event envelope
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MethodEventEnvelope {
    pub seq: u64,
    pub timestamp: String,
    pub run_id: String,
    pub kind: MethodEventKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phase_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attempt: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    pub payload: serde_json::Value,
}

// ---------------------------------------------------------------------------
// Event kind enum
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MethodEventKind {
    DefinitionFrozen,
    RunStarted,
    RunCompleted,
    RunFailed,
    RunBlocked,
    PhaseStarted,
    PhaseCompleted,
    PhaseFailed,
    PhaseBlocked,
    StepStarted,
    StepCompleted,
    StepFailed,
    StepBlocked,
    AttemptStarted,
    AttemptCompleted,
    AttemptFailed,
    WorkerDispatched,
    WorkerCompleted,
    WorkerFailed,
    HandoffIngested,
    OutputBound,
    GateEvaluated,
    InteractivePrompted,
    InteractiveResponseReceived,
    SynthesisStarted,
    SynthesisCompleted,
    PipelineExecuteBlocked,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum AppendError {
    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),
}

// ---------------------------------------------------------------------------
// Persistence functions
// ---------------------------------------------------------------------------

/// Read the last sequence number from an existing ndjson event log.
/// Returns 0 if the file does not exist or is empty.
pub fn read_last_seq(events_path: &Path) -> Result<u64, AppendError> {
    if !events_path.exists() {
        return Ok(0);
    }
    let file = std::fs::File::open(events_path)?;
    let reader = std::io::BufReader::new(file);
    let mut last_seq: u64 = 0;
    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Ok(envelope) = serde_json::from_str::<MethodEventEnvelope>(trimmed) {
            last_seq = envelope.seq;
        }
    }
    Ok(last_seq)
}

/// Append a single event to the ndjson log. Increments current_seq,
/// assigns it to the envelope, sets timestamp if empty, serializes,
/// and appends. Returns the new sequence number.
pub fn append_event(
    events_path: &Path,
    envelope: &mut MethodEventEnvelope,
    current_seq: &mut u64,
) -> Result<u64, AppendError> {
    *current_seq += 1;
    envelope.seq = *current_seq;
    if envelope.timestamp.is_empty() {
        envelope.timestamp = chrono::Utc::now().to_rfc3339();
    }
    let json = serde_json::to_string(envelope)?;
    if let Some(parent) = events_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(events_path)?;
    writeln!(file, "{json}")?;
    Ok(*current_seq)
}

/// Recover events from an ndjson log, skipping an invalid last line
/// (torn tail) and truncating the file if necessary.
pub fn recover_events(events_path: &Path) -> Result<Vec<MethodEventEnvelope>, AppendError> {
    if !events_path.exists() {
        return Ok(Vec::new());
    }
    let content = std::fs::read_to_string(events_path)?;
    let lines: Vec<&str> = content.lines().collect();
    let mut events = Vec::new();
    let mut last_was_invalid = false;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<MethodEventEnvelope>(trimmed) {
            Ok(envelope) => {
                events.push(envelope);
                last_was_invalid = false;
            }
            Err(_) => {
                if i == lines.len() - 1 {
                    // Torn tail — skip it and truncate
                    last_was_invalid = true;
                } else {
                    // Invalid line in the middle — skip it
                    continue;
                }
            }
        }
    }

    // Truncate the file if the last line was torn
    if last_was_invalid {
        let mut file = std::fs::File::create(events_path)?;
        for event in &events {
            let json = serde_json::to_string(event)?;
            writeln!(file, "{json}")?;
        }
    }

    Ok(events)
}

/// Create a new envelope with default/empty fields.
pub fn make_envelope(run_id: &str, kind: MethodEventKind) -> MethodEventEnvelope {
    MethodEventEnvelope {
        seq: 0,
        timestamp: String::new(),
        run_id: run_id.to_string(),
        kind,
        phase_id: None,
        step_id: None,
        attempt: None,
        worker_id: None,
        payload: serde_json::Value::Null,
    }
}
