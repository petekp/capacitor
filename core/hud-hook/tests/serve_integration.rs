//! Integration tests for `hud-hook serve`.
//!
//! Spawns the server binary on a random port, exercises the HTTP endpoints,
//! and verifies that hook events flow through to the snapshot file.

mod common;

use common::{free_port, http_request, read_snapshot, unique_temp_dir, ServerGuard};
use std::fs;

#[test]
fn health_endpoint_returns_ok() {
    let temp_dir = unique_temp_dir("serve-health");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, body) = http_request(port, "GET", "/health", None);
    assert_eq!(status, 200);
    assert!(body.contains(r#""status":"ok"#), "body: {body}");
}

#[test]
fn hook_endpoint_processes_event() {
    let temp_dir = unique_temp_dir("serve-hook");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

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
fn hook_endpoint_rejects_invalid_json() {
    let temp_dir = unique_temp_dir("serve-bad-json");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, body) = http_request(port, "POST", "/hook", Some("not json"));
    assert_eq!(status, 400, "body: {body}");
    assert!(body.contains("error"), "body: {body}");
}

#[test]
fn unknown_route_returns_404() {
    let temp_dir = unique_temp_dir("serve-404");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, _body) = http_request(port, "GET", "/nonexistent", None);
    assert_eq!(status, 404);
}

#[test]
fn pid_file_is_written() {
    let temp_dir = unique_temp_dir("serve-pid");
    let snapshot_path = temp_dir.join("snapshot.json");
    let runtime_dir = temp_dir.join(".capacitor/runtime");
    let port = free_port();

    let server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let pid_file = runtime_dir.join(format!("hud-hook-serve-{port}.pid"));
    assert!(pid_file.exists(), "PID file should exist at {pid_file:?}");

    let pid_contents = fs::read_to_string(&pid_file).expect("read pid file");
    let file_pid: u32 = pid_contents.trim().parse().expect("parse pid");
    assert_eq!(file_pid, server.child.id());
}
