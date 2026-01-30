use fs_err as fs;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::thread;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

const PROTOCOL_VERSION: u32 = 1;
const SOCKET_NAME: &str = "daemon.sock";

#[derive(Debug, Deserialize)]
struct Request {
    protocol_version: u32,
    method: String,
    #[serde(default)]
    params: Option<Value>,
}

#[derive(Debug, Serialize)]
struct Response {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorInfo>,
}

#[derive(Debug, Serialize)]
struct ErrorInfo {
    code: String,
    message: String,
}

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
    let mut buffer = String::new();
    if let Err(err) = stream.read_to_string(&mut buffer) {
        warn!(error = %err, "Failed to read daemon request");
        let _ = write_error(&mut stream, "read_error", "Failed to read request");
        return;
    }

    if buffer.trim().is_empty() {
        let _ = write_error(&mut stream, "empty_request", "Request body was empty");
        return;
    }

    let request: Request = match serde_json::from_str(&buffer) {
        Ok(req) => req,
        Err(err) => {
            warn!(error = %err, "Invalid daemon request JSON");
            let _ = write_error(&mut stream, "invalid_json", "Request was not valid JSON");
            return;
        }
    };

    if request.protocol_version != PROTOCOL_VERSION {
        let _ = write_error(
            &mut stream,
            "protocol_mismatch",
            "Unsupported protocol version",
        );
        return;
    }

    match request.method.as_str() {
        "get_health" => {
            let data = serde_json::json!({
                "status": "ok",
                "pid": std::process::id(),
                "version": env!("CARGO_PKG_VERSION"),
                "protocol_version": PROTOCOL_VERSION,
            });
            let _ = write_ok(&mut stream, data);
        }
        "event" => {
            info!(
                "Received event: {:?}",
                request.params.as_ref().map(|_| "payload")
            );
            let _ = write_ok(&mut stream, serde_json::json!({"accepted": true}));
        }
        _ => {
            let _ = write_error(&mut stream, "unknown_method", "Unknown method");
        }
    }
}

fn write_ok(stream: &mut UnixStream, data: Value) -> std::io::Result<()> {
    let response = Response {
        ok: true,
        data: Some(data),
        error: None,
    };
    write_response(stream, response)
}

fn write_error(stream: &mut UnixStream, code: &str, message: &str) -> std::io::Result<()> {
    let response = Response {
        ok: false,
        data: None,
        error: Some(ErrorInfo {
            code: code.to_string(),
            message: message.to_string(),
        }),
    };
    write_response(stream, response)
}

fn write_response(stream: &mut UnixStream, response: Response) -> std::io::Result<()> {
    serde_json::to_writer(&mut *stream, &response)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}
