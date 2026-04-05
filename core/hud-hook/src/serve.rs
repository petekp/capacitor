//! HTTP hook server for Capacitor.
//!
//! Long-lived process that receives Claude Code hook events via HTTP POST.
//! Processes events through the canonical `handle::handle_hook_input` pipeline.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use capacitor_core::{runtime::service::RuntimeServiceBootstrap, CoreRuntime};
use chrono::{DateTime, Utc};

use crate::{handlers, power::SleepTracker};

pub(crate) static SHUTDOWN: AtomicBool = AtomicBool::new(false);
static POLL_WAITERS: AtomicUsize = AtomicUsize::new(0);
const RUNTIME_ARTIFACT_PATH_ENV: &str = "CAPACITOR_RUNTIME_ARTIFACT_PATH";
const DEFAULT_RUNTIME_ARTIFACT_RELATIVE_PATH: &str = ".capacitor/runtime/app_snapshot.json";
const POLL_TIMEOUT_SECS_ENV: &str = "CAPACITOR_POLL_TIMEOUT_SECS";
const DEFAULT_POLL_TIMEOUT_SECS: u64 = 30;
const MAX_POLL_WAITERS: usize = 2;
const MAX_BODY_BYTES: u64 = 1_024 * 1_024;

pub(crate) struct PollWaiterGuard;

impl PollWaiterGuard {
    pub(crate) fn try_acquire() -> Option<Self> {
        let current_waiters = POLL_WAITERS.fetch_add(1, Ordering::Relaxed);
        if current_waiters >= MAX_POLL_WAITERS {
            POLL_WAITERS.fetch_sub(1, Ordering::Relaxed);
            return None;
        }

        Some(Self)
    }
}

impl Drop for PollWaiterGuard {
    fn drop(&mut self) {
        POLL_WAITERS.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(crate) struct RuntimeServerState {
    pub(crate) bootstrap: Option<RuntimeServiceBootstrap>,
    pub(crate) home_dir: PathBuf,
    pub(crate) runtime: Option<Arc<CoreRuntime>>,
    pub(crate) sleep_tracker: Arc<Mutex<SleepTracker>>,
    // Observability metrics
    pub(crate) started_at: Instant,
    pub(crate) gc_cycle_count: AtomicU64,
    pub(crate) gc_last_changed: AtomicBool,
    pub(crate) last_snapshot_served_at: Mutex<Option<String>>,
    pub(crate) last_hook_event_at: Mutex<Option<String>>,
    pub(crate) last_shell_signal_at: Mutex<Option<String>>,
}

impl RuntimeServerState {
    fn new(port: u16) -> Result<Self, String> {
        let bootstrap = RuntimeServiceBootstrap::from_env(port)?;
        let home_dir = dirs::home_dir().ok_or("Cannot determine home directory")?;
        let artifact_path = runtime_artifact_path()?;
        let runtime =
            CoreRuntime::new_with_snapshot_file(artifact_path.to_string_lossy().to_string())
                .map_err(|error| error.to_string())?;
        let sleep_tracker = Arc::new(Mutex::new(SleepTracker::new()));
        crate::runtime_client::register_service_runtime_with_sleep_tracker(
            Arc::clone(&runtime),
            Arc::clone(&sleep_tracker),
        )?;

        Ok(Self {
            bootstrap,
            home_dir,
            runtime: Some(runtime),
            sleep_tracker,
            started_at: Instant::now(),
            gc_cycle_count: AtomicU64::new(0),
            gc_last_changed: AtomicBool::new(false),
            last_snapshot_served_at: Mutex::new(None),
            last_hook_event_at: Mutex::new(None),
            last_shell_signal_at: Mutex::new(None),
        })
    }
}

pub fn run(port: u16) -> Result<(), String> {
    const GC_INTERVAL: Duration = Duration::from_secs(10);
    const SHUTDOWN_POLL_INTERVAL: Duration = Duration::from_millis(100);
    const WORKER_THREAD_COUNT: usize = 4;

    SHUTDOWN.store(false, Ordering::Relaxed);
    install_signal_handlers();

    let addr = format!("127.0.0.1:{port}");
    let server = Arc::new(
        tiny_http::Server::http(&addr).map_err(|e| format!("Failed to bind {addr}: {e}"))?,
    );
    let runtime_service = Arc::new(RuntimeServerState::new(port)?);

    tracing::info!(port, "hud-hook serve listening");

    let _pid_guard = PidFile::write(port, runtime_service.bootstrap.is_some())?;
    let _runtime_service_guard = runtime_service
        .bootstrap
        .as_ref()
        .map(|bootstrap| bootstrap.write_token_file(&runtime_service.home_dir))
        .transpose()?;

    let gc_shutdown = Arc::new((Mutex::new(()), Condvar::new()));

    let shutdown_server = Arc::clone(&server);
    let shutdown_signal = Arc::clone(&gc_shutdown);
    let shutdown_runtime = runtime_service.runtime.as_ref().map(Arc::clone);
    let shutdown_handle = thread::spawn(move || loop {
        thread::sleep(SHUTDOWN_POLL_INTERVAL);

        if SHUTDOWN.load(Ordering::Relaxed) {
            let (_, shutdown_condvar) = &*shutdown_signal;
            shutdown_condvar.notify_all();
            if let Some(runtime) = shutdown_runtime.as_ref() {
                runtime.notify_version_waiters();
            }
            for _ in 0..WORKER_THREAD_COUNT {
                shutdown_server.unblock();
            }
            break;
        }
    });

    let gc_signal = Arc::clone(&gc_shutdown);
    let gc_state = Arc::clone(&runtime_service);
    let gc_handle = thread::spawn(move || {
        let (shutdown_lock, shutdown_condvar) = &*gc_signal;
        let mut guard = shutdown_lock.lock().expect("gc shutdown lock poisoned");

        loop {
            let wait_result = shutdown_condvar
                .wait_timeout(guard, GC_INTERVAL)
                .expect("gc shutdown condvar poisoned");
            guard = wait_result.0;

            if SHUTDOWN.load(Ordering::Relaxed) {
                break;
            }

            if wait_result.1.timed_out() {
                if let Some(runtime) = gc_state.runtime.as_ref() {
                    let adjusted_now = adjusted_gc_reference_time(&gc_state.sleep_tracker);
                    match runtime.run_gc_at(adjusted_now) {
                        Ok(changed) => {
                            gc_state.gc_cycle_count.fetch_add(1, Ordering::Relaxed);
                            gc_state.gc_last_changed.store(changed, Ordering::Relaxed);
                        }
                        Err(error) => {
                            tracing::warn!(error = %error, "Periodic GC tick failed");
                        }
                    }
                }
            }
        }
    });

    let mut worker_handles = Vec::with_capacity(WORKER_THREAD_COUNT);
    for worker_id in 0..WORKER_THREAD_COUNT {
        let worker_server = Arc::clone(&server);
        let worker_state = Arc::clone(&runtime_service);
        worker_handles.push(thread::spawn(move || loop {
            match worker_server.recv() {
                Ok(request) => dispatch(request, worker_state.as_ref()),
                Err(error) => {
                    if !SHUTDOWN.load(Ordering::Relaxed) {
                        tracing::warn!(worker_id, error = %error, "Error receiving request");
                        SHUTDOWN.store(true, Ordering::Relaxed);
                    }
                    break;
                }
            }

            if SHUTDOWN.load(Ordering::Relaxed) {
                break;
            }
        }));
    }

    while !SHUTDOWN.load(Ordering::Relaxed) {
        thread::sleep(SHUTDOWN_POLL_INTERVAL);
    }

    tracing::info!("Shutdown signal received, exiting");

    shutdown_handle
        .join()
        .map_err(|_| "shutdown coordinator thread panicked".to_string())?;
    gc_handle
        .join()
        .map_err(|_| "gc thread panicked".to_string())?;
    for worker_handle in worker_handles {
        worker_handle
            .join()
            .map_err(|_| "worker thread panicked".to_string())?;
    }

    Ok(())
}

fn dispatch(request: tiny_http::Request, runtime_service: &RuntimeServerState) {
    match (request.method(), request.url()) {
        (&tiny_http::Method::Get, "/health") => {
            handlers::handle_health(request, runtime_service.bootstrap.as_ref())
        }
        (&tiny_http::Method::Get, url) if url.starts_with("/runtime/snapshot/poll") => {
            handlers::handle_runtime_poll_snapshot(request, runtime_service)
        }
        (&tiny_http::Method::Get, "/runtime/snapshot") => {
            handlers::handle_runtime_snapshot(request, runtime_service)
        }
        (&tiny_http::Method::Get, "/runtime/diagnostics") => {
            handlers::handle_runtime_diagnostics(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/routing/resolve") => {
            handlers::handle_runtime_resolve_routing(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/ingest/hook-event") => {
            handlers::handle_runtime_ingest_hook_event(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/power/sleep") => {
            handlers::handle_runtime_power_sleep(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/power/wake") => {
            handlers::handle_runtime_power_wake(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/ingest/shell-signal") => {
            handlers::handle_runtime_ingest_shell_signal(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/shell/unregister") => {
            handlers::handle_runtime_shell_unregister(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/delegation/mutate") => {
            handlers::handle_runtime_mutate_delegation(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/run/mutate") => {
            handlers::handle_runtime_mutate_run(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/hook") => handlers::handle_hook(request),
        _ => handlers::respond_not_found(request),
    }
}

fn runtime_artifact_path() -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var(RUNTIME_ARTIFACT_PATH_ENV) {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }

    let home = dirs::home_dir().ok_or("Cannot determine home directory")?;
    Ok(home.join(DEFAULT_RUNTIME_ARTIFACT_RELATIVE_PATH))
}

pub(crate) fn adjusted_gc_reference_time(
    sleep_tracker: &Arc<Mutex<SleepTracker>>,
) -> DateTime<Utc> {
    match sleep_tracker.lock() {
        Ok(sleep_tracker) => sleep_tracker.adjusted_now(),
        Err(_) => {
            tracing::warn!("Sleep tracker lock poisoned; falling back to current time");
            Utc::now()
        }
    }
}

pub(crate) fn read_json<T>(request: &mut tiny_http::Request) -> Result<T, tiny_http::ResponseBox>
where
    T: serde::de::DeserializeOwned,
{
    let body = read_request_body(request)?;
    serde_json::from_str::<T>(&body).map_err(|error| {
        tracing::debug!(error = %error, "Invalid request JSON");
        json_error(400, "invalid JSON")
    })
}

fn read_request_body(request: &mut tiny_http::Request) -> Result<String, tiny_http::ResponseBox> {
    if let Some(len) = request.body_length() {
        if (len as u64) > MAX_BODY_BYTES {
            return Err(json_error(413, "body too large"));
        }
    }

    let mut reader = request.as_reader();
    let mut body_bytes = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        match std::io::Read::read(&mut reader, &mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if (body_bytes.len() + n) as u64 > MAX_BODY_BYTES {
                    return Err(json_error(413, "body too large"));
                }
                body_bytes.extend_from_slice(&chunk[..n]);
            }
            Err(error) => {
                tracing::debug!(error = %error, "Failed to read request body");
                return Err(json_error(400, "failed to read body"));
            }
        }
    }

    String::from_utf8(body_bytes).map_err(|error| {
        tracing::debug!(error = %error, "Failed to decode request body as UTF-8");
        json_error(400, "failed to read body")
    })
}

pub(crate) fn respond_json<T>(request: tiny_http::Request, status: u16, payload: &T)
where
    T: serde::Serialize,
{
    let body = serde_json::to_string(payload)
        .unwrap_or_else(|_| r#"{"error":"serialization failed"}"#.to_string());
    let response = tiny_http::Response::from_string(body)
        .with_status_code(status)
        .with_header(json_content_type());
    let _ = request.respond(response);
}

pub(crate) fn parse_since_version(url: &str) -> Option<u64> {
    let query = url.split_once('?')?.1;
    query.split('&').find_map(|param| {
        param
            .strip_prefix("since_version=")
            .and_then(|value| value.parse::<u64>().ok())
    })
}

pub(crate) fn runtime_poll_timeout() -> Duration {
    std::env::var(POLL_TIMEOUT_SECS_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(DEFAULT_POLL_TIMEOUT_SECS))
}

pub(crate) fn json_error(status: u16, message: &str) -> tiny_http::ResponseBox {
    let body = serde_json::json!({ "error": message }).to_string();
    tiny_http::Response::from_string(body)
        .with_status_code(status)
        .with_header(json_content_type())
        .boxed()
}

pub(crate) fn json_content_type() -> tiny_http::Header {
    "Content-Type: application/json"
        .parse()
        .expect("valid header")
}

// ---------------------------------------------------------------------------
// Signal handling
// ---------------------------------------------------------------------------

fn install_signal_handlers() {
    // SAFETY: We only set an AtomicBool from the signal handler, which is
    // async-signal-safe. No heap allocation, no locks, no IO.
    #[allow(unsafe_code)]
    unsafe {
        let handler = signal_handler as *const () as libc::sighandler_t;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }
}

extern "C" fn signal_handler(_sig: libc::c_int) {
    SHUTDOWN.store(true, Ordering::Relaxed);
}

// ---------------------------------------------------------------------------
// PID file guard
// ---------------------------------------------------------------------------

struct PidFile {
    path: std::path::PathBuf,
}

impl PidFile {
    fn write(port: u16, runtime_service_enabled: bool) -> Result<Self, String> {
        let runtime_dir = dirs::home_dir()
            .ok_or("Cannot determine home directory")?
            .join(".capacitor/runtime");

        fs_err::create_dir_all(&runtime_dir)
            .map_err(|e| format!("Failed to create runtime dir: {e}"))?;
        std::fs::set_permissions(&runtime_dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("Failed to set runtime dir permissions: {e}"))?;

        let filename = if runtime_service_enabled {
            format!("runtime-service-{port}.pid")
        } else {
            format!("hud-hook-serve-{port}.pid")
        };
        let path = runtime_dir.join(filename);
        let pid = std::process::id();

        fs_err::write(&path, pid.to_string())
            .map_err(|e| format!("Failed to write PID file: {e}"))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("Failed to set PID file permissions: {e}"))?;

        tracing::debug!(?path, pid, "Wrote PID file");
        Ok(Self { path })
    }
}

impl Drop for PidFile {
    fn drop(&mut self) {
        if let Err(e) = std::fs::remove_file(&self.path) {
            tracing::warn!(error = %e, path = ?self.path, "Failed to remove PID file");
        }
    }
}
