//! Runtime service snapshot helpers for session liveness checks.
//!
//! Live callers should resolve session liveness through the authenticated local
//! runtime service rather than reading persisted artifacts directly.

use crate::domain::AppSnapshot;
use crate::runtime_service::{RuntimeServiceEndpoint, RUNTIME_SERVICE_DEFAULT_PORT};
use serde::Deserialize;

const ENABLE_ENV: &str = "CAPACITOR_CORE_ENABLED";

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct RuntimeSessionRecord {
    pub session_id: String,
    pub pid: u32,
    pub state: String,
    pub cwd: String,
    pub project_path: String,
    pub updated_at: String,
    pub state_changed_at: String,
    #[serde(default)]
    pub last_event: Option<String>,
    #[serde(default)]
    pub last_activity_at: Option<String>,
    #[serde(default)]
    pub tools_in_flight: u32,
    #[serde(default)]
    pub ready_reason: Option<String>,
    #[serde(default)]
    pub is_alive: Option<bool>,
}

pub struct RuntimeSessionsSnapshot {
    sessions: Vec<RuntimeSessionRecord>,
}

impl RuntimeSessionsSnapshot {
    pub fn sessions(&self) -> &[RuntimeSessionRecord] {
        &self.sessions
    }

    #[cfg(test)]
    pub(crate) fn from_sessions(sessions: Vec<RuntimeSessionRecord>) -> Self {
        Self { sessions }
    }
}

pub(crate) struct HookHealthSnapshot {
    pub(crate) sessions: RuntimeSessionsSnapshot,
    pub(crate) last_hook_event_at: Option<String>,
}

pub fn sessions_snapshot() -> Option<RuntimeSessionsSnapshot> {
    hook_health_snapshot().map(|snapshot| snapshot.sessions)
}

pub(crate) fn hook_health_snapshot() -> Option<HookHealthSnapshot> {
    if !runtime_enabled() {
        return None;
    }

    let snapshot = load_runtime_snapshot().ok()??;
    let sessions = snapshot
        .sessions
        .into_iter()
        .map(|session| RuntimeSessionRecord {
            session_id: session.session_id,
            pid: session.pid,
            state: session_state_label(session.state).to_string(),
            cwd: session.cwd,
            project_path: session.project_path,
            updated_at: session.updated_at,
            state_changed_at: session.state_changed_at,
            last_event: session.last_event,
            last_activity_at: session.last_activity_at,
            tools_in_flight: session.tools_in_flight,
            ready_reason: session.ready_reason,
            is_alive: None,
        })
        .collect();

    Some(HookHealthSnapshot {
        sessions: RuntimeSessionsSnapshot { sessions },
        last_hook_event_at: snapshot.diagnostics.last_hook_event_at,
    })
}

pub(crate) fn runtime_health() -> Option<bool> {
    if !runtime_enabled() {
        return None;
    }

    match runtime_service_endpoint() {
        Ok(Some(endpoint)) => Some(endpoint.probe_health().is_ok()),
        Ok(None) | Err(_) => Some(false),
    }
}

pub(crate) fn runtime_enabled() -> bool {
    env_flag(ENABLE_ENV).unwrap_or(true)
}

fn load_runtime_snapshot() -> Result<Option<AppSnapshot>, String> {
    let Some(endpoint) = runtime_service_endpoint()? else {
        return Ok(None);
    };

    endpoint.fetch_snapshot().map(Some)
}

fn runtime_service_endpoint() -> Result<Option<RuntimeServiceEndpoint>, String> {
    let home = dirs::home_dir().ok_or_else(|| "Cannot determine home directory".to_string())?;
    RuntimeServiceEndpoint::discover(&home, RUNTIME_SERVICE_DEFAULT_PORT)
}

fn env_flag(key: &str) -> Option<bool> {
    std::env::var(key).ok().and_then(|value| parse_bool(&value))
}

fn parse_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn session_state_label(state: crate::domain::SessionState) -> &'static str {
    match state {
        crate::domain::SessionState::Working => "working",
        crate::domain::SessionState::Ready => "ready",
        crate::domain::SessionState::Idle => "idle",
        crate::domain::SessionState::Compacting => "compacting",
        crate::domain::SessionState::Waiting => "waiting",
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant};

    #[derive(Debug, Clone)]
    pub(crate) struct MockRuntimeServiceRoute {
        pub path: &'static str,
        pub status: u16,
        pub body: String,
    }

    impl MockRuntimeServiceRoute {
        pub(crate) fn json(path: &'static str, body: serde_json::Value) -> Self {
            Self {
                path,
                status: 200,
                body: serde_json::to_string(&body).expect("serialize mock route body"),
            }
        }
    }

    pub(crate) struct MockRuntimeService {
        port: u16,
        handle: Option<JoinHandle<()>>,
    }

    impl MockRuntimeService {
        pub(crate) fn spawn(auth_token: &str, routes: Vec<MockRuntimeServiceRoute>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock runtime service");
            listener
                .set_nonblocking(true)
                .expect("set mock runtime service nonblocking");

            let port = listener
                .local_addr()
                .expect("mock runtime service addr")
                .port();
            let auth_token = auth_token.to_string();

            let handle = thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(3);
                let mut handled = 0usize;

                while handled < routes.len() && Instant::now() < deadline {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream
                                .set_nonblocking(false)
                                .expect("set mock runtime service blocking");
                            stream
                                .set_read_timeout(Some(Duration::from_secs(1)))
                                .expect("set read timeout");

                            let mut request = String::new();
                            let mut buf = [0u8; 4096];
                            loop {
                                match stream.read(&mut buf) {
                                    Ok(0) => break,
                                    Ok(n) => {
                                        request.push_str(&String::from_utf8_lossy(&buf[..n]));
                                        if request.contains("\r\n\r\n") {
                                            break;
                                        }
                                    }
                                    Err(error)
                                        if error.kind() == std::io::ErrorKind::WouldBlock =>
                                    {
                                        thread::sleep(Duration::from_millis(10));
                                    }
                                    Err(error) if error.kind() == std::io::ErrorKind::TimedOut => {
                                        panic!("timed out reading mock runtime service request");
                                    }
                                    Err(error) => {
                                        panic!("read mock runtime service request: {error}")
                                    }
                                }
                            }

                            let route = &routes[handled];
                            let request_line = request
                                .lines()
                                .next()
                                .map(|line| line.trim_end_matches('\r'))
                                .unwrap_or_default();
                            assert_eq!(request_line, format!("GET {} HTTP/1.1", route.path));
                            let expected_auth = format!("Authorization: Bearer {auth_token}");
                            assert!(
                                request
                                    .lines()
                                    .any(|line| { line.trim_end_matches('\r') == expected_auth }),
                                "missing bearer token in request: {request}",
                            );

                            let status_text = if route.status == 200 { "OK" } else { "ERROR" };
                            let response = format!(
                                "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                route.status,
                                status_text,
                                route.body.len(),
                                route.body
                            );
                            stream
                                .write_all(response.as_bytes())
                                .expect("write mock runtime service response");
                            handled += 1;
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10));
                        }
                        Err(error) => panic!("accept mock runtime service connection: {error}"),
                    }
                }

                assert_eq!(
                    handled,
                    routes.len(),
                    "mock runtime service saw {handled} requests but expected {}",
                    routes.len()
                );
            });

            Self {
                port,
                handle: Some(handle),
            }
        }

        pub(crate) fn port(&self) -> u16 {
            self.port
        }

        pub(crate) fn finish(mut self) {
            if let Some(handle) = self.handle.take() {
                handle.join().expect("mock runtime service thread");
            }
        }
    }

    impl Drop for MockRuntimeService {
        fn drop(&mut self) {
            if let Some(handle) = self.handle.take() {
                if std::thread::panicking() {
                    let _ = handle.join();
                } else {
                    handle.join().expect("mock runtime service thread");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{MockRuntimeService, MockRuntimeServiceRoute};
    use super::*;
    use crate::runtime_service::{RUNTIME_SERVICE_PORT_ENV, RUNTIME_SERVICE_TOKEN_ENV};
    use std::sync::{Mutex, OnceLock};

    // Legacy env sentinel used to prove live runtime reads ignore the old
    // artifact-path boundary, even when a stale value is still present.
    const IGNORED_SNAPSHOT_ENV_NAME: &str = concat!("CAPACITOR_", "CORE_", "SNAPSHOT");

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    struct EnvGuard {
        key: &'static str,
        prior: Option<String>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::set_var(key, value);
            Self { key, prior }
        }

        fn unset(key: &'static str) -> Self {
            let prior = std::env::var(key).ok();
            std::env::remove_var(key);
            Self { key, prior }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.prior {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        match ENV_LOCK.get_or_init(|| Mutex::new(())).lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    #[test]
    fn sessions_snapshot_parses_entries() {
        let value = serde_json::json!([
            {
                "session_id": "session-1",
                "pid": 123,
                "state": "working",
                "cwd": "/repo",
                "project_path": "/repo",
                "updated_at": "2026-01-31T00:00:00Z",
                "state_changed_at": "2026-01-31T00:00:00Z",
                "is_alive": true
            }
        ]);

        let entries: Vec<RuntimeSessionRecord> =
            serde_json::from_value(value).expect("parse sessions");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].session_id, "session-1");
    }

    #[test]
    fn runtime_enabled_defaults_to_true_when_env_missing() {
        let _guard = env_lock();
        let _unset = EnvGuard::unset(ENABLE_ENV);
        assert!(runtime_enabled());
    }

    #[test]
    fn runtime_enabled_is_false_when_env_zero() {
        let _guard = env_lock();
        let _set = EnvGuard::set(ENABLE_ENV, "0");
        assert!(!runtime_enabled());
    }

    #[test]
    fn runtime_enabled_is_true_when_env_one() {
        let _guard = env_lock();
        let _set = EnvGuard::set(ENABLE_ENV, "1");
        assert!(runtime_enabled());
    }

    #[test]
    fn sessions_snapshot_does_not_assume_alive_state() {
        let _guard = env_lock();
        let snapshot = serde_json::json!({
            "projects": [],
            "sessions": [{
                "session_id": "session-1",
                "pid": 123,
                "cwd": "/repo",
                "project_id": "/repo/.git",
                "project_path": "/repo",
                "workspace_id": "workspace-1",
                "state": "working",
                "state_changed_at": "2026-03-05T00:00:00Z",
                "updated_at": "2026-03-05T00:00:00Z",
                "last_event": "user_prompt_submit",
                "last_activity_at": "2026-03-05T00:00:00Z",
                "tools_in_flight": 1,
                "ready_reason": null
            }],
            "shells": [],
            "routing": [],
            "diagnostics": {
                "events_ingested": 1,
                "sessions_tracked": 1,
                "shell_signals_tracked": 0,
                "events_skipped": 0,
                "stale_events_skipped": 0,
                "informational_events_skipped": 0,
                "reducer_events_skipped": 0,
                "last_error": null
            },
            "generated_at": "2026-03-05T00:00:00Z"
        });
        let runtime_service = MockRuntimeService::spawn(
            "snapshot-token",
            vec![MockRuntimeServiceRoute::json("/runtime/snapshot", snapshot)],
        );

        let _enable = EnvGuard::set(ENABLE_ENV, "1");
        let _ignored_snapshot = EnvGuard::set(
            IGNORED_SNAPSHOT_ENV_NAME,
            "/tmp/ignored-runtime-snapshot.json",
        );
        let _port = EnvGuard::set(
            RUNTIME_SERVICE_PORT_ENV,
            &runtime_service.port().to_string(),
        );
        let _token = EnvGuard::set(RUNTIME_SERVICE_TOKEN_ENV, "snapshot-token");

        let sessions = sessions_snapshot().expect("sessions snapshot");
        assert_eq!(sessions.sessions().len(), 1);
        assert_eq!(sessions.sessions()[0].is_alive, None);
        runtime_service.finish();
    }

    #[test]
    fn runtime_health_uses_runtime_service_health_endpoint() {
        let _guard = env_lock();
        let runtime_service = MockRuntimeService::spawn(
            "health-token",
            vec![MockRuntimeServiceRoute::json(
                "/health",
                serde_json::json!({
                    "status": "ok",
                    "pid": 4242,
                    "version": "runtime-service-test",
                    "protocol_version": 1,
                    "auth_mode": "bearer",
                    "service_mode": "bootstrap_only"
                }),
            )],
        );

        let _enable = EnvGuard::set(ENABLE_ENV, "1");
        let _ignored_snapshot = EnvGuard::set(
            IGNORED_SNAPSHOT_ENV_NAME,
            "/tmp/ignored-runtime-snapshot.json",
        );
        let _port = EnvGuard::set(
            RUNTIME_SERVICE_PORT_ENV,
            &runtime_service.port().to_string(),
        );
        let _token = EnvGuard::set(RUNTIME_SERVICE_TOKEN_ENV, "health-token");

        assert_eq!(runtime_health(), Some(true));
        runtime_service.finish();
    }
}
