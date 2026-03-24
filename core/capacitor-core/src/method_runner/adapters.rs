//! Adapter contracts and fake implementations for the method runner.
//!
//! Traits define the boundaries for prompt construction, worker dispatch,
//! artifact ingestion, and interactive checkpoints. Fake implementations
//! support the tracer bullet vertical.

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

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

    #[error("skill not found: {0}")]
    SkillNotFound(String),

    #[error("template not found: {0}")]
    TemplateNotFound(String),

    #[error("assembly failed (exit {exit_code}): {stderr}")]
    AssemblyFailed { exit_code: i32, stderr: String },

    #[error("contract violation: {0}")]
    ContractViolation(String),
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
    /// Step-level template name (e.g. "implement", "review"). None if unset.
    pub template: Option<String>,
    /// Merged skills list (method defaults + phase + step + worker), stable order.
    pub skills: Vec<String>,
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
    /// Absolute path to the assembled prompt file from IF1.
    pub prompt_path: PathBuf,
}

/// Result from dispatching a worker attempt.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkerDispatchResult {
    pub worker_id: String,
    pub exit_code: i32,
    /// Signal that terminated the process, if any (e.g. SIGTERM = 15).
    pub signal: Option<i32>,
    /// Wall-clock elapsed time of the worker subprocess.
    pub elapsed: Duration,
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
// Interactive IO
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
// Response type validation
// ---------------------------------------------------------------------------

/// Validate an interactive response against its declared response_type.
/// Returns Ok(()) if valid, or Err(reason) if the response doesn't match.
pub fn validate_interactive_response(response_type: &str, body: &str) -> Result<(), String> {
    match response_type {
        "approval" => {
            let normalized = body.trim().to_lowercase();
            if normalized == "approved" || normalized == "rejected" {
                Ok(())
            } else {
                Err(format!(
                    "approval response must be 'approved' or 'rejected', got '{}'",
                    body.trim()
                ))
            }
        }
        "markdown" | "selection" | "checklist" => {
            if body.trim().is_empty() {
                Err(format!("{} response must be non-empty", response_type))
            } else {
                Ok(())
            }
        }
        other => {
            // Unknown response type — accept any non-empty response
            if body.trim().is_empty() {
                Err(format!("{} response must be non-empty", other))
            } else {
                Ok(())
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Fake interactive IO
// ---------------------------------------------------------------------------

/// Fake interactive IO for tracer bullet. Returns a pre-configured response
/// without actually prompting the user. Optionally validates against a
/// response_type if one is set.
pub struct FakeInteractiveIO {
    pub response: String,
    /// Optional response_type for validation awareness. When set, the fake
    /// adapter will validate its response against the expected type.
    pub response_type: Option<String>,
}

impl FakeInteractiveIO {
    /// Create a FakeInteractiveIO with just a response (no type awareness).
    pub fn new(response: impl Into<String>) -> Self {
        Self {
            response: response.into(),
            response_type: None,
        }
    }

    /// Create a FakeInteractiveIO with response_type awareness.
    pub fn with_type(response: impl Into<String>, response_type: impl Into<String>) -> Self {
        Self {
            response: response.into(),
            response_type: Some(response_type.into()),
        }
    }
}

impl InteractiveIO for FakeInteractiveIO {
    fn emit_prompt(&self, _prompt: &InteractivePrompt) {
        // In fake mode, we just ignore the prompt
    }
    fn capture_response(&self) -> InteractiveResponse {
        // If response_type is set, validate the response matches
        if let Some(ref rt) = self.response_type {
            if let Err(e) = validate_interactive_response(rt, &self.response) {
                eprintln!("warning: fake response validation failed: {}", e);
            }
        }
        InteractiveResponse {
            body: self.response.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// CLI interactive IO
// ---------------------------------------------------------------------------

/// CLI interactive IO adapter. Reads responses from CLI flags:
/// - `--approve` → "approved" for approval type
/// - `--reject` → "rejected" for approval type
/// - `--response-file <path>` → read response from file
pub struct CliInteractiveIO {
    mode: CliInteractiveMode,
}

/// How the CLI adapter resolves its response.
pub enum CliInteractiveMode {
    /// Fixed "approved" response (from --approve flag).
    Approve,
    /// Fixed "rejected" response (from --reject flag).
    Reject,
    /// Read response body from a file (from --response-file flag).
    ResponseFile(PathBuf),
}

impl CliInteractiveIO {
    pub fn approve() -> Self {
        Self {
            mode: CliInteractiveMode::Approve,
        }
    }

    pub fn reject() -> Self {
        Self {
            mode: CliInteractiveMode::Reject,
        }
    }

    pub fn from_file(path: PathBuf) -> Self {
        Self {
            mode: CliInteractiveMode::ResponseFile(path),
        }
    }
}

impl InteractiveIO for CliInteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt) {
        // In CLI mode, print the prompt to stdout
        println!("[interactive] {}", prompt.message);
    }

    fn capture_response(&self) -> InteractiveResponse {
        let body = match &self.mode {
            CliInteractiveMode::Approve => "approved".to_string(),
            CliInteractiveMode::Reject => "rejected".to_string(),
            CliInteractiveMode::ResponseFile(path) => {
                std::fs::read_to_string(path).unwrap_or_else(|e| {
                    eprintln!("warning: failed to read response file: {}", e);
                    String::new()
                })
            }
        };
        InteractiveResponse { body }
    }
}

// ---------------------------------------------------------------------------
// File-backed interactive IO
// ---------------------------------------------------------------------------

/// File-backed interactive IO for testing multi-gate methods.
///
/// Handles TWO prompt formats:
/// 1. Gate prompts: `"Gate '<gate_id>': ..."` -> looks up `{response_dir}/{gate_id}.json`
/// 2. Interactive step prompts: raw prompt text -> looks up `{response_dir}/{step_id}.json`
///    where step_id is extracted by normalizing the prompt (or a `_default.json` fallback)
///
/// Response JSON format: `{"action": "approved", "note": "optional note"}`
/// Falls back to "approved" if no matching file exists.
pub struct FileInteractiveIO {
    response_dir: PathBuf,
    current_prompt_key: std::cell::RefCell<Option<String>>,
}

impl FileInteractiveIO {
    pub fn new(response_dir: PathBuf) -> Self {
        Self {
            response_dir,
            current_prompt_key: std::cell::RefCell::new(None),
        }
    }

    /// Extract a lookup key from a prompt message.
    /// Gate prompts: "Gate 'build-gate': ..." -> "build-gate"
    /// Interactive step prompts: try to find a step-id-like slug, else use "_default"
    fn extract_key(message: &str) -> String {
        // Try gate format first: "Gate '<id>':"
        if let Some(after) = message.strip_prefix("Gate '") {
            if let Some(id) = after.split("':").next() {
                return id.to_string();
            }
        }
        // For interactive step prompts, use a normalized slug of the first
        // 40 chars as the key, or "_default" if empty
        let slug: String = message
            .chars()
            .take(40)
            .map(|c| {
                if c.is_alphanumeric() {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect();
        let slug = slug.trim_matches('-').to_string();
        if slug.is_empty() {
            "_default".to_string()
        } else {
            slug
        }
    }
}

impl InteractiveIO for FileInteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt) {
        *self.current_prompt_key.borrow_mut() = Some(Self::extract_key(&prompt.message));
    }

    fn capture_response(&self) -> InteractiveResponse {
        let key = self.current_prompt_key.borrow();
        let body = if let Some(ref k) = *key {
            let path = self.response_dir.join(format!("{}.json", k));
            let fallback = self.response_dir.join("_default.json");
            let target = if path.exists() { path } else { fallback };
            if target.exists() {
                let content = std::fs::read_to_string(&target).unwrap_or_default();
                serde_json::from_str::<serde_json::Value>(&content)
                    .ok()
                    .and_then(|v| v["action"].as_str().map(String::from))
                    .unwrap_or_else(|| "approved".into())
            } else {
                "approved".into()
            }
        } else {
            "approved".into()
        };
        InteractiveResponse { body }
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

impl FakeWorkerDispatcher {
    fn write_handoff(request: &WorkerDispatchRequest) -> Result<(), std::io::Error> {
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
        Ok(())
    }
}

impl WorkerDispatcher for FakeWorkerDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError> {
        std::fs::create_dir_all(&request.relay_root)?;
        Self::write_handoff(request)?;

        Ok(WorkerDispatchResult {
            worker_id: request.worker_id.clone(),
            exit_code: 0,
            signal: None,
            elapsed: Duration::ZERO,
        })
    }
}

// ---------------------------------------------------------------------------
// Configurable worker dispatcher (for testing retry/failure scenarios)
// ---------------------------------------------------------------------------

/// A dispatcher that can be configured to fail on specific attempts.
/// After construction, call `fail_attempt(step_id, attempt)` to make
/// that attempt return an error. All other attempts produce clean handoffs.
pub struct ConfigurableDispatcher {
    /// Set of (step_id, attempt) pairs that should fail with AdapterError.
    fail_on: std::collections::HashSet<(String, u32)>,
    /// Set of (step_id, attempt) pairs that should return non-zero exit code
    /// (worker crash) but still produce a handoff with ISSUES verdict.
    crash_on: std::collections::HashSet<(String, u32)>,
}

impl Default for ConfigurableDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

impl ConfigurableDispatcher {
    pub fn new() -> Self {
        Self {
            fail_on: std::collections::HashSet::new(),
            crash_on: std::collections::HashSet::new(),
        }
    }

    /// Configure this attempt to fail with an adapter error (spawn failed).
    pub fn fail_attempt(&mut self, step_id: &str, attempt: u32) {
        self.fail_on.insert((step_id.to_string(), attempt));
    }

    /// Configure this attempt to crash (non-zero exit, ISSUES verdict handoff).
    pub fn crash_attempt(&mut self, step_id: &str, attempt: u32) {
        self.crash_on.insert((step_id.to_string(), attempt));
    }
}

impl WorkerDispatcher for ConfigurableDispatcher {
    fn dispatch(
        &self,
        request: &WorkerDispatchRequest,
    ) -> Result<WorkerDispatchResult, AdapterError> {
        let key = (request.step_id.clone(), request.attempt);

        // Check for hard failure (adapter error)
        if self.fail_on.contains(&key) {
            return Err(AdapterError::SpawnFailed(format!(
                "configured failure for step '{}' attempt {}",
                request.step_id, request.attempt
            )));
        }

        std::fs::create_dir_all(&request.relay_root)?;

        // Check for crash (produces handoff with ISSUES verdict)
        if self.crash_on.contains(&key) {
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
            writeln!(f, "- (fake) NOT verified")?;
            writeln!(f)?;
            writeln!(f, "### Verdict")?;
            writeln!(f, "ISSUES")?;
            writeln!(f)?;
            writeln!(f, "### Completion Claim")?;
            writeln!(f, "INCOMPLETE")?;
            writeln!(f)?;
            writeln!(f, "### Issues Found")?;
            writeln!(f, "Worker crashed on attempt {}", request.attempt)?;
            writeln!(f)?;
            writeln!(f, "### Next Steps")?;
            writeln!(f, "Retry")?;

            return Ok(WorkerDispatchResult {
                worker_id: request.worker_id.clone(),
                exit_code: 1,
                signal: None,
                elapsed: Duration::ZERO,
            });
        }

        // Happy path: clean handoff
        FakeWorkerDispatcher::write_handoff(request)?;

        Ok(WorkerDispatchResult {
            worker_id: request.worker_id.clone(),
            exit_code: 0,
            signal: None,
            elapsed: Duration::ZERO,
        })
    }
}
