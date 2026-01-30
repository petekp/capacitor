//! Capacitor daemon entrypoint.
//!
//! This is a small, single-writer service that owns state updates for the app.
//! Phase 1 keeps it minimal: a socket listener, strict request validation, and
//! a stub event handler so hooks can integrate safely.

use fs_err as fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

use capacitor_daemon_protocol::{
    parse_event, ErrorInfo, Method, Request, Response, MAX_REQUEST_BYTES, PROTOCOL_VERSION,
};

const SOCKET_NAME: &str = "daemon.sock";
const READ_TIMEOUT_SECS: u64 = 2;
const READ_CHUNK_SIZE: usize = 4096;

fn main() {
    init_logging();

    let socket_path = match daemon_socket_path() {
        Ok(path) => path,
        Err(err) => {
            error!(error = %err, "Failed to resolve daemon socket path");
            std::process::exit(1);
        }
    };

    if let Err(err) = prepare_socket_dir(&socket_path) {
        error!(error = %err, "Failed to prepare daemon socket directory");
        std::process::exit(1);
    }

    if let Err(err) = remove_existing_socket(&socket_path) {
        error!(error = %err, path = %socket_path.display(), "Failed to remove existing socket");
        std::process::exit(1);
    }

    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(err) => {
            error!(error = %err, path = %socket_path.display(), "Failed to bind daemon socket");
            std::process::exit(1);
        }
    };

    info!(path = %socket_path.display(), "Capacitor daemon started");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                thread::spawn(|| handle_connection(stream));
            }
            Err(err) => {
                warn!(error = %err, "Failed to accept daemon connection");
            }
        }
    }
}

fn init_logging() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}

fn daemon_socket_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Home directory not found".to_string())?;
    Ok(home.join(".capacitor").join(SOCKET_NAME))
}

fn prepare_socket_dir(socket_path: &Path) -> Result<(), String> {
    let parent = socket_path
        .parent()
        .ok_or_else(|| "Socket path has no parent".to_string())?;
    fs::create_dir_all(parent).map_err(|err| format!("Failed to create socket directory: {}", err))
}

fn remove_existing_socket(socket_path: &Path) -> Result<(), String> {
    if socket_path.exists() {
        fs::remove_file(socket_path)
            .map_err(|err| format!("Failed to remove existing socket: {}", err))?;
    }
    Ok(())
}

fn handle_connection(mut stream: UnixStream) {
    let request = match read_request(&mut stream) {
        Ok(request) => request,
        Err(err) => {
            let response = Response::error_with_info(None, err);
            let _ = write_response(&mut stream, response);
            return;
        }
    };

    let response = handle_request(request);
    let _ = write_response(&mut stream, response);
}

fn read_request(stream: &mut UnixStream) -> Result<Request, ErrorInfo> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(READ_TIMEOUT_SECS)));

    let mut buffer = Vec::new();
    let mut chunk = [0u8; READ_CHUNK_SIZE];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                if buffer.len() > MAX_REQUEST_BYTES {
                    return Err(ErrorInfo::new(
                        "request_too_large",
                        "request exceeded maximum size",
                    ));
                }
                if chunk[..n].contains(&b'\n') {
                    break;
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                return Err(ErrorInfo::new("read_timeout", "request timed out"));
            }
            Err(err) => {
                return Err(ErrorInfo::new(
                    "read_error",
                    format!("failed to read request: {}", err),
                ));
            }
        }
    }

    if buffer.is_empty() {
        return Err(ErrorInfo::new("empty_request", "request body was empty"));
    }

    let newline_index = buffer.iter().position(|b| *b == b'\n');
    let request_bytes = match newline_index {
        Some(index) => {
            if buffer.len() > index + 1 {
                let trailing = &buffer[index + 1..];
                if trailing.iter().any(|b| !b.is_ascii_whitespace()) {
                    warn!("Extra bytes detected after newline; ignoring trailing data");
                }
            }
            &buffer[..index]
        }
        None => buffer.as_slice(),
    };

    if request_bytes.iter().all(|b| b.is_ascii_whitespace()) {
        return Err(ErrorInfo::new("empty_request", "request body was empty"));
    }

    serde_json::from_slice(request_bytes).map_err(|err| {
        ErrorInfo::new(
            "invalid_json",
            format!("request was not valid JSON: {}", err),
        )
    })
}

fn handle_request(request: Request) -> Response {
    if request.protocol_version != PROTOCOL_VERSION {
        return Response::error(
            request.id,
            "protocol_mismatch",
            "unsupported protocol version",
        );
    }

    match request.method {
        Method::GetHealth => {
            let data = serde_json::json!({
                "status": "ok",
                "pid": std::process::id(),
                "version": env!("CARGO_PKG_VERSION"),
                "protocol_version": PROTOCOL_VERSION,
            });
            Response::ok(request.id, data)
        }
        Method::Event => handle_event(request),
    }
}

fn handle_event(request: Request) -> Response {
    let params = match request.params {
        Some(params) => params,
        None => return Response::error(request.id, "invalid_params", "event payload is required"),
    };

    let event = match parse_event(params) {
        Ok(event) => event,
        Err(err) => return Response::error_with_info(request.id, err),
    };

    info!(
        event_type = ?event.event_type,
        session_id = ?event.session_id,
        pid = ?event.pid,
        "Received event"
    );

    Response::ok(request.id, serde_json::json!({"accepted": true}))
}

fn write_response(stream: &mut UnixStream, response: Response) -> std::io::Result<()> {
    serde_json::to_writer(&mut *stream, &response)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}
