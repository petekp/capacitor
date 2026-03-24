//! Integration tests for `hud-hook serve`.
//!
//! Spawns the server binary on a random port, exercises the HTTP endpoints,
//! and verifies that hook events flow through to the snapshot file.

mod common;

use capacitor_core::method_runner::checkpoint_bridge_protocol::{
    decision_path, pending_path, write_json_atomic, CheckpointBridgeDecision,
    CheckpointBridgePending, CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
};
use common::{
    free_port, http_request, http_request_with_headers, raw_http_request, read_snapshot, run_cwd,
    unique_temp_dir, ServerGuard,
};
use std::fs;
use std::net::TcpListener;

fn create_run_with_active_checkpoint(port: u16, authorization: &str, run_id: &str) -> String {
    let create_payload = serde_json::json!({
        "kind": "create",
        "project_path": "/tmp/runtime-service-project",
        "run_id": run_id,
        "method_id": "execution_only",
        "involvement": null,
        "checkpoint_kind": null,
        "checkpoint_title": null,
        "checkpoint_summary": null,
        "checkpoint_brief_path": null,
        "checkpoint_manifest_path": null,
        "checkpoint_media_artifacts": [],
        "checkpoint_mermaid_sources": [],
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
        "completed_media_artifacts": []
    });
    let (create_status, create_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization)],
        Some(&create_payload.to_string()),
    );
    assert_eq!(create_status, 200, "body: {create_body}");

    let emit_payload = serde_json::json!({
        "kind": "emit_checkpoint",
        "project_path": "/tmp/runtime-service-project",
        "run_id": run_id,
        "method_id": null,
        "involvement": null,
        "checkpoint_kind": "implementation_milestone",
        "checkpoint_title": "Checkpoint capture",
        "checkpoint_summary": null,
        "checkpoint_brief_path": null,
        "checkpoint_manifest_path": null,
        "checkpoint_media_artifacts": [],
        "checkpoint_mermaid_sources": [],
        "capture_url": "http://localhost:3000",
        "checkpoint_id": null,
        "capture_request_id": null,
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": null,
        "decision_note": null,
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });
    let (emit_status, emit_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization)],
        Some(&emit_payload.to_string()),
    );
    assert_eq!(emit_status, 200, "body: {emit_body}");

    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization)],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");

    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    snapshot_json["runs"][0]["active_checkpoint"]["id"]
        .as_str()
        .expect("checkpoint id")
        .to_string()
}

fn submit_decision(
    port: u16,
    authorization: &str,
    run_id: &str,
    checkpoint_id: &str,
    action: &str,
    note: Option<&str>,
) -> (u16, String) {
    let decision_payload = serde_json::json!({
        "kind": "submit_decision",
        "project_path": "/tmp/runtime-service-project",
        "run_id": run_id,
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
        "checkpoint_id": checkpoint_id,
        "capture_request_id": null,
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": action,
        "decision_note": note,
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });

    http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization)],
        Some(&decision_payload.to_string()),
    )
}

fn seeded_snapshot_without_routing() -> serde_json::Value {
    serde_json::json!({
        "projects": [
            {
                "project_path": "/tmp/runtime-service-project",
                "project_id": "/tmp/runtime-service-project/.git",
                "workspace_id": "workspace-runtime-service-project",
                "display_name": "runtime-service-project",
                "state": "ready",
                "state_changed_at": "2026-03-12T00:00:00Z",
                "updated_at": "2026-03-12T00:00:00Z",
                "representative_session_id": "runtime-service-session",
                "latest_session_id": "runtime-service-session",
                "session_count": 1,
                "active_count": 0,
                "has_session": true
            }
        ],
        "sessions": [
            {
                "session_id": "runtime-service-session",
                "pid": 4242,
                "cwd": "/tmp/runtime-service-project",
                "project_id": "/tmp/runtime-service-project/.git",
                "project_path": "/tmp/runtime-service-project",
                "workspace_id": "workspace-runtime-service-project",
                "state": "ready",
                "state_changed_at": "2026-03-12T00:00:00Z",
                "updated_at": "2026-03-12T00:00:00Z",
                "last_event": "session_start",
                "last_activity_at": "2026-03-12T00:00:00Z",
                "tools_in_flight": 0,
                "ready_reason": null
            }
        ],
        "shells": [
            {
                "pid": 4242,
                "cwd": "/tmp/runtime-service-project",
                "tty": "/dev/ttys123",
                "parent_app": "ghostty",
                "tmux_session": "runtime-service-project",
                "tmux_client_tty": "/dev/ttys111",
                "tmux_pane": null,
                "updated_at": "2026-03-12T00:00:00Z"
            }
        ],
        "routing": [],
        "delegations": [],
        "runs": [],
        "diagnostics": {
            "events_ingested": 2,
            "sessions_tracked": 1,
            "shell_signals_tracked": 1,
            "events_skipped": 0,
            "stale_events_skipped": 0,
            "informational_events_skipped": 0,
            "reducer_events_skipped": 0,
            "last_error": null,
            "last_hook_event_at": "2026-03-12T00:00:00Z"
        },
        "generated_at": "2026-03-12T00:00:00Z"
    })
}

#[test]
fn health_endpoint_returns_ok() {
    let temp_dir = unique_temp_dir("serve-health");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let (status, body) = http_request(port, "GET", "/health", None);
    assert_eq!(status, 200);
    assert!(body.contains(r#""status":"ok"#), "body: {body}");
}

#[test]
fn spawn_ready_retries_when_initial_port_candidate_is_occupied() {
    let temp_dir = unique_temp_dir("serve-ready-retry");
    let snapshot_path = temp_dir.join("snapshot.json");
    let occupied_listener = TcpListener::bind("127.0.0.1:0").expect("bind occupied listener");
    let occupied_port = occupied_listener
        .local_addr()
        .expect("occupied listener addr")
        .port();
    let fallback_port = free_port();

    let (_server, port) = ServerGuard::spawn_ready_with_candidates(
        &temp_dir,
        &snapshot_path,
        [occupied_port, fallback_port],
    );

    assert_eq!(port, fallback_port);

    let (status, body) = http_request(port, "GET", "/health", None);
    assert_eq!(status, 200, "body: {body}");
    assert!(body.contains(r#""status":"ok"#), "body: {body}");
}

#[test]
fn bootstrap_health_requires_auth_and_reports_service_mode() {
    let temp_dir = unique_temp_dir("serve-bootstrap-health");
    let snapshot_path = temp_dir.join("snapshot.json");
    let runtime_dir = temp_dir.join(".capacitor/runtime");
    let auth_token = "secret-token";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let (unauthorized_status, unauthorized_body) = http_request(port, "GET", "/health", None);
    assert_eq!(unauthorized_status, 401, "body: {unauthorized_body}");

    let authorization = format!("Bearer {auth_token}");
    let (status, body) = http_request_with_headers(
        port,
        "GET",
        "/health",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(status, 200, "body: {body}");
    assert!(body.contains(r#""status":"ok""#), "body: {body}");
    assert!(body.contains(r#""schema_version":"#), "body: {body}");
    assert!(
        body.contains(r#""service_mode":"bootstrap_only""#),
        "body: {body}"
    );
    assert!(body.contains(r#""auth_mode":"bearer""#), "body: {body}");

    let token_path = runtime_dir.join(format!("runtime-service-{port}.token"));
    let persisted_token = fs::read_to_string(&token_path).expect("read runtime service token");
    assert_eq!(persisted_token, auth_token);
}

#[test]
fn cwd_command_discovers_runtime_service_and_runtime_snapshot_reports_shell_state() {
    let temp_dir = unique_temp_dir("serve-runtime-snapshot");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "snapshot-token";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let status = run_cwd(
        &temp_dir,
        "/tmp/runtime-service-project",
        4242,
        "/dev/ttys123",
    );
    assert!(
        status.success(),
        "hud-hook cwd should succeed via runtime service"
    );

    let authorization = format!("Bearer {auth_token}");
    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");

    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    assert_eq!(snapshot_json["shells"].as_array().map(Vec::len), Some(1));
    assert_eq!(snapshot_json["shells"][0]["pid"].as_u64(), Some(4242));
    assert_eq!(
        snapshot_json["shells"][0]["cwd"].as_str(),
        Some("/tmp/runtime-service-project")
    );
}

#[test]
fn hook_endpoint_and_runtime_snapshot_share_service_runtime_state() {
    let temp_dir = unique_temp_dir("serve-runtime-hook");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "hook-token";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "runtime-service-session",
        "cwd": "/tmp/runtime-service-project"
    });

    let (hook_status, hook_body) = http_request(port, "POST", "/hook", Some(&payload.to_string()));
    assert_eq!(hook_status, 200, "body: {hook_body}");

    let authorization = format!("Bearer {auth_token}");
    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");

    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    assert_eq!(snapshot_json["sessions"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        snapshot_json["sessions"][0]["session_id"].as_str(),
        Some("runtime-service-session")
    );
    assert_eq!(
        snapshot_json["sessions"][0]["state"].as_str(),
        Some("working")
    );
}

#[test]
fn runtime_snapshot_recomputes_routing_from_seeded_snapshot_on_startup() {
    let temp_dir = unique_temp_dir("serve-runtime-recompute-routing");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "recompute-token";

    fs::write(
        &snapshot_path,
        serde_json::to_vec_pretty(&seeded_snapshot_without_routing())
            .expect("serialize seeded snapshot"),
    )
    .expect("write seeded snapshot");

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");

    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    assert_eq!(snapshot_json["routing"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        snapshot_json["routing"][0]["project_path"].as_str(),
        Some("/tmp/runtime-service-project")
    );
    assert_eq!(
        snapshot_json["routing"][0]["target"]["kind"].as_str(),
        Some("tmux_session")
    );
    assert_eq!(
        snapshot_json["routing"][0]["target"]["session_name"].as_str(),
        Some("runtime-service-project")
    );
    assert_eq!(
        snapshot_json["routing"][0]["target"]["host_tty"].as_str(),
        Some("/dev/ttys111")
    );
    assert_eq!(
        snapshot_json["routing"][0]["reason_code"].as_str(),
        Some("TMUX_SESSION_ATTACHED")
    );
}

#[test]
fn runtime_delegation_mutation_endpoint_updates_shared_runtime_snapshot() {
    let temp_dir = unique_temp_dir("serve-runtime-delegation");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "delegation-token";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let start_payload = serde_json::json!({
        "kind": "start",
        "project_path": "/tmp/runtime-service-project",
        "worker_id": "worker-1",
        "idea_id": "idea-1",
        "worktree_name": "delegation-worker-1",
        "worktree_path": "/tmp/runtime-service-project/.capacitor/worktrees/delegation-worker-1",
        "session_id": null,
        "milestone_id": null,
        "brief_path": null,
        "manifest_path": null,
        "review_decision": null,
        "note": null
    });

    let (start_status, start_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/delegation/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&start_payload.to_string()),
    );
    assert_eq!(start_status, 200, "body: {start_body}");

    let review_payload = serde_json::json!({
        "kind": "review_ready",
        "project_path": "/tmp/runtime-service-project",
        "worker_id": "worker-1",
        "idea_id": "idea-1",
        "worktree_name": "delegation-worker-1",
        "worktree_path": "/tmp/runtime-service-project/.capacitor/worktrees/delegation-worker-1",
        "session_id": "session-worker-1",
        "milestone_id": "01",
        "brief_path": "/tmp/runtime-service-project/.capacitor/delegations/worker-1/milestones/01/brief.md",
        "manifest_path": "/tmp/runtime-service-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
        "review_decision": null,
        "note": null
    });

    let (review_status, review_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/delegation/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&review_payload.to_string()),
    );
    assert_eq!(review_status, 200, "body: {review_body}");

    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");

    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    assert_eq!(
        snapshot_json["delegations"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        snapshot_json["delegations"][0]["project_path"].as_str(),
        Some("/tmp/runtime-service-project")
    );
    assert_eq!(
        snapshot_json["delegations"][0]["status"].as_str(),
        Some("review_needed")
    );
    assert_eq!(
        snapshot_json["delegations"][0]["current_review"]["manifest_path"].as_str(),
        Some(
            "/tmp/runtime-service-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
        )
    );
}

#[test]
fn runtime_run_mutation_endpoint_updates_shared_runtime_snapshot() {
    let temp_dir = unique_temp_dir("serve-runtime-run");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "run-token";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let create_payload = serde_json::json!({
        "kind": "create",
        "project_path": "/tmp/runtime-service-project",
        "run_id": "run-1",
        "method_id": "execution_only",
        "involvement": null,
        "checkpoint_kind": null,
        "checkpoint_title": null,
        "checkpoint_summary": null,
        "checkpoint_brief_path": null,
        "checkpoint_manifest_path": null,
        "checkpoint_media_artifacts": [],
        "checkpoint_mermaid_sources": [],
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
        "completed_media_artifacts": []
    });
    let (create_status, create_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&create_payload.to_string()),
    );
    assert_eq!(create_status, 200, "body: {create_body}");

    let attach_payload = serde_json::json!({
        "kind": "attach_session",
        "project_path": "/tmp/runtime-service-project",
        "run_id": "run-1",
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
        "checkpoint_id": null,
        "capture_request_id": null,
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": null,
        "decision_note": null,
        "session_id": "runtime-service-session",
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });
    let (attach_status, attach_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&attach_payload.to_string()),
    );
    assert_eq!(attach_status, 200, "body: {attach_body}");

    let emit_payload = serde_json::json!({
        "kind": "emit_checkpoint",
        "project_path": "/tmp/runtime-service-project",
        "run_id": "run-1",
        "method_id": null,
        "involvement": null,
        "checkpoint_kind": "implementation_milestone",
        "checkpoint_title": "Checkpoint capture",
        "checkpoint_summary": null,
        "checkpoint_brief_path": null,
        "checkpoint_manifest_path": null,
        "checkpoint_media_artifacts": [],
        "checkpoint_mermaid_sources": [],
        "capture_url": "http://localhost:3000",
        "checkpoint_id": null,
        "capture_request_id": null,
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": null,
        "decision_note": null,
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });
    let (emit_status, emit_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&emit_payload.to_string()),
    );
    assert_eq!(emit_status, 200, "body: {emit_body}");

    let (snapshot_status, snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(snapshot_status, 200, "body: {snapshot_body}");
    let snapshot_json: serde_json::Value =
        serde_json::from_str(&snapshot_body).expect("runtime snapshot json");
    let checkpoint_id = snapshot_json["runs"][0]["active_checkpoint"]["id"]
        .as_str()
        .expect("checkpoint id")
        .to_string();

    let claim_payload = serde_json::json!({
        "kind": "capture_claim",
        "project_path": "/tmp/runtime-service-project",
        "run_id": "run-1",
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
        "checkpoint_id": checkpoint_id.as_str(),
        "capture_request_id": "request-1",
        "client_id": "client-1",
        "observed_capture_url": "http://localhost:4173",
        "capture_failure_reason": null,
        "decision_action": null,
        "decision_note": null,
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });
    let (claim_status, claim_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&claim_payload.to_string()),
    );
    assert_eq!(claim_status, 200, "body: {claim_body}");

    let complete_payload = serde_json::json!({
        "kind": "capture_complete",
        "project_path": "/tmp/runtime-service-project",
        "run_id": "run-1",
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
        "checkpoint_id": checkpoint_id.as_str(),
        "capture_request_id": "request-1",
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": null,
        "decision_note": null,
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": [
            {
                "artifact_type": "screenshot",
                "path": "/tmp/runtime-service-project/captures/checkpoint-1.png",
                "label": "Checkpoint screenshot",
                "width": 1280,
                "height": 720,
                "duration_secs": null
            }
        ]
    });
    let (complete_status, complete_body) = http_request_with_headers(
        port,
        "POST",
        "/runtime/run/mutate",
        &[("Authorization", authorization.as_str())],
        Some(&complete_payload.to_string()),
    );
    assert_eq!(complete_status, 200, "body: {complete_body}");

    let (final_snapshot_status, final_snapshot_body) = http_request_with_headers(
        port,
        "GET",
        "/runtime/snapshot",
        &[("Authorization", authorization.as_str())],
        None,
    );
    assert_eq!(final_snapshot_status, 200, "body: {final_snapshot_body}");

    let final_snapshot_json: serde_json::Value =
        serde_json::from_str(&final_snapshot_body).expect("runtime snapshot json");
    assert_eq!(
        final_snapshot_json["runs"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        final_snapshot_json["runs"][0]["active_checkpoint"]["id"].as_str(),
        Some(checkpoint_id.as_str())
    );
    assert_eq!(
        final_snapshot_json["runs"][0]["active_checkpoint"]["capture_status"].as_str(),
        Some("completed")
    );
    assert_eq!(
        final_snapshot_json["runs"][0]["active_checkpoint"]["media_artifacts"][0]["path"].as_str(),
        Some("/tmp/runtime-service-project/captures/checkpoint-1.png")
    );
}

#[test]
fn runtime_run_submit_decision_writes_checkpoint_bridge_file_when_pending_marker_exists() {
    let temp_dir = unique_temp_dir("serve-runtime-run-decision-bridge");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "decision-bridge-token";
    let run_id = "run-decision-1";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let checkpoint_id = create_run_with_active_checkpoint(port, &authorization, run_id);

    let pending = CheckpointBridgePending {
        version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
        project_path: "/tmp/runtime-service-project".to_string(),
        run_id: run_id.to_string(),
        checkpoint_id: checkpoint_id.clone(),
        phase_id: "phase-001".to_string(),
        gate_type: "approval".to_string(),
        manifest_path: "/tmp/runtime-service-project/.capacitor/checkpoints/gate.json".to_string(),
        created_at: "2026-03-24T12:00:00Z".to_string(),
    };
    let pending_file = pending_path(&temp_dir, run_id, &checkpoint_id);
    write_json_atomic(&pending_file, &pending).expect("write pending marker");

    let (decision_status, decision_body) = submit_decision(
        port,
        &authorization,
        run_id,
        &checkpoint_id,
        "approve",
        Some("Ship it"),
    );
    assert_eq!(decision_status, 200, "body: {decision_body}");

    let decision_file = decision_path(&temp_dir, run_id, &checkpoint_id);
    assert!(
        decision_file.exists(),
        "decision file should exist at {decision_file:?}"
    );
    let decision_payload = fs::read_to_string(&decision_file).expect("read decision file");
    let decision: CheckpointBridgeDecision =
        serde_json::from_str(&decision_payload).expect("parse decision file");
    assert_eq!(decision.version, CHECKPOINT_BRIDGE_PROTOCOL_VERSION);
    assert_eq!(decision.run_id, run_id);
    assert_eq!(decision.checkpoint_id, checkpoint_id);
    assert_eq!(decision.action, "approve");
    assert_eq!(decision.note.as_deref(), Some("Ship it"));
    assert!(
        !pending_file.exists(),
        "pending marker should be removed after relay"
    );
}

#[test]
fn runtime_run_submit_decision_is_noop_without_checkpoint_bridge_pending_marker() {
    let temp_dir = unique_temp_dir("serve-runtime-run-decision-noop");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "decision-noop-token";
    let run_id = "run-decision-2";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let checkpoint_id = create_run_with_active_checkpoint(port, &authorization, run_id);

    let (decision_status, decision_body) = submit_decision(
        port,
        &authorization,
        run_id,
        &checkpoint_id,
        "request_changes",
        Some("Needs one more pass"),
    );
    assert_eq!(decision_status, 200, "body: {decision_body}");

    let decision_file = decision_path(&temp_dir, run_id, &checkpoint_id);
    assert!(
        !decision_file.exists(),
        "relay should not write a decision without a pending marker"
    );
}

#[test]
fn runtime_run_submit_decision_does_not_write_checkpoint_bridge_file_when_mutation_is_rejected() {
    let temp_dir = unique_temp_dir("serve-runtime-run-decision-rejected");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "decision-rejected-token";
    let run_id = "run-decision-3";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let checkpoint_id = create_run_with_active_checkpoint(port, &authorization, run_id);

    let pending = CheckpointBridgePending {
        version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
        project_path: "/tmp/runtime-service-project".to_string(),
        run_id: run_id.to_string(),
        checkpoint_id: checkpoint_id.clone(),
        phase_id: "phase-001".to_string(),
        gate_type: "approval".to_string(),
        manifest_path: "/tmp/runtime-service-project/.capacitor/checkpoints/gate.json".to_string(),
        created_at: "2026-03-24T12:00:00Z".to_string(),
    };
    let pending_file = pending_path(&temp_dir, run_id, &checkpoint_id);
    write_json_atomic(&pending_file, &pending).expect("write pending marker");

    let (decision_status, decision_body) = submit_decision(
        port,
        &authorization,
        run_id,
        &checkpoint_id,
        "",
        Some("Ship it"),
    );
    assert_eq!(decision_status, 200, "body: {decision_body}");

    let outcome: serde_json::Value =
        serde_json::from_str(&decision_body).expect("parse mutation outcome");
    assert_eq!(
        outcome["ok"].as_bool(),
        Some(false),
        "body: {decision_body}"
    );

    let decision_file = decision_path(&temp_dir, run_id, &checkpoint_id);
    assert!(
        !decision_file.exists(),
        "relay should not write a decision for rejected mutations"
    );
    assert!(
        pending_file.exists(),
        "pending marker should remain when relay does not run"
    );
}

#[test]
fn runtime_run_submit_decision_does_not_write_checkpoint_bridge_file_when_unauthorized() {
    let temp_dir = unique_temp_dir("serve-runtime-run-decision-unauthorized");
    let snapshot_path = temp_dir.join("snapshot.json");
    let auth_token = "decision-unauthorized-token";
    let run_id = "run-decision-4";

    let (_server, port) =
        ServerGuard::spawn_service_bootstrap_ready(&temp_dir, &snapshot_path, auth_token);

    let authorization = format!("Bearer {auth_token}");
    let checkpoint_id = create_run_with_active_checkpoint(port, &authorization, run_id);

    let pending = CheckpointBridgePending {
        version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
        project_path: "/tmp/runtime-service-project".to_string(),
        run_id: run_id.to_string(),
        checkpoint_id: checkpoint_id.clone(),
        phase_id: "phase-001".to_string(),
        gate_type: "approval".to_string(),
        manifest_path: "/tmp/runtime-service-project/.capacitor/checkpoints/gate.json".to_string(),
        created_at: "2026-03-24T12:00:00Z".to_string(),
    };
    let pending_file = pending_path(&temp_dir, run_id, &checkpoint_id);
    write_json_atomic(&pending_file, &pending).expect("write pending marker");

    let decision_payload = serde_json::json!({
        "kind": "submit_decision",
        "project_path": "/tmp/runtime-service-project",
        "run_id": run_id,
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
        "checkpoint_id": checkpoint_id,
        "capture_request_id": null,
        "client_id": null,
        "observed_capture_url": null,
        "capture_failure_reason": null,
        "decision_action": "approve",
        "decision_note": "Ship it",
        "session_id": null,
        "delegation_worker_id": null,
        "completed_media_artifacts": []
    });
    let (decision_status, decision_body) = http_request(
        port,
        "POST",
        "/runtime/run/mutate",
        Some(&decision_payload.to_string()),
    );
    assert_eq!(decision_status, 401, "body: {decision_body}");

    let decision_file = decision_path(&temp_dir, run_id, &checkpoint_id);
    assert!(
        !decision_file.exists(),
        "relay should not write a decision for unauthorized requests"
    );
    assert!(
        pending_file.exists(),
        "pending marker should remain when authorization fails"
    );
}

#[test]
fn hook_endpoint_processes_event() {
    let temp_dir = unique_temp_dir("serve-hook");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "serve-test-1",
        "cwd": "/tmp/serve-test"
    });

    let (status, body) = http_request(port, "POST", "/hook", Some(&payload.to_string()));
    assert_eq!(status, 200, "body: {body}");
    assert!(body.contains(r#""status":"ok"#), "body: {body}");

    let snapshot = read_snapshot(&snapshot_path);

    assert_eq!(
        snapshot["sessions"][0]["state"].as_str(),
        Some("working"),
        "UserPromptSubmit should set state to working"
    );
    assert_eq!(
        snapshot["sessions"][0]["session_id"].as_str(),
        Some("serve-test-1")
    );
}

#[test]
fn hook_endpoint_skips_non_delete_when_cwd_missing() {
    let temp_dir = unique_temp_dir("serve-missing-cwd-skip");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "serve-missing-cwd"
    });

    let (status, body) = http_request(port, "POST", "/hook", Some(&payload.to_string()));
    assert_eq!(status, 200, "body: {body}");
    assert!(body.contains(r#""status":"ok"#), "body: {body}");

    if snapshot_path.exists() {
        let snapshot = read_snapshot(&snapshot_path);
        assert_eq!(
            snapshot["sessions"].as_array().map(Vec::len),
            Some(0),
            "missing cwd should skip non-delete events rather than invent a project attribution"
        );
    }
}

#[test]
fn session_end_without_cwd_still_deletes_existing_session() {
    let temp_dir = unique_temp_dir("serve-missing-cwd-delete");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let create_payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "serve-delete-1",
        "cwd": "/tmp/serve-delete"
    });
    let (create_status, create_body) =
        http_request(port, "POST", "/hook", Some(&create_payload.to_string()));
    assert_eq!(create_status, 200, "body: {create_body}");

    let delete_payload = serde_json::json!({
        "hook_event_name": "SessionEnd",
        "session_id": "serve-delete-1"
    });
    let (delete_status, delete_body) =
        http_request(port, "POST", "/hook", Some(&delete_payload.to_string()));
    assert_eq!(delete_status, 200, "body: {delete_body}");
    assert!(
        delete_body.contains(r#""status":"ok"#),
        "body: {delete_body}"
    );

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(
        snapshot["sessions"].as_array().map(Vec::len),
        Some(0),
        "SessionEnd should delete the existing session even when cwd is absent"
    );
}

#[test]
fn hook_endpoint_accepts_valid_chunked_body_without_content_length() {
    let temp_dir = unique_temp_dir("serve-chunked-valid");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "chunked-valid-1",
        "cwd": "/tmp/chunked-valid"
    })
    .to_string();

    let mut chunked_payload = String::new();
    for chunk in payload.as_bytes().chunks(7) {
        chunked_payload.push_str(&format!("{:X}\r\n", chunk.len()));
        chunked_payload.push_str(std::str::from_utf8(chunk).expect("payload is utf-8"));
        chunked_payload.push_str("\r\n");
    }
    chunked_payload.push_str("0\r\n\r\n");

    let request = format!(
        "POST /hook HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         Transfer-Encoding: chunked\r\n\
         Connection: close\r\n\
         \r\n\
         {chunked_payload}"
    );

    let (status, body) = raw_http_request(port, &request);
    assert_eq!(status, 200, "body: {body}");
    assert!(body.contains(r#""status":"ok"#), "body: {body}");

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(
        snapshot["sessions"][0]["session_id"].as_str(),
        Some("chunked-valid-1")
    );
    assert_eq!(snapshot["sessions"][0]["state"].as_str(), Some("working"));
}

#[test]
fn hook_endpoint_rejects_invalid_json() {
    let temp_dir = unique_temp_dir("serve-bad-json");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let (status, body) = http_request(port, "POST", "/hook", Some("not json"));
    assert_eq!(status, 400, "body: {body}");
    assert!(body.contains("error"), "body: {body}");
}

#[test]
fn hook_endpoint_rejects_oversized_body_without_content_length() {
    let temp_dir = unique_temp_dir("serve-oversized-no-length");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    // Deliberately exceed MAX_BODY_BYTES (1 MiB) without Content-Length.
    let payload = serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "oversized-no-length",
        "cwd": "/tmp/serve-test",
        "message": "x".repeat((1024 * 1024) + 128)
    })
    .to_string();

    let mut chunked_payload = String::new();
    let chunk_size = 16 * 1024;
    for chunk in payload.as_bytes().chunks(chunk_size) {
        chunked_payload.push_str(&format!("{:X}\r\n", chunk.len()));
        chunked_payload.push_str(std::str::from_utf8(chunk).expect("payload is utf-8"));
        chunked_payload.push_str("\r\n");
    }
    chunked_payload.push_str("0\r\n\r\n");

    let request = format!(
        "POST /hook HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         Transfer-Encoding: chunked\r\n\
         Connection: close\r\n\
         \r\n\
         {chunked_payload}"
    );

    let (status, body) = raw_http_request(port, &request);
    assert_eq!(status, 413, "body: {body}");
    assert!(body.contains("body too large"), "body: {body}");
}

#[test]
fn unknown_route_returns_404() {
    let temp_dir = unique_temp_dir("serve-404");
    let snapshot_path = temp_dir.join("snapshot.json");
    let (_server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let (status, _body) = http_request(port, "GET", "/nonexistent", None);
    assert_eq!(status, 404);
}

#[test]
fn pid_file_is_written() {
    let temp_dir = unique_temp_dir("serve-pid");
    let snapshot_path = temp_dir.join("snapshot.json");
    let runtime_dir = temp_dir.join(".capacitor/runtime");
    let (server, port) = ServerGuard::spawn_ready(&temp_dir, &snapshot_path);

    let pid_file = runtime_dir.join(format!("hud-hook-serve-{port}.pid"));
    assert!(pid_file.exists(), "PID file should exist at {pid_file:?}");

    let pid_contents = fs::read_to_string(&pid_file).expect("read pid file");
    let file_pid: u32 = pid_contents.trim().parse().expect("parse pid");
    assert_eq!(file_pid, server.child.id());
}
