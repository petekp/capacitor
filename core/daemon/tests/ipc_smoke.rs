use capacitor_daemon_protocol::{
    EventEnvelope, EventType, Method, Request, Response, PROTOCOL_VERSION,
};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};
use tempfile::TempDir;

struct DaemonGuard {
    child: Child,
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_daemon(home: &Path) -> Child {
    Command::new(env!("CARGO_BIN_EXE_capacitor-daemon"))
        .env("HOME", home)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("Failed to spawn capacitor-daemon")
}

fn socket_path(home: &Path) -> PathBuf {
    home.join(".capacitor").join("daemon.sock")
}

fn wait_for_socket(path: &Path, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return;
        }
        sleep(Duration::from_millis(25));
    }
    panic!("Timed out waiting for daemon socket at {}", path.display());
}

fn send_request(socket: &Path, request: Request) -> Response {
    let mut stream = UnixStream::connect(socket).expect("Failed to connect to daemon socket");
    serde_json::to_writer(&mut stream, &request).expect("Failed to serialize request");
    stream.write_all(b"\n").expect("Failed to write request");
    stream.flush().ok();
    read_response(&mut stream)
}

fn read_response(stream: &mut UnixStream) -> Response {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];

    loop {
        let n = stream.read(&mut chunk).expect("Failed to read response");
        if n == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..n]);
        if chunk[..n].contains(&b'\n') {
            break;
        }
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let response_bytes = match newline_index {
        Some(index) => &buffer[..index],
        None => buffer.as_slice(),
    };

    serde_json::from_slice(response_bytes).expect("Failed to parse response JSON")
}

#[test]
fn daemon_ipc_health_and_liveness_smoke() {
    let home = TempDir::new().expect("Failed to create temp HOME");
    let socket = socket_path(home.path());
    let child = spawn_daemon(home.path());
    let _guard = DaemonGuard { child };

    wait_for_socket(&socket, Duration::from_secs(2));

    let health = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetHealth,
            id: Some("health-check".to_string()),
            params: None,
        },
    );

    assert!(health.ok, "health response was not ok");
    let status = health
        .data
        .as_ref()
        .and_then(|data| data.get("status"))
        .and_then(|value| value.as_str())
        .unwrap_or("missing");
    assert_eq!(status, "ok");

    let pid = std::process::id();
    let event = EventEnvelope {
        event_id: "evt-test-1".to_string(),
        recorded_at: "2026-01-31T00:00:00Z".to_string(),
        event_type: EventType::SessionStart,
        session_id: Some("session-test-1".to_string()),
        pid: Some(pid),
        cwd: Some(home.path().to_string_lossy().to_string()),
        tool: None,
        file_path: None,
        parent_app: None,
        tty: None,
        tmux_session: None,
        tmux_client_tty: None,
        notification_type: None,
        stop_hook_active: None,
        metadata: None,
    };

    let event_response = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::Event,
            id: Some(event.event_id.clone()),
            params: Some(serde_json::to_value(event).expect("Failed to serialize event")),
        },
    );
    assert!(event_response.ok, "event response was not ok");

    let liveness = send_request(
        &socket,
        Request {
            protocol_version: PROTOCOL_VERSION,
            method: Method::GetProcessLiveness,
            id: Some("liveness-check".to_string()),
            params: Some(serde_json::json!({ "pid": pid })),
        },
    );
    assert!(liveness.ok, "liveness response was not ok");
    let pid_value = liveness
        .data
        .as_ref()
        .and_then(|data| data.get("pid"))
        .and_then(|value| value.as_u64())
        .unwrap_or_default();
    assert_eq!(pid_value, pid as u64);
}
