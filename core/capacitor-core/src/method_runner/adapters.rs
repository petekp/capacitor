//! Adapter contracts and fake implementations for the method runner.
//!
//! Traits define the boundaries for prompt construction, worker dispatch,
//! artifact ingestion, and interactive checkpoints. Fake implementations
//! support the tracer bullet vertical.

use std::io::Write;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum AdapterError {
    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("spawn failed: {0}")]
    SpawnFailed(String),

    #[error("timeout")]
    Timeout,

    #[error("process crash: {0}")]
    ProcessCrash(String),
}

// ---------------------------------------------------------------------------
// Prompt builder
// ---------------------------------------------------------------------------

/// Request for prompt composition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptBuildRequest {
    pub phase_id: String,
    pub step_id: String,
    pub attempt: u32,
    pub relay_root: PathBuf,
    pub instructions: String,
}

/// Result from prompt composition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptBuildResult {
    pub header_path: PathBuf,
    pub prompt_path: PathBuf,
}

/// Boundary for building worker prompts.
pub trait PromptBuilder {
    fn build_prompt(&self, request: &PromptBuildRequest)
        -> Result<PromptBuildResult, AdapterError>;
}

// ---------------------------------------------------------------------------
// Worker dispatcher
// ---------------------------------------------------------------------------

/// Request for dispatching a worker attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerDispatchRequest {
    pub phase_id: String,
    pub step_id: String,
    pub attempt: u32,
    pub worker_id: String,
    pub relay_root: PathBuf,
}

/// Result from dispatching a worker attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerDispatchResult {
    pub worker_id: String,
    pub exit_code: i32,
}

/// Boundary for worker orchestration.
pub trait WorkerDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError>;
}

// ---------------------------------------------------------------------------
// Artifact ingestion (unchanged from scaffold)
// ---------------------------------------------------------------------------

/// Record for ingested artifacts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtifactRecord {
    pub name: String,
    pub path: PathBuf,
}

/// Boundary for translating external artifacts into typed runner records.
pub trait ArtifactIngestor {
    fn ingest(&self, artifact: &ArtifactRecord);
}

// ---------------------------------------------------------------------------
// Interactive IO (unchanged from scaffold)
// ---------------------------------------------------------------------------

/// Prompt shown for interactive checkpoints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InteractivePrompt {
    pub message: String,
}

/// Response captured from interactive checkpoints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InteractiveResponse {
    pub body: String,
}

/// Boundary for explicit human-in-the-loop interaction.
pub trait InteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt);
    fn capture_response(&self) -> InteractiveResponse;
}

// ---------------------------------------------------------------------------
// Fake interactive IO
// ---------------------------------------------------------------------------

/// Fake interactive IO for tracer bullet. Returns a pre-configured response
/// without actually prompting the user.
pub struct FakeInteractiveIO {
    pub response: String,
}

impl InteractiveIO for FakeInteractiveIO {
    fn emit_prompt(&self, _prompt: &InteractivePrompt) {
        // In fake mode, we just ignore the prompt
    }
    fn capture_response(&self) -> InteractiveResponse {
        InteractiveResponse {
            body: self.response.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// Fake prompt builder
// ---------------------------------------------------------------------------

/// Fake prompt builder for tracer bullet. Creates prompt-header.md and
/// prompt.md with step metadata at the relay root.
pub struct FakePromptBuilder;

impl PromptBuilder for FakePromptBuilder {
    fn build_prompt(
        &self,
        request: &PromptBuildRequest,
    ) -> Result<PromptBuildResult, AdapterError> {
        std::fs::create_dir_all(&request.relay_root)?;

        let header_path = request.relay_root.join("prompt-header.md");
        let prompt_path = request.relay_root.join("prompt.md");

        {
            let mut f = std::fs::File::create(&header_path)?;
            writeln!(f, "# Step: {}", request.step_id)?;
            writeln!(f, "Phase: {}", request.phase_id)?;
            writeln!(f, "Attempt: {}", request.attempt)?;
        }

        {
            let mut f = std::fs::File::create(&prompt_path)?;
            writeln!(f, "# Instructions")?;
            writeln!(f)?;
            writeln!(f, "{}", request.instructions)?;
        }

        Ok(PromptBuildResult {
            header_path,
            prompt_path,
        })
    }
}

// ---------------------------------------------------------------------------
// Fake worker dispatcher
// ---------------------------------------------------------------------------

/// Fake worker dispatcher for tracer bullet. Creates a synthetic HANDOFF.md
/// at the worker's relay root with all canonical headings, CLEAN verdict,
/// and COMPLETE completion claim.
pub struct FakeWorkerDispatcher;

impl WorkerDispatcher for FakeWorkerDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError> {
        std::fs::create_dir_all(&request.relay_root)?;

        let handoff_path = request.relay_root.join("HANDOFF.md");
        let mut f = std::fs::File::create(&handoff_path)?;

        writeln!(f, "# Handoff: {} / {}", request.phase_id, request.step_id)?;
        writeln!(f)?;
        writeln!(f, "### Files Changed")?;
        writeln!(f, "- (fake) no files changed")?;
        writeln!(f)?;
        writeln!(f, "### Tests Run")?;
        writeln!(f, "- (fake) no tests run")?;
        writeln!(f)?;
        writeln!(f, "### Verification")?;
        writeln!(f, "- (fake) verified")?;
        writeln!(f)?;
        writeln!(f, "### Verdict")?;
        writeln!(f, "CLEAN")?;
        writeln!(f)?;
        writeln!(f, "### Completion Claim")?;
        writeln!(f, "COMPLETE")?;
        writeln!(f)?;
        writeln!(f, "### Issues Found")?;
        writeln!(f, "None")?;
        writeln!(f)?;
        writeln!(f, "### Next Steps")?;
        writeln!(f, "None")?;

        Ok(WorkerDispatchResult {
            worker_id: request.worker_id.clone(),
            exit_code: 0,
        })
    }
}
