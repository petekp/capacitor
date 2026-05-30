//! Wire-contract oracle for `MutateRunCommand` / `RunMutationKind`.
//!
//! This test pins the DESERIALIZATION + reducer behavior of the run-mutation
//! wire protocol so it survives the upcoming sum-type refactor of
//! `MutateRunCommand`. It deliberately does NOT pin exact serialization
//! (`serde_json::to_string`) — the on-the-wire SHAPE Rust emits will
//! legitimately change when the flat 27-field record becomes a sum type.
//!
//! What is pinned (the contract producers depend on today):
//!   1. For EACH of the 16 `RunMutationKind` variants, the representative wire
//!      JSON exactly as the producers send it TODAY decodes via
//!      `serde_json::from_str::<MutateRunCommand>`.
//!      - Swift `RuntimeRunMutationRequest` flat frames (snake_case keys, with
//!        the `kind` discriminator + only that kind's payload fields populated;
//!        every other field nil → JSON `null`, arrays → `[]`).
//!        Source of truth: `apps/swift/.../RuntimeClientTypes.swift` factories
//!        (`create` / `submitDecision` / `captureClaim` / `captureFailed` /
//!        `captureComplete` / `status`).
//!      - Rust-only frames produced by
//!        `method_runner/run_status_reporter.rs` (status family) and
//!        `method_runner/checkpoint_bridge.rs` (`emit_checkpoint`,
//!        which is the only producer of `checkpoint_decision_relay`).
//!   2. Feeding the decoded command through the live reducer
//!      (`CoreRuntime::mutate_run`, which calls `apply_run_mutation`) produces
//!      the expected per-kind outcome, and the fields that kind READS are
//!      honored in the resulting `RunState`.
//!   3. The `checkpoint_decision_relay` asymmetry: Swift's flat request struct
//!      has NO `checkpoint_decision_relay` key, so a Swift-shaped frame omits
//!      it entirely. An `emit_checkpoint` frame WITHOUT that key must still
//!      decode (it is `#[serde(default)]`). The checkpoint bridge frame, which
//!      DOES send `checkpoint_decision_relay: "checkpoint_bridge"`, must also
//!      decode and be honored.
//!
//! The 16 representative JSON frames are defined as `const &str` so the Refactor
//! stage can reuse them verbatim as the input corpus for the new sum type.

use capacitor_core::domain::{
    CaptureStatus, CheckpointDecisionRelay, CheckpointStatus, InvolvementLevel, MutateRunCommand,
    RunMutationKind, RunState, RunStatus,
};
use capacitor_core::CoreRuntime;

// ---------------------------------------------------------------------------
// Representative wire frames (the refactor stage reuses these verbatim)
// ---------------------------------------------------------------------------
//
// Naming convention:
//   *_SWIFT_*  → produced by the Swift `RuntimeRunMutationRequest` factories.
//                These carry EVERY struct field as an explicit `null`/`[]` and
//                have NO `checkpoint_decision_relay` key.
//   *_RUST_*   → produced by Rust-only adapters (status reporter / checkpoint
//                bridge). These are serde-serialized `MutateRunCommand`s and so
//                DO carry `checkpoint_decision_relay` (as `null` or a value).

/// Frame 1 (`create`) — Swift `RuntimeRunMutationRequest.create`. Real producer
/// fills project_path/run_id/method_id/involvement/idea_*.
const CREATE_SWIFT: &str = r#"{
  "kind": "create",
  "project_path": "/wire/create",
  "run_id": "run-create",
  "checkpoint_id": null,
  "method_id": "execution_only",
  "involvement": "autonomous",
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": "idea-42",
  "idea_title": "Wire oracle",
  "idea_description": "Pin the wire contract"
}"#;

/// 2. `start` — Swift `RuntimeRunMutationRequest.status(kind: "start")`.
const START_SWIFT: &str = r#"{
  "kind": "start",
  "project_path": "/wire/start",
  "run_id": "run-start",
  "checkpoint_id": null,
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "Booting up",
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// Frame 3 (`heartbeat`) — Rust `run_status_reporter` frame (serde-serialized
/// `MutateRunCommand`, so it carries `checkpoint_decision_relay: null`).
const HEARTBEAT_RUST: &str = r#"{
  "kind": "heartbeat",
  "project_path": "/wire/heartbeat",
  "run_id": "run-heartbeat",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "Working on phase",
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 4. `advance_phase` — Rust `run_status_reporter` frame (no payload fields).
const ADVANCE_PHASE_RUST: &str = r#"{
  "kind": "advance_phase",
  "project_path": "/wire/advance",
  "run_id": "run-advance",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// Frame 5 (`emit_checkpoint`) — Rust `checkpoint_bridge` frame. This is the
/// ONLY producer that sets `checkpoint_decision_relay`.
const EMIT_CHECKPOINT_BRIDGE_RUST: &str = r#"{
  "kind": "emit_checkpoint",
  "project_path": "/wire/emit",
  "run_id": "run-emit",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": "implementation_milestone",
  "checkpoint_title": "Milestone 1",
  "checkpoint_summary": "First milestone reached",
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": "/wire/emit/manifest.json",
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": "checkpoint_bridge",
  "capture_url": null,
  "checkpoint_id": "gate-emit-1",
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 5b. `emit_checkpoint` — Swift-SHAPED frame WITHOUT `checkpoint_decision_relay`.
/// Swift's `RuntimeRunMutationRequest` struct has no such key, so the field is
/// absent from the wire entirely. This MUST decode (it is `#[serde(default)]`).
/// Used to pin the relay asymmetry described in the module docs.
const EMIT_CHECKPOINT_SWIFT_NO_RELAY: &str = r#"{
  "kind": "emit_checkpoint",
  "project_path": "/wire/emit-no-relay",
  "run_id": "run-emit-no-relay",
  "checkpoint_id": "gate-emit-no-relay",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": "proposal",
  "checkpoint_title": "Proposal A",
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// 6. `submit_decision` — Swift `RuntimeRunMutationRequest.submitDecision`.
const SUBMIT_DECISION_SWIFT: &str = r#"{
  "kind": "submit_decision",
  "project_path": "/wire/decision",
  "run_id": "run-decision",
  "checkpoint_id": "gate-decision-1",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": "approve",
  "decision_note": "Looks good",
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// Frame 7 (`attach_session`) — Rust-shaped frame (serde-serialized command).
/// The runtime attaches a session_id and optionally a delegation_worker_id.
const ATTACH_SESSION_RUST: &str = r#"{
  "kind": "attach_session",
  "project_path": "/wire/attach",
  "run_id": "run-attach",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": "session-attach",
  "delegation_worker_id": "worker-attach",
  "status_message": null,
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 8. `detach_session` — Rust-shaped frame (no payload fields read).
const DETACH_SESSION_RUST: &str = r#"{
  "kind": "detach_session",
  "project_path": "/wire/detach",
  "run_id": "run-detach",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 9. `capture_claim` — Swift `RuntimeRunMutationRequest.captureClaim`.
const CAPTURE_CLAIM_SWIFT: &str = r#"{
  "kind": "capture_claim",
  "project_path": "/wire/claim",
  "run_id": "run-claim",
  "checkpoint_id": "gate-claim-1",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": "cap-req-1",
  "client_id": "client-1",
  "observed_capture_url": "http://localhost:3000",
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// 10. `capture_failed` — Swift `RuntimeRunMutationRequest.captureFailed`.
const CAPTURE_FAILED_SWIFT: &str = r#"{
  "kind": "capture_failed",
  "project_path": "/wire/failed",
  "run_id": "run-failed",
  "checkpoint_id": "gate-failed-1",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": "cap-req-2",
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": "browser launch failed",
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// 11. `capture_complete` — Swift `RuntimeRunMutationRequest.captureComplete`.
const CAPTURE_COMPLETE_SWIFT: &str = r#"{
  "kind": "capture_complete",
  "project_path": "/wire/complete",
  "run_id": "run-complete",
  "checkpoint_id": "gate-complete-1",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": "cap-req-3",
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [
    {
      "artifact_type": "screenshot",
      "path": "/wire/complete/shot.png",
      "label": "Homepage",
      "width": 1280,
      "height": 720,
      "duration_secs": null
    }
  ],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// 12. `pause` — Swift `RuntimeRunMutationRequest.status(kind: "pause")`.
const PAUSE_SWIFT: &str = r#"{
  "kind": "pause",
  "project_path": "/wire/pause",
  "run_id": "run-pause",
  "checkpoint_id": null,
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "Pausing for review",
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// 13. `resume` — Rust `run_status_reporter` frame.
const RESUME_RUST: &str = r#"{
  "kind": "resume",
  "project_path": "/wire/resume",
  "run_id": "run-resume",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "Resuming work",
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 14. `complete` — Rust `run_status_reporter` frame.
const COMPLETE_RUST: &str = r#"{
  "kind": "complete",
  "project_path": "/wire/complete-run",
  "run_id": "run-complete-run",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "All done",
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 15. `fail` — Rust `run_status_reporter` frame.
const FAIL_RUST: &str = r#"{
  "kind": "fail",
  "project_path": "/wire/fail",
  "run_id": "run-fail",
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "checkpoint_decision_relay": null,
  "capture_url": null,
  "checkpoint_id": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": "Build failed",
  "idea_id": null,
  "idea_title": null,
  "idea_description": null,
  "completed_media_artifacts": []
}"#;

/// 16. `cancel` — Swift `RuntimeRunMutationRequest.status(kind: "cancel")`.
const CANCEL_SWIFT: &str = r#"{
  "kind": "cancel",
  "project_path": "/wire/cancel",
  "run_id": "run-cancel",
  "checkpoint_id": null,
  "method_id": null,
  "involvement": null,
  "checkpoint_kind": null,
  "checkpoint_title": null,
  "checkpoint_summary": null,
  "checkpoint_brief_path": null,
  "checkpoint_manifest_path": null,
  "checkpoint_media_artifacts": [],
  "checkpoint_mermaid_sources": [],
  "capture_url": null,
  "decision_action": null,
  "decision_note": null,
  "session_id": null,
  "delegation_worker_id": null,
  "status_message": null,
  "capture_request_id": null,
  "client_id": null,
  "observed_capture_url": null,
  "capture_failure_reason": null,
  "completed_media_artifacts": [],
  "idea_id": null,
  "idea_title": null,
  "idea_description": null
}"#;

/// The full corpus of representative frames, exported for the refactor stage.
/// Each entry is `(label, expected_kind_tag, wire_json)`.
///
/// `expected_kind_tag` is the internally-tagged serde discriminator the frame
/// must decode into (the `kind` field on the FLAT wire object). After the
/// sum-type refactor the decoded `RunMutationKind` is a struct variant, so the
/// oracle compares discriminators via [`kind_tag`] rather than `==` on a value.
const WIRE_FRAMES: &[(&str, &str, &str)] = &[
    ("create", "create", CREATE_SWIFT),
    ("start", "start", START_SWIFT),
    ("heartbeat", "heartbeat", HEARTBEAT_RUST),
    ("advance_phase", "advance_phase", ADVANCE_PHASE_RUST),
    (
        "emit_checkpoint",
        "emit_checkpoint",
        EMIT_CHECKPOINT_BRIDGE_RUST,
    ),
    ("submit_decision", "submit_decision", SUBMIT_DECISION_SWIFT),
    ("attach_session", "attach_session", ATTACH_SESSION_RUST),
    ("detach_session", "detach_session", DETACH_SESSION_RUST),
    ("capture_claim", "capture_claim", CAPTURE_CLAIM_SWIFT),
    ("capture_failed", "capture_failed", CAPTURE_FAILED_SWIFT),
    (
        "capture_complete",
        "capture_complete",
        CAPTURE_COMPLETE_SWIFT,
    ),
    ("pause", "pause", PAUSE_SWIFT),
    ("resume", "resume", RESUME_RUST),
    ("complete", "complete", COMPLETE_RUST),
    ("fail", "fail", FAIL_RUST),
    ("cancel", "cancel", CANCEL_SWIFT),
];

/// The internally-tagged serde discriminator for a decoded [`RunMutationKind`].
///
/// Mirrors the `#[serde(tag = "kind", rename_all = "snake_case")]` mapping so
/// the oracle can assert "this frame decoded to the variant whose `kind` is X"
/// without re-spelling each variant's payload.
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn decode(json: &str) -> MutateRunCommand {
    serde_json::from_str::<MutateRunCommand>(json)
        .unwrap_or_else(|err| panic!("wire frame must decode: {err}\n{json}"))
}

/// Apply a wire frame through the live reducer entry point and return the run
/// that the frame addressed (keyed by `project_path` + `run_id`).
fn apply_and_find(
    runtime: &CoreRuntime,
    json: &str,
) -> (capacitor_core::domain::MutationOutcome, Option<RunState>) {
    let command = decode(json);
    let project_path = command.project_path.clone();
    let run_id = command.run_id.clone();
    let outcome = runtime.mutate_run(command).expect("mutate_run");
    let run = runtime
        .app_snapshot()
        .expect("snapshot")
        .runs
        .into_iter()
        .find(|run| run.id == run_id && run.project_path == project_path);
    (outcome, run)
}

/// Seed a fresh run via the canonical `create` wire frame so per-kind tests can
/// build on a known-good starting state. Re-targets the create frame onto the
/// given project/run so each test stays isolated.
fn seed_created_run(runtime: &CoreRuntime, project_path: &str, run_id: &str, method_id: &str) {
    let mut command = decode(CREATE_SWIFT);
    command.project_path = project_path.to_string();
    command.run_id = run_id.to_string();
    if let RunMutationKind::Create {
        method_id: cmd_method_id,
        involvement,
        ..
    } = &mut command.kind
    {
        *cmd_method_id = Some(method_id.to_string());
        *involvement = None;
    } else {
        panic!("CREATE_SWIFT must decode to a create command");
    }
    let outcome = runtime.mutate_run(command).expect("seed create");
    assert!(outcome.ok, "seed create failed: {}", outcome.message);
}

fn status_command(json: &str, project_path: &str, run_id: &str) -> MutateRunCommand {
    let mut command = decode(json);
    command.project_path = project_path.to_string();
    command.run_id = run_id.to_string();
    command
}

/// Decode the bridge `emit_checkpoint` frame, re-target it onto the given
/// run, and override its `checkpoint_id`/`capture_url`. These fields now live
/// inside the `EmitCheckpoint` variant, so the override happens via the
/// variant binding instead of flat command fields.
fn emit_checkpoint_command(
    project_path: &str,
    run_id: &str,
    checkpoint_id: &str,
    capture_url: Option<&str>,
) -> MutateRunCommand {
    let mut command = decode(EMIT_CHECKPOINT_BRIDGE_RUST);
    command.project_path = project_path.to_string();
    command.run_id = run_id.to_string();
    let RunMutationKind::EmitCheckpoint {
        checkpoint_id: cmd_checkpoint_id,
        capture_url: cmd_capture_url,
        ..
    } = &mut command.kind
    else {
        panic!("EMIT_CHECKPOINT_BRIDGE_RUST must decode to emit_checkpoint");
    };
    *cmd_checkpoint_id = Some(checkpoint_id.to_string());
    if let Some(capture_url) = capture_url {
        *cmd_capture_url = Some(capture_url.to_string());
    }
    command
}

/// Decode the Swift `capture_claim` frame, re-target it, and override the
/// checkpoint/request/client identifiers carried inside the `CaptureClaim`
/// variant.
fn capture_claim_command(
    project_path: &str,
    run_id: &str,
    checkpoint_id: &str,
    capture_request_id: &str,
    client_id: &str,
) -> MutateRunCommand {
    let mut command = decode(CAPTURE_CLAIM_SWIFT);
    command.project_path = project_path.to_string();
    command.run_id = run_id.to_string();
    let RunMutationKind::CaptureClaim {
        checkpoint_id: cmd_checkpoint_id,
        capture_request_id: cmd_capture_request_id,
        client_id: cmd_client_id,
        ..
    } = &mut command.kind
    else {
        panic!("CAPTURE_CLAIM_SWIFT must decode to capture_claim");
    };
    *cmd_checkpoint_id = Some(checkpoint_id.to_string());
    *cmd_capture_request_id = Some(capture_request_id.to_string());
    *cmd_client_id = Some(client_id.to_string());
    command
}

// ---------------------------------------------------------------------------
// 1. Every frame decodes AND maps to its expected discriminator.
// ---------------------------------------------------------------------------

#[test]
fn all_sixteen_wire_frames_deserialize_to_expected_kind() {
    assert_eq!(
        WIRE_FRAMES.len(),
        16,
        "must cover all 16 RunMutationKind variants"
    );

    for (label, expected_tag, json) in WIRE_FRAMES {
        let command = serde_json::from_str::<MutateRunCommand>(json)
            .unwrap_or_else(|err| panic!("[{label}] frame failed to deserialize: {err}\n{json}"));
        assert_eq!(
            kind_tag(&command.kind),
            *expected_tag,
            "[{label}] decoded discriminator mismatch",
        );
        assert!(
            !command.project_path.is_empty(),
            "[{label}] project_path missing",
        );
        assert!(!command.run_id.is_empty(), "[{label}] run_id missing");
    }
}

// ---------------------------------------------------------------------------
// 2. checkpoint_decision_relay asymmetry (the headline of this oracle).
// ---------------------------------------------------------------------------

#[test]
fn emit_checkpoint_swift_frame_without_relay_decodes_to_none() {
    // Swift's RuntimeRunMutationRequest has no checkpoint_decision_relay key,
    // so the field is absent on the wire. #[serde(default)] must fill None.
    let command = decode(EMIT_CHECKPOINT_SWIFT_NO_RELAY);
    let RunMutationKind::EmitCheckpoint {
        checkpoint_decision_relay,
        ..
    } = command.kind
    else {
        panic!("expected emit_checkpoint, got {:?}", command.kind);
    };
    assert!(
        checkpoint_decision_relay.is_none(),
        "absent checkpoint_decision_relay must default to None",
    );
}

#[test]
fn emit_checkpoint_bridge_frame_with_relay_decodes_to_value() {
    let command = decode(EMIT_CHECKPOINT_BRIDGE_RUST);
    let RunMutationKind::EmitCheckpoint {
        checkpoint_decision_relay,
        ..
    } = command.kind
    else {
        panic!("expected emit_checkpoint, got {:?}", command.kind);
    };
    assert_eq!(
        checkpoint_decision_relay,
        Some(CheckpointDecisionRelay::CheckpointBridge),
        "checkpoint bridge frame must decode its relay value",
    );
}

#[test]
fn emit_checkpoint_relay_is_honored_by_reducer_both_ways() {
    // Relay present → ActiveCheckpoint.decision_relay = Some(CheckpointBridge).
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/emit", "run-emit", "execution_only");
    // Activate the run so the checkpoint can be emitted (Created -> Active).
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/emit", "run-emit");
    runtime.mutate_run(attach).expect("attach to activate");

    let (outcome, run) = apply_and_find(&runtime, EMIT_CHECKPOINT_BRIDGE_RUST);
    assert!(outcome.ok, "emit (relay) rejected: {}", outcome.message);
    let run = run.expect("emit run exists");
    let checkpoint = run.active_checkpoint.expect("active checkpoint");
    assert_eq!(
        checkpoint.decision_relay,
        Some(CheckpointDecisionRelay::CheckpointBridge),
        "reducer must honor the relay value from the bridge frame",
    );
    assert_eq!(checkpoint.id, "gate-emit-1");

    // Relay absent (Swift frame) → ActiveCheckpoint.decision_relay = None.
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(
        &runtime,
        "/wire/emit-no-relay",
        "run-emit-no-relay",
        "execution_only",
    );
    let attach = status_command(
        ATTACH_SESSION_RUST,
        "/wire/emit-no-relay",
        "run-emit-no-relay",
    );
    runtime.mutate_run(attach).expect("attach to activate");

    let (outcome, run) = apply_and_find(&runtime, EMIT_CHECKPOINT_SWIFT_NO_RELAY);
    assert!(outcome.ok, "emit (no relay) rejected: {}", outcome.message);
    let checkpoint = run
        .expect("emit-no-relay run exists")
        .active_checkpoint
        .expect("active checkpoint");
    assert!(
        checkpoint.decision_relay.is_none(),
        "absent relay must remain None through the reducer",
    );
}

// ---------------------------------------------------------------------------
// 3. Per-kind reducer behavior. Each test drives the live reducer and asserts
//    the fields THAT kind reads are honored.
// ---------------------------------------------------------------------------

#[test]
fn create_frame_builds_run_from_method_and_idea() {
    let runtime = CoreRuntime::new().expect("runtime");
    let (outcome, run) = apply_and_find(&runtime, CREATE_SWIFT);
    assert!(outcome.ok, "create rejected: {}", outcome.message);
    let run = run.expect("created run exists");

    assert_eq!(run.status, RunStatus::Created);
    assert_eq!(run.method_id, "execution_only");
    // involvement: "autonomous" override (method default is Supervised).
    assert_eq!(run.involvement, InvolvementLevel::Autonomous);
    assert_eq!(run.idea_id.as_deref(), Some("idea-42"));
    assert_eq!(run.idea_title.as_deref(), Some("Wire oracle"));
    assert_eq!(
        run.idea_description.as_deref(),
        Some("Pin the wire contract")
    );
    assert!(!run.phases.is_empty(), "method phases must be instantiated");
}

#[test]
fn start_frame_activates_run_and_sets_status_message() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/start", "run-start", "execution_only");

    let (outcome, run) = apply_and_find(&runtime, START_SWIFT);
    assert!(outcome.ok, "start rejected: {}", outcome.message);
    let run = run.expect("started run exists");
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.status_message.as_deref(), Some("Booting up"));
    // Start activates phase 0.
    assert_eq!(
        run.phases[0].status,
        capacitor_core::domain::PhaseStatus::Active
    );
}

#[test]
fn heartbeat_frame_updates_status_message() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(
        &runtime,
        "/wire/heartbeat",
        "run-heartbeat",
        "execution_only",
    );
    let start = status_command(START_SWIFT, "/wire/heartbeat", "run-heartbeat");
    runtime.mutate_run(start).expect("start before heartbeat");

    let (outcome, run) = apply_and_find(&runtime, HEARTBEAT_RUST);
    assert!(outcome.ok, "heartbeat rejected: {}", outcome.message);
    let run = run.expect("heartbeat run exists");
    assert_eq!(run.status_message.as_deref(), Some("Working on phase"));
    // Heartbeat does not change status.
    assert_eq!(run.status, RunStatus::Active);
}

#[test]
fn advance_phase_frame_completes_single_phase_run() {
    let runtime = CoreRuntime::new().expect("runtime");
    // execution_only has a single phase, so advancing completes the run.
    seed_created_run(&runtime, "/wire/advance", "run-advance", "execution_only");
    let start = status_command(START_SWIFT, "/wire/advance", "run-advance");
    runtime.mutate_run(start).expect("start before advance");

    let (outcome, run) = apply_and_find(&runtime, ADVANCE_PHASE_RUST);
    assert!(outcome.ok, "advance rejected: {}", outcome.message);
    let run = run.expect("advanced run exists");
    assert_eq!(run.status, RunStatus::Completed);
    assert_eq!(
        run.phases[0].status,
        capacitor_core::domain::PhaseStatus::Completed
    );
}

#[test]
fn submit_decision_frame_records_decision_and_resumes_run() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/decision", "run-decision", "execution_only");
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/decision", "run-decision");
    runtime.mutate_run(attach).expect("attach to activate");

    // Emit a checkpoint with the id the decision frame addresses.
    let emit = emit_checkpoint_command("/wire/decision", "run-decision", "gate-decision-1", None);
    let emit_outcome = runtime.mutate_run(emit).expect("emit before decision");
    assert!(emit_outcome.ok, "emit failed: {}", emit_outcome.message);

    let (outcome, run) = apply_and_find(&runtime, SUBMIT_DECISION_SWIFT);
    assert!(outcome.ok, "submit_decision rejected: {}", outcome.message);
    let run = run.expect("decided run exists");
    // approve -> run resumes Active, checkpoint archived.
    assert_eq!(run.status, RunStatus::Active);
    assert!(run.active_checkpoint.is_none());
    let archived = run.past_checkpoints.last().expect("archived checkpoint");
    assert_eq!(archived.status, CheckpointStatus::Decided);
    let decision = archived.decision.as_ref().expect("decision recorded");
    assert_eq!(decision.action, "approve");
    assert_eq!(decision.note.as_deref(), Some("Looks good"));
}

#[test]
fn attach_session_frame_links_session_and_worker() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/attach", "run-attach", "execution_only");

    let (outcome, run) = apply_and_find(&runtime, ATTACH_SESSION_RUST);
    assert!(outcome.ok, "attach_session rejected: {}", outcome.message);
    let run = run.expect("attached run exists");
    assert_eq!(run.session_id.as_deref(), Some("session-attach"));
    assert_eq!(run.delegation_worker_id.as_deref(), Some("worker-attach"));
    // First activation transitions Created -> Active.
    assert_eq!(run.status, RunStatus::Active);
}

#[test]
fn detach_session_frame_clears_session() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/detach", "run-detach", "execution_only");
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/detach", "run-detach");
    runtime.mutate_run(attach).expect("attach before detach");

    let (outcome, run) = apply_and_find(&runtime, DETACH_SESSION_RUST);
    assert!(outcome.ok, "detach_session rejected: {}", outcome.message);
    let run = run.expect("detached run exists");
    assert!(run.session_id.is_none(), "detach must clear session_id");
}

#[test]
fn capture_claim_frame_claims_pending_capture() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/claim", "run-claim", "execution_only");
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/claim", "run-claim");
    runtime.mutate_run(attach).expect("attach to activate");

    // Emit a checkpoint WITH a capture_url so capture_status is Pending.
    let emit = emit_checkpoint_command(
        "/wire/claim",
        "run-claim",
        "gate-claim-1",
        Some("http://localhost:3000"),
    );
    let emit_outcome = runtime.mutate_run(emit).expect("emit before claim");
    assert!(emit_outcome.ok, "emit failed: {}", emit_outcome.message);

    let (outcome, run) = apply_and_find(&runtime, CAPTURE_CLAIM_SWIFT);
    assert!(outcome.ok, "capture_claim rejected: {}", outcome.message);
    let run = run.expect("claim run exists");
    let checkpoint = run.active_checkpoint.expect("active checkpoint");
    assert_eq!(checkpoint.capture_status, CaptureStatus::InProgress);
    let claim = checkpoint.capture_claim.expect("capture claim recorded");
    assert_eq!(claim.capture_request_id, "cap-req-1");
    assert_eq!(claim.client_id, "client-1");
    assert_eq!(
        claim.observed_capture_url.as_deref(),
        Some("http://localhost:3000")
    );
}

#[test]
fn capture_failed_frame_marks_capture_failed() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/failed", "run-failed", "execution_only");
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/failed", "run-failed");
    runtime.mutate_run(attach).expect("attach to activate");

    // Emit checkpoint with capture_url + claim it so status is InProgress.
    let emit = emit_checkpoint_command(
        "/wire/failed",
        "run-failed",
        "gate-failed-1",
        Some("http://localhost:4000"),
    );
    runtime.mutate_run(emit).expect("emit before failed");

    let claim = capture_claim_command(
        "/wire/failed",
        "run-failed",
        "gate-failed-1",
        "cap-req-2",
        "client-fail",
    );
    let claim_outcome = runtime.mutate_run(claim).expect("claim before failed");
    assert!(claim_outcome.ok, "claim failed: {}", claim_outcome.message);

    let (outcome, run) = apply_and_find(&runtime, CAPTURE_FAILED_SWIFT);
    assert!(outcome.ok, "capture_failed rejected: {}", outcome.message);
    let run = run.expect("failed run exists");
    let checkpoint = run.active_checkpoint.expect("active checkpoint");
    assert_eq!(
        checkpoint.capture_status,
        CaptureStatus::Failed {
            reason: "browser launch failed".to_string(),
        },
        "capture_failure_reason must be honored",
    );
}

#[test]
fn capture_complete_frame_attaches_media_and_completes_capture() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/complete", "run-complete", "execution_only");
    let attach = status_command(ATTACH_SESSION_RUST, "/wire/complete", "run-complete");
    runtime.mutate_run(attach).expect("attach to activate");

    let emit = emit_checkpoint_command(
        "/wire/complete",
        "run-complete",
        "gate-complete-1",
        Some("http://localhost:5000"),
    );
    runtime.mutate_run(emit).expect("emit before complete");

    let claim = capture_claim_command(
        "/wire/complete",
        "run-complete",
        "gate-complete-1",
        "cap-req-3",
        "client-complete",
    );
    runtime.mutate_run(claim).expect("claim before complete");

    let (outcome, run) = apply_and_find(&runtime, CAPTURE_COMPLETE_SWIFT);
    assert!(outcome.ok, "capture_complete rejected: {}", outcome.message);
    let run = run.expect("complete run exists");
    let checkpoint = run.active_checkpoint.expect("active checkpoint");
    assert_eq!(checkpoint.capture_status, CaptureStatus::Completed);
    assert!(
        checkpoint
            .media_artifacts
            .iter()
            .any(|artifact| artifact.path == "/wire/complete/shot.png"),
        "completed_media_artifacts must be attached to the checkpoint",
    );
}

#[test]
fn pause_frame_transitions_run_to_paused() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/pause", "run-pause", "execution_only");
    let start = status_command(START_SWIFT, "/wire/pause", "run-pause");
    runtime.mutate_run(start).expect("start before pause");

    let (outcome, run) = apply_and_find(&runtime, PAUSE_SWIFT);
    assert!(outcome.ok, "pause rejected: {}", outcome.message);
    let run = run.expect("paused run exists");
    assert_eq!(run.status, RunStatus::Paused);
    assert_eq!(run.status_message.as_deref(), Some("Pausing for review"));
}

#[test]
fn resume_frame_transitions_paused_run_to_active() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/resume", "run-resume", "execution_only");
    let start = status_command(START_SWIFT, "/wire/resume", "run-resume");
    runtime.mutate_run(start).expect("start before resume");
    let pause = status_command(PAUSE_SWIFT, "/wire/resume", "run-resume");
    runtime.mutate_run(pause).expect("pause before resume");

    let (outcome, run) = apply_and_find(&runtime, RESUME_RUST);
    assert!(outcome.ok, "resume rejected: {}", outcome.message);
    let run = run.expect("resumed run exists");
    assert_eq!(run.status, RunStatus::Active);
    assert_eq!(run.status_message.as_deref(), Some("Resuming work"));
}

#[test]
fn complete_frame_marks_run_completed() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(
        &runtime,
        "/wire/complete-run",
        "run-complete-run",
        "execution_only",
    );
    let start = status_command(START_SWIFT, "/wire/complete-run", "run-complete-run");
    runtime.mutate_run(start).expect("start before complete");

    let (outcome, run) = apply_and_find(&runtime, COMPLETE_RUST);
    assert!(outcome.ok, "complete rejected: {}", outcome.message);
    let run = run.expect("completed run exists");
    assert_eq!(run.status, RunStatus::Completed);
    assert_eq!(run.status_message.as_deref(), Some("All done"));
}

#[test]
fn fail_frame_marks_run_failed() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/fail", "run-fail", "execution_only");
    let start = status_command(START_SWIFT, "/wire/fail", "run-fail");
    runtime.mutate_run(start).expect("start before fail");

    let (outcome, run) = apply_and_find(&runtime, FAIL_RUST);
    assert!(outcome.ok, "fail rejected: {}", outcome.message);
    let run = run.expect("failed run exists");
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.status_message.as_deref(), Some("Build failed"));
}

#[test]
fn cancel_frame_marks_run_cancelled() {
    let runtime = CoreRuntime::new().expect("runtime");
    seed_created_run(&runtime, "/wire/cancel", "run-cancel", "execution_only");
    let start = status_command(START_SWIFT, "/wire/cancel", "run-cancel");
    runtime.mutate_run(start).expect("start before cancel");

    let (outcome, run) = apply_and_find(&runtime, CANCEL_SWIFT);
    assert!(outcome.ok, "cancel rejected: {}", outcome.message);
    let run = run.expect("cancelled run exists");
    assert_eq!(run.status, RunStatus::Cancelled);
}

// ---------------------------------------------------------------------------
// 4. SERIALIZE-side oracle. The hand-written `impl Serialize for
//    MutateRunCommand` (run_types.rs) emits the FLAT wire object that the
//    production Rust producers (run_status_reporter.rs, checkpoint_bridge.rs)
//    actually put on the HTTP boundary. The deserialization oracle above does
//    NOT exercise this path, so a future edit to the per-variant
//    `serialize_entry` list (or the `payload_len` hint) could silently desync
//    the wire. These tests pin the emitted shape:
//
//      - the JSON is a FLAT object (no nesting, no `{ "kind": { ... } }` tag),
//      - its EXACT key set equals {kind, project_path, run_id, ...variant
//        fields} (full-set assertion: an added OR removed field fails),
//      - the `kind` tag string is the expected discriminator,
//      - round-trip: deserialize(serialize(cmd)) == cmd (identity).
//
//    Inputs are decoded from the representative producer frames above so the
//    serialize oracle stays anchored to real on-the-wire shapes.
// ---------------------------------------------------------------------------

/// Per-kind serialize expectations, anchored to a representative producer frame.
///
/// Each entry is `(label, source_frame, expected_kind_tag, expected_keys)`.
/// `expected_keys` is the COMPLETE set of top-level keys the flat wire object
/// must carry for that kind — the 3 framing keys plus exactly that variant's
/// payload fields. Asserting the full set means an added or removed
/// `serialize_entry` in the hand-written impl trips this oracle.
const SERIALIZE_CASES: &[(&str, &str, &str, &[&str])] = &[
    // Zero-payload kind: only the 3 framing keys.
    (
        "advance_phase",
        ADVANCE_PHASE_RUST,
        "advance_phase",
        &["kind", "project_path", "run_id"],
    ),
    // Second zero-payload kind for symmetry.
    (
        "detach_session",
        DETACH_SESSION_RUST,
        "detach_session",
        &["kind", "project_path", "run_id"],
    ),
    // Status-family kind (single `status_message` payload field).
    (
        "complete",
        COMPLETE_RUST,
        "complete",
        &["kind", "project_path", "run_id", "status_message"],
    ),
    // The riskiest producer kind: 10 payload fields, the only one carrying
    // `checkpoint_decision_relay` (set to "checkpoint_bridge" here).
    (
        "emit_checkpoint",
        EMIT_CHECKPOINT_BRIDGE_RUST,
        "emit_checkpoint",
        &[
            "kind",
            "project_path",
            "run_id",
            "checkpoint_kind",
            "checkpoint_title",
            "checkpoint_summary",
            "checkpoint_brief_path",
            "checkpoint_manifest_path",
            "checkpoint_media_artifacts",
            "checkpoint_mermaid_sources",
            "checkpoint_decision_relay",
            "capture_url",
            "checkpoint_id",
        ],
    ),
    // Decision submission (3 payload fields).
    (
        "submit_decision",
        SUBMIT_DECISION_SWIFT,
        "submit_decision",
        &[
            "kind",
            "project_path",
            "run_id",
            "checkpoint_id",
            "decision_action",
            "decision_note",
        ],
    ),
    // Capture completion (3 payload fields incl. the media artifact Vec).
    (
        "capture_complete",
        CAPTURE_COMPLETE_SWIFT,
        "capture_complete",
        &[
            "kind",
            "project_path",
            "run_id",
            "checkpoint_id",
            "capture_request_id",
            "completed_media_artifacts",
        ],
    ),
];

/// Collect the top-level object keys of a `serde_json::Value`, panicking if the
/// value is not a flat JSON object (which also pins "not nested / not tagged").
fn flat_object_keys(label: &str, value: &serde_json::Value) -> std::collections::BTreeSet<String> {
    let object = value
        .as_object()
        .unwrap_or_else(|| panic!("[{label}] serialized command must be a flat JSON object"));
    // Every value must be a scalar/array/null — never a nested object, which
    // would mean the discriminator got tagged or a payload got nested.
    for (key, child) in object {
        assert!(
            !child.is_object(),
            "[{label}] key `{key}` serialized as a nested object; \
             the wire must stay flat",
        );
    }
    object.keys().cloned().collect()
}

#[test]
fn serialize_emits_flat_object_with_exact_key_set_per_kind() {
    for (label, source_frame, expected_tag, expected_keys) in SERIALIZE_CASES {
        let command = decode(source_frame);

        // Serialize via the hand-written impl into a structured Value.
        let value = serde_json::to_value(&command)
            .unwrap_or_else(|err| panic!("[{label}] serialize failed: {err}"));

        // (a) Flat object, no nesting/tagging.
        let actual_keys = flat_object_keys(label, &value);

        // (b) EXACT key set — added or removed field fails.
        let expected: std::collections::BTreeSet<String> =
            expected_keys.iter().map(|k| (*k).to_string()).collect();
        assert_eq!(
            actual_keys, expected,
            "[{label}] serialized key set drifted from the pinned wire contract",
        );

        // (c) The `kind` discriminator is the expected string.
        assert_eq!(
            value.get("kind").and_then(serde_json::Value::as_str),
            Some(*expected_tag),
            "[{label}] kind discriminator mismatch",
        );
        // The framing keys are always present and non-empty.
        assert!(
            value
                .get("project_path")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|s| !s.is_empty()),
            "[{label}] project_path missing from serialized wire",
        );
        assert!(
            value
                .get("run_id")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|s| !s.is_empty()),
            "[{label}] run_id missing from serialized wire",
        );

        // (d) Round-trip identity: deserialize(serialize(cmd)) == cmd.
        let round_tripped: MutateRunCommand = serde_json::from_value(value)
            .unwrap_or_else(|err| panic!("[{label}] round-trip deserialize failed: {err}"));
        assert_eq!(
            round_tripped, command,
            "[{label}] serialize∘deserialize is not the identity",
        );
    }
}

/// The `emit_checkpoint` relay value must survive serialization verbatim. This
/// is the single most desync-prone field: only the checkpoint bridge sets it,
/// and the Swift struct has no key for it. Pin that the serialized wire carries
/// the relay string (not dropped, not tagged).
#[test]
fn serialize_emit_checkpoint_preserves_decision_relay_value() {
    let command = decode(EMIT_CHECKPOINT_BRIDGE_RUST);
    let value = serde_json::to_value(&command).expect("serialize emit_checkpoint");
    assert_eq!(
        value
            .get("checkpoint_decision_relay")
            .and_then(serde_json::Value::as_str),
        Some("checkpoint_bridge"),
        "checkpoint_decision_relay must serialize to its bridge value",
    );

    // And the round-trip preserves the typed relay variant.
    let round_tripped: MutateRunCommand =
        serde_json::from_value(value).expect("round-trip emit_checkpoint");
    let RunMutationKind::EmitCheckpoint {
        checkpoint_decision_relay,
        ..
    } = round_tripped.kind
    else {
        panic!("expected emit_checkpoint after round-trip");
    };
    assert_eq!(
        checkpoint_decision_relay,
        Some(CheckpointDecisionRelay::CheckpointBridge),
        "relay value must round-trip through serialize∘deserialize",
    );
}
