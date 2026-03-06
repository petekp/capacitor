//! Integration tests for `hud-hook serve`.
//!
//! Spawns the server binary on a random port, exercises the HTTP endpoints,
//! and verifies that hook events flow through to the snapshot file.

mod common;

use common::{
    free_port, http_request, raw_http_request, read_snapshot, unique_temp_dir, ServerGuard,
};
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
fn hook_endpoint_skips_non_delete_when_cwd_missing() {
    let temp_dir = unique_temp_dir("serve-missing-cwd-skip");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

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
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

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
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

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
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, body) = http_request(port, "POST", "/hook", Some("not json"));
    assert_eq!(status, 400, "body: {body}");
    assert!(body.contains("error"), "body: {body}");
}

#[test]
fn hook_endpoint_rejects_oversized_body_without_content_length() {
    let temp_dir = unique_temp_dir("serve-oversized-no-length");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _server = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

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
