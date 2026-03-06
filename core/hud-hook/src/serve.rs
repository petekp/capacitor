//! HTTP hook server for Capacitor.
//!
//! Long-lived process that receives Claude Code hook events via HTTP POST.
//! Processes events through the canonical `handle::handle_hook_input` pipeline.

use std::sync::atomic::{AtomicBool, Ordering};

use crate::hook_types::HookInput;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

pub fn run(port: u16) -> Result<(), String> {
    install_signal_handlers();

    let addr = format!("127.0.0.1:{port}");
    let server =
        tiny_http::Server::http(&addr).map_err(|e| format!("Failed to bind {addr}: {e}"))?;

    tracing::info!(port, "hud-hook serve listening");

    let _pid_guard = PidFile::write(port)?;

    // tiny_http::Server::incoming_requests() blocks until a request arrives
    // or the server is shut down. We use recv_timeout so we can check the
    // shutdown flag periodically.
    loop {
        if SHUTDOWN.load(Ordering::Relaxed) {
            tracing::info!("Shutdown signal received, exiting");
            break;
        }

        // Poll with 500ms timeout so SIGTERM is noticed promptly.
        let request = match server.recv_timeout(std::time::Duration::from_millis(500)) {
            Ok(Some(req)) => req,
            Ok(None) => continue, // timeout, loop back to check shutdown
            Err(e) => {
                tracing::warn!(error = %e, "Error receiving request");
                continue;
            }
        };

        dispatch(request);
    }

    Ok(())
}

fn dispatch(request: tiny_http::Request) {
    match (request.method(), request.url()) {
        (&tiny_http::Method::Get, "/health") => handle_health(request),
        (&tiny_http::Method::Post, "/hook") => handle_hook(request),
        _ => {
            let _ = request.respond(json_error(404, "not found"));
        }
    }
}

fn handle_health(request: tiny_http::Request) {
    let resp = tiny_http::Response::from_string(r#"{"status":"ok"}"#)
        .with_status_code(200)
        .with_header(json_content_type());
    let _ = request.respond(resp);
}

fn handle_hook(mut request: tiny_http::Request) {
    // Reject oversized payloads (hook events are small JSON, 1 MB is very generous)
    const MAX_BODY_BYTES: u64 = 1_024 * 1_024;
    if let Some(len) = request.body_length() {
        if (len as u64) > MAX_BODY_BYTES {
            let _ = request.respond(json_error(413, "body too large"));
            return;
        }
    }

    let mut reader = request.as_reader();
    let mut body_bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match std::io::Read::read(&mut reader, &mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if (body_bytes.len() + n) as u64 > MAX_BODY_BYTES {
                    let _ = request.respond(json_error(413, "body too large"));
                    return;
                }
                body_bytes.extend_from_slice(&chunk[..n]);
            }
            Err(e) => {
                tracing::debug!(error = %e, "Failed to read request body");
                let _ = request.respond(json_error(400, "failed to read body"));
                return;
            }
        }
    }
    let body = match String::from_utf8(body_bytes) {
        Ok(body) => body,
        Err(e) => {
            tracing::debug!(error = %e, "Failed to decode request body as UTF-8");
            let _ = request.respond(json_error(400, "failed to read body"));
            return;
        }
    };

    let hook_input: HookInput = match serde_json::from_str(&body) {
        Ok(input) => input,
        Err(e) => {
            tracing::debug!(error = %e, "Invalid hook JSON");
            let _ = request.respond(json_error(400, "invalid JSON"));
            return;
        }
    };

    match crate::handle::handle_hook_input(hook_input) {
        Ok(()) => {
            let resp = tiny_http::Response::from_string(r#"{"status":"ok"}"#)
                .with_status_code(200)
                .with_header(json_content_type());
            let _ = request.respond(resp);
        }
        Err(e) => {
            tracing::warn!(error = %e, "Hook processing failed");
            let _ = request.respond(json_error(500, "hook processing failed"));
        }
    }
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
    fn write(port: u16) -> Result<Self, String> {
        let runtime_dir = dirs::home_dir()
            .ok_or("Cannot determine home directory")?
            .join(".capacitor/runtime");

        fs_err::create_dir_all(&runtime_dir)
            .map_err(|e| format!("Failed to create runtime dir: {e}"))?;

        let path = runtime_dir.join(format!("hud-hook-serve-{port}.pid"));
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
