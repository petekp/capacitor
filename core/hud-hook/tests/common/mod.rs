//! Shared test helpers for hud-hook integration tests.
#![allow(dead_code)]

use std::io::{Read as _, Write as _};
use std::net::{Shutdown, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Create a unique temporary directory with a descriptive prefix.
pub fn unique_temp_dir(prefix: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_nanos();
    let path = std::env::temp_dir().join(format!("{}-{}", prefix, nanos));
    std::fs::create_dir_all(&path).expect("create temp dir");
    path
}

/// Find a free port by binding to :0 and reading back the assigned port.
pub fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind to free port");
    listener.local_addr().expect("local addr").port()
}

/// Guard that kills the hud-hook server process on drop.
pub struct ServerGuard {
    pub child: Child,
}

impl ServerGuard {
    const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
    const STARTUP_POLL_INTERVAL: Duration = Duration::from_millis(50);
    const STARTUP_ATTEMPTS: usize = 8;

    /// Spawn `hud-hook serve` on the given port with custom HOME and snapshot path.
    pub fn spawn(port: u16, home: &Path, snapshot_path: &Path) -> Self {
        let child = Command::new(env!("CARGO_BIN_EXE_hud-hook"))
            .args(["serve", "--port", &port.to_string()])
            .env("HOME", home)
            .env("CAPACITOR_RUNTIME_ARTIFACT_PATH", snapshot_path)
            .env("CAPACITOR_CORE_ENABLED", "1")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn hud-hook serve");

        Self { child }
    }

    /// Spawn `hud-hook serve` in runtime-service bootstrap mode.
    pub fn spawn_service_bootstrap(
        port: u16,
        home: &Path,
        snapshot_path: &Path,
        auth_token: &str,
    ) -> Self {
        Self::spawn_service_bootstrap_with_env(port, home, snapshot_path, auth_token, &[])
    }

    pub fn spawn_service_bootstrap_with_env(
        port: u16,
        home: &Path,
        snapshot_path: &Path,
        auth_token: &str,
        envs: &[(&str, &str)],
    ) -> Self {
        let child = Command::new(env!("CARGO_BIN_EXE_hud-hook"))
            .args(["serve", "--port", &port.to_string()])
            .env("HOME", home)
            .env("CAPACITOR_RUNTIME_ARTIFACT_PATH", snapshot_path)
            .env("CAPACITOR_CORE_ENABLED", "1")
            .env("CAPACITOR_RUNTIME_SERVICE_BOOTSTRAP", "1")
            .env("CAPACITOR_RUNTIME_SERVICE_PORT", port.to_string())
            .env("CAPACITOR_RUNTIME_SERVICE_TOKEN", auth_token)
            .envs(envs.iter().copied())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn hud-hook serve bootstrap");

        Self { child }
    }

    pub fn spawn_ready(home: &Path, snapshot_path: &Path) -> (Self, u16) {
        Self::spawn_ready_with_candidates(
            home,
            snapshot_path,
            (0..Self::STARTUP_ATTEMPTS).map(|_| free_port()),
        )
    }

    pub fn spawn_ready_with_candidates<I>(
        home: &Path,
        snapshot_path: &Path,
        ports: I,
    ) -> (Self, u16)
    where
        I: IntoIterator<Item = u16>,
    {
        Self::spawn_with_retry(
            ports,
            |port| Self::spawn(port, home, snapshot_path),
            |server, port| server.wait_until_ready(port),
        )
    }

    pub fn spawn_service_bootstrap_ready(
        home: &Path,
        snapshot_path: &Path,
        auth_token: &str,
    ) -> (Self, u16) {
        Self::spawn_service_bootstrap_ready_with_env(home, snapshot_path, auth_token, &[])
    }

    pub fn spawn_service_bootstrap_ready_with_env(
        home: &Path,
        snapshot_path: &Path,
        auth_token: &str,
        envs: &[(&str, &str)],
    ) -> (Self, u16) {
        Self::spawn_service_bootstrap_ready_with_candidates(
            home,
            snapshot_path,
            auth_token,
            envs,
            (0..Self::STARTUP_ATTEMPTS).map(|_| free_port()),
        )
    }

    pub fn spawn_service_bootstrap_ready_with_candidates<I>(
        home: &Path,
        snapshot_path: &Path,
        auth_token: &str,
        envs: &[(&str, &str)],
        ports: I,
    ) -> (Self, u16)
    where
        I: IntoIterator<Item = u16>,
    {
        Self::spawn_with_retry(
            ports,
            |port| {
                Self::spawn_service_bootstrap_with_env(port, home, snapshot_path, auth_token, envs)
            },
            |server, port| server.wait_until_ready_with_auth(port, auth_token),
        )
    }

    fn spawn_with_retry<I, Spawn, Wait>(ports: I, mut spawn: Spawn, mut wait: Wait) -> (Self, u16)
    where
        I: IntoIterator<Item = u16>,
        Spawn: FnMut(u16) -> Self,
        Wait: FnMut(&mut Self, u16) -> Result<(), String>,
    {
        let mut failures = Vec::new();

        for port in ports {
            let mut server = spawn(port);
            match wait(&mut server, port) {
                Ok(()) => return (server, port),
                Err(error) => failures.push(format!("port {port}: {error}")),
            }
        }

        panic!(
            "Failed to start hud-hook serve after {} attempts:\n{}",
            failures.len(),
            failures.join("\n")
        );
    }

    fn wait_until_ready(&mut self, port: u16) -> Result<(), String> {
        self.wait_until_ready_internal(port, None)
    }

    fn wait_until_ready_with_auth(&mut self, port: u16, auth_token: &str) -> Result<(), String> {
        self.wait_until_ready_internal(port, Some(auth_token))
    }

    fn wait_until_ready_internal(
        &mut self,
        port: u16,
        auth_token: Option<&str>,
    ) -> Result<(), String> {
        let deadline = Instant::now() + Self::STARTUP_TIMEOUT;
        let header_value = auth_token.map(|token| format!("Bearer {token}"));

        while Instant::now() < deadline {
            if let Some(exit_reason) = self.exited_before_ready() {
                return Err(exit_reason);
            }

            let response = if let Some(header_value) = header_value.as_deref() {
                try_http_request_with_headers(
                    port,
                    "GET",
                    "/health",
                    &[("Authorization", header_value)],
                    None,
                )
            } else {
                try_http_request(port, "GET", "/health", None)
            };

            if let Ok((200, body)) = response {
                if body.contains("\"ok\"") {
                    return Ok(());
                }
            }

            std::thread::sleep(Self::STARTUP_POLL_INTERVAL);
        }

        if let Some(exit_reason) = self.exited_before_ready() {
            return Err(exit_reason);
        }

        Err(format!(
            "Server on port {port} did not become healthy within {}s",
            Self::STARTUP_TIMEOUT.as_secs()
        ))
    }

    fn exited_before_ready(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                let stderr = self.read_stderr();
                let stderr_suffix = if stderr.trim().is_empty() {
                    String::new()
                } else {
                    format!("; stderr: {}", stderr.trim())
                };
                Some(format!(
                    "server exited before readiness check completed with status {status}{stderr_suffix}"
                ))
            }
            Ok(None) => None,
            Err(error) => Some(format!(
                "failed to query child status while waiting for readiness: {error}"
            )),
        }
    }

    fn read_stderr(&mut self) -> String {
        let Some(stderr) = self.child.stderr.as_mut() else {
            return String::new();
        };

        let mut buffer = Vec::new();
        let _ = stderr.read_to_end(&mut buffer);
        String::from_utf8_lossy(&buffer).to_string()
    }
}

impl Drop for ServerGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Send an HTTP request to the server and return (status_code, body).
/// Panics if the connection fails — use `try_http_request` for polling.
pub fn http_request(port: u16, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
    try_http_request(port, method, path, body).expect("HTTP request failed")
}

pub fn http_request_with_headers(
    port: u16,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> (u16, String) {
    try_http_request_with_headers(port, method, path, headers, body).expect("HTTP request failed")
}

/// Send a raw HTTP request string and return (status_code, body).
pub fn raw_http_request(port: u16, request: &str) -> (u16, String) {
    let mut stream =
        TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect for raw HTTP request");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("set read timeout");
    if let Err(err) = stream.write_all(request.as_bytes()) {
        if err.kind() != std::io::ErrorKind::BrokenPipe {
            panic!("write raw request: {err}");
        }
    }
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Write);

    let mut buf = vec![0u8; 8192];
    let mut total = 0;
    loop {
        match stream.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(_) => break,
        }
    }
    let response = String::from_utf8_lossy(&buf[..total]).to_string();

    parse_http_response(&response)
}

/// Send an HTTP request, returning Err if the connection fails.
fn try_http_request(
    port: u16,
    method: &str,
    path: &str,
    body: Option<&str>,
) -> Result<(u16, String), std::io::Error> {
    try_http_request_with_headers(port, method, path, &[], body)
}

fn try_http_request_with_headers(
    port: u16,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<(u16, String), std::io::Error> {
    let body_bytes = body.unwrap_or("");
    let header_blob = headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();
    let request = format!(
        "{method} {path} HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Content-Type: application/json\r\n\
         {header_blob}\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {body_bytes}",
        body_bytes.len()
    );

    let mut stream = TcpStream::connect(format!("127.0.0.1:{port}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.write_all(request.as_bytes())?;
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Write);

    let mut buf = vec![0u8; 8192];
    let mut total = 0;
    loop {
        match stream.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => break,
            Err(_) => break,
        }
    }
    let response = String::from_utf8_lossy(&buf[..total]).to_string();

    Ok(parse_http_response(&response))
}

/// POST JSON to the /hook endpoint.
pub fn post_hook(port: u16, input: &serde_json::Value) -> (u16, String) {
    http_request(port, "POST", "/hook", Some(&input.to_string()))
}

/// Parse a raw HTTP response into (status_code, body).
fn parse_http_response(response: &str) -> (u16, String) {
    let status = response
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .unwrap_or(0);

    let raw_body = response
        .find("\r\n\r\n")
        .map(|pos| &response[pos + 4..])
        .unwrap_or("");

    // Handle chunked transfer-encoding from tiny_http:
    // skip chunk-size lines and extract the JSON payload.
    let body = if raw_body.contains("\r\n") && !raw_body.starts_with('{') {
        raw_body
            .lines()
            .find(|line| line.starts_with('{'))
            .unwrap_or(raw_body)
    } else {
        raw_body
    };

    (status, body.to_string())
}

/// Read and parse the snapshot JSON file.
pub fn read_snapshot(snapshot_path: &Path) -> serde_json::Value {
    let payload = std::fs::read_to_string(snapshot_path).expect("read snapshot file");
    serde_json::from_str(&payload).expect("valid snapshot json")
}

/// Run `hud-hook cwd` with a specific HOME and return the exit status.
pub fn run_cwd(home: &Path, path: &str, pid: u32, tty: &str) -> std::process::ExitStatus {
    Command::new(env!("CARGO_BIN_EXE_hud-hook"))
        .args(["cwd", path, &pid.to_string(), tty])
        .env("HOME", home)
        .env("CAPACITOR_CORE_ENABLED", "1")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run hud-hook cwd")
}
