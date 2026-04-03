//! HTTP hook server for Capacitor.
//!
//! Long-lived process that receives Claude Code hook events via HTTP POST.
//! Processes events through the canonical `handle::handle_hook_input` pipeline.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use capacitor_core::{
    domain::{
        IngestHookEventCommand, IngestShellSignalCommand, MutateDelegationCommand,
        MutateRunCommand, ResolveRoutingCommand,
    },
    runtime_service::RuntimeServiceBootstrap,
    CoreRuntime,
};

use crate::hook_types::HookInput;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);
const RUNTIME_ARTIFACT_PATH_ENV: &str = "CAPACITOR_RUNTIME_ARTIFACT_PATH";
const DEFAULT_RUNTIME_ARTIFACT_RELATIVE_PATH: &str = ".capacitor/runtime/app_snapshot.json";
const MAX_BODY_BYTES: u64 = 1_024 * 1_024;

struct RuntimeServerState {
    bootstrap: Option<RuntimeServiceBootstrap>,
    home_dir: PathBuf,
    runtime: Option<Arc<CoreRuntime>>,
}

impl RuntimeServerState {
    fn new(port: u16) -> Result<Self, String> {
        let bootstrap = RuntimeServiceBootstrap::from_env(port)?;
        let home_dir = dirs::home_dir().ok_or("Cannot determine home directory")?;
        let artifact_path = runtime_artifact_path()?;
        let runtime =
            CoreRuntime::new_with_snapshot_file(artifact_path.to_string_lossy().to_string())
                .map_err(|error| error.to_string())?;
        crate::runtime_client::register_service_runtime(Arc::clone(&runtime))?;

        Ok(Self {
            bootstrap,
            home_dir,
            runtime: Some(runtime),
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
    let shutdown_handle = thread::spawn(move || loop {
        thread::sleep(SHUTDOWN_POLL_INTERVAL);

        if SHUTDOWN.load(Ordering::Relaxed) {
            let (_, shutdown_condvar) = &*shutdown_signal;
            shutdown_condvar.notify_all();
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
                    if let Err(error) = runtime.run_gc() {
                        tracing::warn!(error = %error, "Periodic GC tick failed");
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
            handle_health(request, runtime_service.bootstrap.as_ref())
        }
        (&tiny_http::Method::Get, "/runtime/snapshot") => {
            handle_runtime_snapshot(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/routing/resolve") => {
            handle_runtime_resolve_routing(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/ingest/hook-event") => {
            handle_runtime_ingest_hook_event(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/ingest/shell-signal") => {
            handle_runtime_ingest_shell_signal(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/delegation/mutate") => {
            handle_runtime_mutate_delegation(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/runtime/run/mutate") => {
            handle_runtime_mutate_run(request, runtime_service)
        }
        (&tiny_http::Method::Post, "/hook") => handle_hook(request),
        _ => {
            let _ = request.respond(json_error(404, "not found"));
        }
    }
}

fn handle_health(request: tiny_http::Request, runtime_service: Option<&RuntimeServiceBootstrap>) {
    let resp = if let Some(bootstrap) = runtime_service {
        let authorization = request
            .headers()
            .iter()
            .find(|header| header.field.equiv("Authorization"))
            .map(|header| header.value.as_str());

        if !bootstrap.is_authorized(authorization) {
            json_error(401, "unauthorized")
        } else {
            tiny_http::Response::from_string(
                serde_json::to_string(&bootstrap.health_report())
                    .unwrap_or_else(|_| r#"{"error":"health unavailable"}"#.to_string()),
            )
            .with_status_code(200)
            .with_header(json_content_type())
            .boxed()
        }
    } else {
        tiny_http::Response::from_string(r#"{"status":"ok"}"#)
            .with_status_code(200)
            .with_header(json_content_type())
            .boxed()
    };
    let _ = request.respond(resp);
}

fn handle_runtime_snapshot(request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    match runtime.app_snapshot() {
        Ok(snapshot) => respond_json(request, 200, &snapshot),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime snapshot request failed");
            let _ = request.respond(json_error(500, "runtime snapshot failed"));
        }
    }
}

fn handle_runtime_ingest_hook_event(mut request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<IngestHookEventCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.ingest_hook_event(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime hook ingest request failed");
            let _ = request.respond(json_error(500, "runtime hook ingest failed"));
        }
    }
}

fn handle_runtime_resolve_routing(mut request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<ResolveRoutingCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.resolve_routing(command) {
        Ok(route) => respond_json(request, 200, &route),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime route resolve request failed");
            let _ = request.respond(json_error(500, "runtime route resolve failed"));
        }
    }
}

fn handle_runtime_ingest_shell_signal(mut request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<IngestShellSignalCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.ingest_shell_signal(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime shell ingest request failed");
            let _ = request.respond(json_error(500, "runtime shell ingest failed"));
        }
    }
}

fn handle_runtime_mutate_delegation(mut request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<MutateDelegationCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.mutate_delegation(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime delegation mutation request failed");
            let _ = request.respond(json_error(500, "runtime delegation mutation failed"));
        }
    }
}

fn handle_runtime_mutate_run(mut request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<MutateRunCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    let command_clone = command.clone();
    match runtime.mutate_run(command) {
        Ok(outcome) => {
            crate::checkpoint_bridge_relay::relay_decision(
                &state.home_dir,
                &command_clone,
                &outcome,
            );
            respond_json(request, 200, &outcome);
        }
        Err(error) => {
            tracing::warn!(error = %error, "Runtime run mutation request failed");
            let _ = request.respond(json_error(500, "runtime run mutation failed"));
        }
    }
}

fn handle_hook(mut request: tiny_http::Request) {
    let hook_input: HookInput = match read_json::<HookInput>(&mut request) {
        Ok(input) => input,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match crate::handle::handle_hook_input(hook_input) {
        Ok(()) => {
            respond_json(request, 200, &serde_json::json!({ "status": "ok" }));
        }
        Err(e) => {
            tracing::warn!(error = %e, "Hook processing failed");
            let _ = request.respond(json_error(500, "hook processing failed"));
        }
    }
}

fn authorize_runtime_request(
    request: &tiny_http::Request,
    runtime_service: Option<&RuntimeServiceBootstrap>,
) -> bool {
    let Some(bootstrap) = runtime_service else {
        return false;
    };

    let authorization = request
        .headers()
        .iter()
        .find(|header| header.field.equiv("Authorization"))
        .map(|header| header.value.as_str());

    bootstrap.is_authorized(authorization)
}

fn read_json<T>(request: &mut tiny_http::Request) -> Result<T, tiny_http::ResponseBox>
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

fn respond_json<T>(request: tiny_http::Request, status: u16, payload: &T)
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

fn json_error(status: u16, message: &str) -> tiny_http::ResponseBox {
    let body = serde_json::json!({"error": message}).to_string();
    tiny_http::Response::from_string(body)
        .with_status_code(status)
        .with_header(json_content_type())
        .boxed()
}

fn json_content_type() -> tiny_http::Header {
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

        let filename = if runtime_service_enabled {
            format!("runtime-service-{port}.pid")
        } else {
            format!("hud-hook-serve-{port}.pid")
        };
        let path = runtime_dir.join(filename);
        let pid = std::process::id();

        fs_err::write(&path, pid.to_string())
            .map_err(|e| format!("Failed to write PID file: {e}"))?;

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
