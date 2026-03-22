//! Run Kernel domain types.
//!
//! These types implement the Run Kernel with Methods and Checkpoints architecture
//! (Option 2 from ARCHITECTURE_OPTIONS.md). They coexist with the existing
//! delegation types during the strangler-pattern migration.

use crate::domain::now_rfc3339;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    #[default]
    Created,
    Active,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

impl RunStatus {
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointKind {
    Proposal,
    ImplementationMilestone,
    AlignmentReview,
    Custom { label: String },
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointStatus {
    #[default]
    Pending,
    Active,
    Decided,
    Skipped,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum PhaseStatus {
    #[default]
    Pending,
    Active,
    Completed,
    Skipped,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum InvolvementLevel {
    Autonomous,
    #[default]
    Supervised,
    Collaborative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum RunMutationKind {
    Create,
    AdvancePhase,
    EmitCheckpoint,
    SubmitDecision,
    AttachSession,
    DetachSession,
    CaptureComplete,
    Pause,
    Resume,
    Complete,
    Fail,
    Cancel,
}

// ---------------------------------------------------------------------------
// Method Templates
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct PhaseTemplate {
    pub id: String,
    pub name: String,
    pub checkpoint_policy: String,
    pub skill_hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MethodTemplate {
    pub id: String,
    pub name: String,
    pub description: String,
    pub task_archetype: String,
    pub default_involvement: InvolvementLevel,
    pub phases: Vec<PhaseTemplate>,
}

// ---------------------------------------------------------------------------
// Phase Instance (runtime copy of a phase template within a run)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct PhaseInstance {
    pub id: String,
    pub template_id: String,
    pub name: String,
    pub status: PhaseStatus,
    pub checkpoint_policy: String,
    pub skill_hint: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

impl PhaseInstance {
    #[must_use]
    pub fn from_template(template: &PhaseTemplate, index: usize) -> Self {
        Self {
            id: format!("phase-{:03}", index + 1),
            template_id: template.id.clone(),
            name: template.name.clone(),
            status: PhaseStatus::Pending,
            checkpoint_policy: template.checkpoint_policy.clone(),
            skill_hint: template.skill_hint.clone(),
            started_at: None,
            completed_at: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Media Artifacts
// ---------------------------------------------------------------------------

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum MediaArtifactType {
    #[default]
    Screenshot,
    Recording,
    MermaidDiagram,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MediaArtifact {
    pub artifact_type: MediaArtifactType,
    pub path: String,
    pub label: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_secs: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MermaidSource {
    pub label: String,
    pub source: String,
}

#[derive(
    Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum, Default,
)]
#[serde(rename_all = "snake_case")]
pub enum CaptureStatus {
    #[default]
    NotRequested,
    Pending,
    Completed,
    Failed {
        reason: String,
    },
}

// ---------------------------------------------------------------------------
// Checkpoint
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CheckpointPacket {
    pub kind: CheckpointKind,
    pub title: String,
    pub summary: Option<String>,
    pub brief_path: Option<String>,
    pub manifest_path: Option<String>,
    pub media_artifacts: Vec<MediaArtifact>,
    pub mermaid_sources: Vec<MermaidSource>,
    pub capture_requested: bool,
    /// URL to capture via agent-browser at checkpoint time (e.g., "http://localhost:3000").
    /// When present, implies capture is requested even if `capture_requested` is false.
    pub capture_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CheckpointDecision {
    pub action: String,
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ActiveCheckpoint {
    pub id: String,
    pub phase_id: String,
    pub kind: CheckpointKind,
    pub status: CheckpointStatus,
    pub title: String,
    pub summary: Option<String>,
    pub brief_path: Option<String>,
    pub manifest_path: Option<String>,
    pub media_artifacts: Vec<MediaArtifact>,
    pub mermaid_sources: Vec<MermaidSource>,
    pub capture_status: CaptureStatus,
    /// URL that was captured (or should be captured) via agent-browser.
    pub capture_url: Option<String>,
    pub decision: Option<CheckpointDecision>,
    pub created_at: String,
    pub decided_at: Option<String>,
}

// ---------------------------------------------------------------------------
// Run State
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct RunState {
    pub id: String,
    pub project_path: String,
    pub method_id: String,
    pub method_name: String,
    pub involvement: InvolvementLevel,
    pub status: RunStatus,
    pub phases: Vec<PhaseInstance>,
    pub current_phase_index: u32,
    pub active_checkpoint: Option<ActiveCheckpoint>,
    pub session_id: Option<String>,
    /// Strangler bridge: links to existing delegation worker when in execution phase.
    pub delegation_worker_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl RunState {
    #[must_use]
    pub fn current_phase(&self) -> Option<&PhaseInstance> {
        self.phases.get(self.current_phase_index as usize)
    }

    #[must_use]
    pub fn is_terminal(&self) -> bool {
        self.status.is_terminal()
    }
}

// ---------------------------------------------------------------------------
// Mutation Command
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct MutateRunCommand {
    pub kind: RunMutationKind,
    pub project_path: String,
    pub run_id: String,
    pub method_id: Option<String>,
    pub involvement: Option<InvolvementLevel>,
    pub checkpoint_kind: Option<CheckpointKind>,
    pub checkpoint_title: Option<String>,
    pub checkpoint_summary: Option<String>,
    pub checkpoint_brief_path: Option<String>,
    pub checkpoint_manifest_path: Option<String>,
    pub checkpoint_media_artifacts: Vec<MediaArtifact>,
    pub checkpoint_mermaid_sources: Vec<MermaidSource>,
    pub capture_requested: bool,
    /// URL to capture via agent-browser (e.g., "http://localhost:3000").
    pub capture_url: Option<String>,
    pub decision_action: Option<String>,
    pub decision_note: Option<String>,
    pub session_id: Option<String>,
    pub delegation_worker_id: Option<String>,
    /// Media artifact paths to attach via CaptureComplete.
    pub completed_media_artifacts: Vec<MediaArtifact>,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generate a simple run-scoped checkpoint ID.
#[must_use]
pub fn next_checkpoint_id(run_id: &str, phase_id: &str) -> String {
    format!(
        "{run_id}:{phase_id}:ckpt-{}",
        now_rfc3339().replace(':', "-")
    )
}
