//! Run Kernel domain types.
//!
//! These types implement the Run Kernel with Methods and Checkpoints architecture
//! (Option 2 from ARCHITECTURE_OPTIONS.md). They coexist with the existing
//! delegation types during the strangler-pattern migration.

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

/// Run-mutation payload, carried as the typed discriminant of [`MutateRunCommand`].
///
/// Each variant carries ONLY the fields its reducer handler reads. This is the
/// domain type the reducer and FFI consume — it is intentionally NOT serde-derived.
///
/// The on-the-wire shape is a FLAT object —
/// `{ "kind": "...", "project_path": ..., "run_id": ..., <variant fields> }` —
/// produced/consumed by the hand-written `Serialize`/`Deserialize` impls on
/// [`MutateRunCommand`] via the private [`MutateRunCommandWire`] DTO. We avoid
/// `#[serde(flatten)]` + an internally-tagged enum here: that combination buffers
/// through `serde::__private::de::Content` and is a known-fragile pattern. The
/// explicit DTO+projection keeps the wire FLAT and backward-compatible (every
/// historical frame still deserializes) while removing that fragility.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RunMutationKind {
    Create {
        method_id: Option<String>,
        involvement: Option<InvolvementLevel>,
        delegation_worker_id: Option<String>,
        idea_id: Option<String>,
        idea_title: Option<String>,
        idea_description: Option<String>,
    },
    Start {
        status_message: Option<String>,
    },
    Heartbeat {
        status_message: Option<String>,
    },
    AdvancePhase,
    EmitCheckpoint {
        checkpoint_kind: Option<CheckpointKind>,
        checkpoint_title: Option<String>,
        checkpoint_summary: Option<String>,
        checkpoint_brief_path: Option<String>,
        checkpoint_manifest_path: Option<String>,
        checkpoint_media_artifacts: Vec<MediaArtifact>,
        checkpoint_mermaid_sources: Vec<MermaidSource>,
        checkpoint_decision_relay: Option<CheckpointDecisionRelay>,
        capture_url: Option<String>,
        checkpoint_id: Option<String>,
    },
    SubmitDecision {
        checkpoint_id: Option<String>,
        decision_action: Option<String>,
        decision_note: Option<String>,
    },
    AttachSession {
        session_id: Option<String>,
        delegation_worker_id: Option<String>,
    },
    DetachSession,
    CaptureClaim {
        checkpoint_id: Option<String>,
        capture_request_id: Option<String>,
        client_id: Option<String>,
        observed_capture_url: Option<String>,
    },
    CaptureFailed {
        checkpoint_id: Option<String>,
        capture_request_id: Option<String>,
        capture_failure_reason: Option<String>,
    },
    CaptureComplete {
        checkpoint_id: Option<String>,
        capture_request_id: Option<String>,
        completed_media_artifacts: Vec<MediaArtifact>,
    },
    Pause {
        status_message: Option<String>,
    },
    Resume {
        status_message: Option<String>,
    },
    Complete {
        status_message: Option<String>,
    },
    Fail {
        status_message: Option<String>,
    },
    Cancel {
        status_message: Option<String>,
    },
}

impl RunMutationKind {
    /// The `checkpoint_id` carried by whichever variant addresses a checkpoint.
    ///
    /// Cross-cutting consumers (the HTTP handler's decision-relay path and the
    /// checkpoint-bridge relay reader) read this without caring which variant
    /// produced it. Returns `None` for variants that have no checkpoint id.
    #[must_use]
    pub fn checkpoint_id(&self) -> Option<&str> {
        match self {
            Self::EmitCheckpoint { checkpoint_id, .. }
            | Self::SubmitDecision { checkpoint_id, .. }
            | Self::CaptureClaim { checkpoint_id, .. }
            | Self::CaptureFailed { checkpoint_id, .. }
            | Self::CaptureComplete { checkpoint_id, .. } => checkpoint_id.as_deref(),
            _ => None,
        }
    }

    /// `true` when this is a `SubmitDecision` mutation. Lets cross-cutting
    /// consumers branch on the discriminant without spelling out the payload.
    #[must_use]
    pub fn is_submit_decision(&self) -> bool {
        matches!(self, Self::SubmitDecision { .. })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointDecisionRelay {
    CheckpointBridge,
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
    InProgress,
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
    /// URL to capture via agent-browser at checkpoint time (e.g., "http://localhost:3000").
    pub capture_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CheckpointDecision {
    pub action: String,
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct CaptureClaim {
    pub capture_request_id: String,
    pub client_id: String,
    pub claimed_at: String,
    #[serde(default)]
    pub observed_capture_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ActiveCheckpoint {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub history_ordinal: Option<u64>,
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
    #[serde(default)]
    pub capture_claim: Option<CaptureClaim>,
    #[serde(default)]
    pub decision_relay: Option<CheckpointDecisionRelay>,
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
    #[serde(default)]
    pub past_checkpoints: Vec<ActiveCheckpoint>,
    #[serde(default)]
    pub next_checkpoint_history_ordinal: u64,
    pub session_id: Option<String>,
    /// Strangler bridge: links to existing delegation worker when in execution phase.
    pub delegation_worker_id: Option<String>,
    /// Human-readable progress message set by Start and Heartbeat mutations.
    #[serde(default)]
    pub status_message: Option<String>,
    /// Idea identity — set on Create, immutable after.
    #[serde(default)]
    pub idea_id: Option<String>,
    #[serde(default)]
    pub idea_title: Option<String>,
    #[serde(default)]
    pub idea_description: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl RunState {
    #[must_use]
    pub fn current_phase(&self) -> Option<&PhaseInstance> {
        self.phases.get(self.current_phase_index as usize)
    }
}

// ---------------------------------------------------------------------------
// Mutation Command
// ---------------------------------------------------------------------------

/// A run mutation addressed to a single run.
///
/// `project_path` + `run_id` identify the run uniformly across every mutation
/// kind; the per-kind payload lives in [`RunMutationKind`].
///
/// # Wire shape
///
/// This is a `uniffi::Record` (UniFFI uses its own codec, NOT serde) and the
/// domain type the reducer consumes. Its JSON representation — exchanged over the
/// runtime-service HTTP boundary — is a FLAT object:
///
/// ```text
/// { "kind": "...", "project_path": ..., "run_id": ..., <variant fields> }
/// ```
///
/// The serde impls are HAND-WRITTEN (see [`MutateRunCommandWire`]) rather than
/// derived. We deliberately do NOT use `#[serde(flatten)]` over an
/// internally-tagged enum: that pairing buffers every field through
/// `serde::__private::de::Content` and is a documented-fragile pattern (it can
/// mishandle number coercion and self-describing-format edge cases). The explicit
/// DTO + projection keeps the wire FLAT and deserialization-compatible (every
/// historical frame still decodes; the serialized object now carries only the
/// active variant's payload keys) while removing the fragile flatten path entirely.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MutateRunCommand {
    pub project_path: String,
    pub run_id: String,
    pub kind: RunMutationKind,
}

/// Private FLAT wire DTO mirroring the historical pre-sum-type `MutateRunCommand`
/// field set byte-for-byte. Plain serde derive — NO `flatten`, NO internally-tagged
/// enum. Optional payload fields default to `None` when absent (matching the
/// Swift-shaped frames that omit keys their struct lacks, e.g.
/// `checkpoint_decision_relay`). The three `Vec` payload fields are modeled as
/// `Option<Vec<_>>` so that "absent key" is distinguishable from "empty array":
/// projection requires them within the variants that read them, reproducing the
/// historical `missing field` error for those variants.
#[derive(serde::Serialize, serde::Deserialize)]
struct MutateRunCommandWire {
    kind: String,
    project_path: String,
    run_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    method_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    involvement: Option<InvolvementLevel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    delegation_worker_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    idea_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    idea_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    idea_description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    status_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_kind: Option<CheckpointKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_brief_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_manifest_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_media_artifacts: Option<Vec<MediaArtifact>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_mermaid_sources: Option<Vec<MermaidSource>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_decision_relay: Option<CheckpointDecisionRelay>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capture_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoint_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    decision_action: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    decision_note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capture_request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    client_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    observed_capture_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capture_failure_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    completed_media_artifacts: Option<Vec<MediaArtifact>>,
}

impl MutateRunCommandWire {
    /// The snake_case `kind` discriminator for a typed [`RunMutationKind`].
    /// Mirrors the historical `#[serde(rename_all = "snake_case")]` mapping.
    fn kind_tag(kind: &RunMutationKind) -> &'static str {
        match kind {
            RunMutationKind::Create { .. } => "create",
            RunMutationKind::Start { .. } => "start",
            RunMutationKind::Heartbeat { .. } => "heartbeat",
            RunMutationKind::AdvancePhase => "advance_phase",
            RunMutationKind::EmitCheckpoint { .. } => "emit_checkpoint",
            RunMutationKind::SubmitDecision { .. } => "submit_decision",
            RunMutationKind::AttachSession { .. } => "attach_session",
            RunMutationKind::DetachSession => "detach_session",
            RunMutationKind::CaptureClaim { .. } => "capture_claim",
            RunMutationKind::CaptureFailed { .. } => "capture_failed",
            RunMutationKind::CaptureComplete { .. } => "capture_complete",
            RunMutationKind::Pause { .. } => "pause",
            RunMutationKind::Resume { .. } => "resume",
            RunMutationKind::Complete { .. } => "complete",
            RunMutationKind::Fail { .. } => "fail",
            RunMutationKind::Cancel { .. } => "cancel",
        }
    }
}

impl serde::Serialize for MutateRunCommand {
    /// Emit the FLAT wire object. Mirrors the historical internally-tagged +
    /// flattened serialization exactly: `kind`, `project_path`, `run_id`, then
    /// ONLY the active variant's fields (Options as explicit `null`, Vecs as `[]`).
    ///
    /// We serialize each field by name into a map so the active variant's fields
    /// are present (never skipped). This is intentionally NOT a pass-through of
    /// [`MutateRunCommandWire`] (whose fields are `skip_serializing_if`): a
    /// derived DTO with all-skipping options would drop the explicit `null`s the
    /// historical wire carried.
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeMap;

        // Field count = 3 framing keys + the active variant's field count.
        let payload_len = match &self.kind {
            RunMutationKind::AdvancePhase | RunMutationKind::DetachSession => 0,
            RunMutationKind::Start { .. }
            | RunMutationKind::Heartbeat { .. }
            | RunMutationKind::Pause { .. }
            | RunMutationKind::Resume { .. }
            | RunMutationKind::Complete { .. }
            | RunMutationKind::Fail { .. }
            | RunMutationKind::Cancel { .. } => 1,
            RunMutationKind::AttachSession { .. } => 2,
            RunMutationKind::SubmitDecision { .. }
            | RunMutationKind::CaptureFailed { .. }
            | RunMutationKind::CaptureComplete { .. } => 3,
            RunMutationKind::CaptureClaim { .. } => 4,
            RunMutationKind::Create { .. } => 6,
            RunMutationKind::EmitCheckpoint { .. } => 10,
        };

        let mut map = serializer.serialize_map(Some(3 + payload_len))?;
        map.serialize_entry("kind", MutateRunCommandWire::kind_tag(&self.kind))?;
        map.serialize_entry("project_path", &self.project_path)?;
        map.serialize_entry("run_id", &self.run_id)?;

        match &self.kind {
            RunMutationKind::Create {
                method_id,
                involvement,
                delegation_worker_id,
                idea_id,
                idea_title,
                idea_description,
            } => {
                map.serialize_entry("method_id", method_id)?;
                map.serialize_entry("involvement", involvement)?;
                map.serialize_entry("delegation_worker_id", delegation_worker_id)?;
                map.serialize_entry("idea_id", idea_id)?;
                map.serialize_entry("idea_title", idea_title)?;
                map.serialize_entry("idea_description", idea_description)?;
            }
            RunMutationKind::Start { status_message }
            | RunMutationKind::Heartbeat { status_message }
            | RunMutationKind::Pause { status_message }
            | RunMutationKind::Resume { status_message }
            | RunMutationKind::Complete { status_message }
            | RunMutationKind::Fail { status_message }
            | RunMutationKind::Cancel { status_message } => {
                map.serialize_entry("status_message", status_message)?;
            }
            RunMutationKind::AdvancePhase | RunMutationKind::DetachSession => {}
            RunMutationKind::EmitCheckpoint {
                checkpoint_kind,
                checkpoint_title,
                checkpoint_summary,
                checkpoint_brief_path,
                checkpoint_manifest_path,
                checkpoint_media_artifacts,
                checkpoint_mermaid_sources,
                checkpoint_decision_relay,
                capture_url,
                checkpoint_id,
            } => {
                map.serialize_entry("checkpoint_kind", checkpoint_kind)?;
                map.serialize_entry("checkpoint_title", checkpoint_title)?;
                map.serialize_entry("checkpoint_summary", checkpoint_summary)?;
                map.serialize_entry("checkpoint_brief_path", checkpoint_brief_path)?;
                map.serialize_entry("checkpoint_manifest_path", checkpoint_manifest_path)?;
                map.serialize_entry("checkpoint_media_artifacts", checkpoint_media_artifacts)?;
                map.serialize_entry("checkpoint_mermaid_sources", checkpoint_mermaid_sources)?;
                map.serialize_entry("checkpoint_decision_relay", checkpoint_decision_relay)?;
                map.serialize_entry("capture_url", capture_url)?;
                map.serialize_entry("checkpoint_id", checkpoint_id)?;
            }
            RunMutationKind::SubmitDecision {
                checkpoint_id,
                decision_action,
                decision_note,
            } => {
                map.serialize_entry("checkpoint_id", checkpoint_id)?;
                map.serialize_entry("decision_action", decision_action)?;
                map.serialize_entry("decision_note", decision_note)?;
            }
            RunMutationKind::AttachSession {
                session_id,
                delegation_worker_id,
            } => {
                map.serialize_entry("session_id", session_id)?;
                map.serialize_entry("delegation_worker_id", delegation_worker_id)?;
            }
            RunMutationKind::CaptureClaim {
                checkpoint_id,
                capture_request_id,
                client_id,
                observed_capture_url,
            } => {
                map.serialize_entry("checkpoint_id", checkpoint_id)?;
                map.serialize_entry("capture_request_id", capture_request_id)?;
                map.serialize_entry("client_id", client_id)?;
                map.serialize_entry("observed_capture_url", observed_capture_url)?;
            }
            RunMutationKind::CaptureFailed {
                checkpoint_id,
                capture_request_id,
                capture_failure_reason,
            } => {
                map.serialize_entry("checkpoint_id", checkpoint_id)?;
                map.serialize_entry("capture_request_id", capture_request_id)?;
                map.serialize_entry("capture_failure_reason", capture_failure_reason)?;
            }
            RunMutationKind::CaptureComplete {
                checkpoint_id,
                capture_request_id,
                completed_media_artifacts,
            } => {
                map.serialize_entry("checkpoint_id", checkpoint_id)?;
                map.serialize_entry("capture_request_id", capture_request_id)?;
                map.serialize_entry("completed_media_artifacts", completed_media_artifacts)?;
            }
        }

        map.end()
    }
}

impl<'de> serde::Deserialize<'de> for MutateRunCommand {
    /// Deserialize the FLAT wire object via [`MutateRunCommandWire`] and project
    /// into the typed variant selected by the `kind` discriminator. Each variant
    /// pulls the fields it reads and ignores the rest. An unknown `kind` is a
    /// hard error. The three `Vec` fields are required WITHIN the variants that
    /// read them, reproducing the historical per-variant `missing field` error.
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error as _;

        let wire = MutateRunCommandWire::deserialize(deserializer)?;

        // Helper: a `Vec` field that is required within its variant.
        fn require_vec<T, E: serde::de::Error>(
            value: Option<Vec<T>>,
            field: &'static str,
        ) -> Result<Vec<T>, E> {
            value.ok_or_else(|| E::missing_field(field))
        }

        let kind = match wire.kind.as_str() {
            "create" => RunMutationKind::Create {
                method_id: wire.method_id,
                involvement: wire.involvement,
                delegation_worker_id: wire.delegation_worker_id,
                idea_id: wire.idea_id,
                idea_title: wire.idea_title,
                idea_description: wire.idea_description,
            },
            "start" => RunMutationKind::Start {
                status_message: wire.status_message,
            },
            "heartbeat" => RunMutationKind::Heartbeat {
                status_message: wire.status_message,
            },
            "advance_phase" => RunMutationKind::AdvancePhase,
            "emit_checkpoint" => RunMutationKind::EmitCheckpoint {
                checkpoint_kind: wire.checkpoint_kind,
                checkpoint_title: wire.checkpoint_title,
                checkpoint_summary: wire.checkpoint_summary,
                checkpoint_brief_path: wire.checkpoint_brief_path,
                checkpoint_manifest_path: wire.checkpoint_manifest_path,
                checkpoint_media_artifacts: require_vec::<_, D::Error>(
                    wire.checkpoint_media_artifacts,
                    "checkpoint_media_artifacts",
                )?,
                checkpoint_mermaid_sources: require_vec::<_, D::Error>(
                    wire.checkpoint_mermaid_sources,
                    "checkpoint_mermaid_sources",
                )?,
                checkpoint_decision_relay: wire.checkpoint_decision_relay,
                capture_url: wire.capture_url,
                checkpoint_id: wire.checkpoint_id,
            },
            "submit_decision" => RunMutationKind::SubmitDecision {
                checkpoint_id: wire.checkpoint_id,
                decision_action: wire.decision_action,
                decision_note: wire.decision_note,
            },
            "attach_session" => RunMutationKind::AttachSession {
                session_id: wire.session_id,
                delegation_worker_id: wire.delegation_worker_id,
            },
            "detach_session" => RunMutationKind::DetachSession,
            "capture_claim" => RunMutationKind::CaptureClaim {
                checkpoint_id: wire.checkpoint_id,
                capture_request_id: wire.capture_request_id,
                client_id: wire.client_id,
                observed_capture_url: wire.observed_capture_url,
            },
            "capture_failed" => RunMutationKind::CaptureFailed {
                checkpoint_id: wire.checkpoint_id,
                capture_request_id: wire.capture_request_id,
                capture_failure_reason: wire.capture_failure_reason,
            },
            "capture_complete" => RunMutationKind::CaptureComplete {
                checkpoint_id: wire.checkpoint_id,
                capture_request_id: wire.capture_request_id,
                completed_media_artifacts: require_vec::<_, D::Error>(
                    wire.completed_media_artifacts,
                    "completed_media_artifacts",
                )?,
            },
            "pause" => RunMutationKind::Pause {
                status_message: wire.status_message,
            },
            "resume" => RunMutationKind::Resume {
                status_message: wire.status_message,
            },
            "complete" => RunMutationKind::Complete {
                status_message: wire.status_message,
            },
            "fail" => RunMutationKind::Fail {
                status_message: wire.status_message,
            },
            "cancel" => RunMutationKind::Cancel {
                status_message: wire.status_message,
            },
            other => {
                return Err(D::Error::custom(format!(
                    "unknown run mutation kind `{other}`"
                )))
            }
        };

        Ok(MutateRunCommand {
            project_path: wire.project_path,
            run_id: wire.run_id,
            kind,
        })
    }
}
