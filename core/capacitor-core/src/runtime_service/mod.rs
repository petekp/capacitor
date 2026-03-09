use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::domain::{
    AppSnapshot, IngestHookEventCommand, IngestShellSignalCommand, MutationOutcome,
};

pub const RUNTIME_SERVICE_BOOTSTRAP_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_BOOTSTRAP";
pub const RUNTIME_SERVICE_PORT_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_PORT";
pub const RUNTIME_SERVICE_TOKEN_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_TOKEN";
pub const RUNTIME_SERVICE_PROTOCOL_VERSION: u32 = 1;
pub const RUNTIME_SERVICE_DEFAULT_PORT: u16 = 7474;
pub const RUNTIME_SERVICE_VERSION: &str = "runtime-service-prototype-v1";
pub const RUNTIME_SERVICE_AUTH_MODE: &str = "bearer";
pub const RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY: &str = "bootstrap_only";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeServiceConnection {
    pub port: u16,
    pub auth_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeServiceBootstrap {
    port: u16,
    auth_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeServiceEndpoint {
    host: String,
    port: u16,
    auth_token: String,
}

impl RuntimeServiceEndpoint {
    #[must_use]
    pub fn localhost(port: u16, auth_token: impl Into<String>) -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port,
            auth_token: auth_token.into(),
        }
    }

    pub fn from_env() -> Result<Option<Self>, String> {
        let port = std::env::var(RUNTIME_SERVICE_PORT_ENV)
            .ok()
            .and_then(|value| value.trim().parse::<u16>().ok());
        let auth_token = std::env::var(RUNTIME_SERVICE_TOKEN_ENV)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());

        match (port, auth_token) {
            (Some(port), Some(auth_token)) => Ok(Some(Self::localhost(port, auth_token))),
            (None, None) => Ok(None),
            _ => Err(format!(
                "{} and {} must both be set to target the runtime service bootstrap",
                RUNTIME_SERVICE_PORT_ENV, RUNTIME_SERVICE_TOKEN_ENV
            )),
        }
    }

    pub fn discover(home_dir: &Path, default_port: u16) -> Result<Option<Self>, String> {
        if let Some(endpoint) = Self::from_env()? {
            return Ok(Some(endpoint));
        }

        let connection_path = RuntimeServiceBootstrap::connection_file_path(home_dir);
        if connection_path.exists() {
            let connection = serde_json::from_str::<RuntimeServiceConnection>(
                &fs_err::read_to_string(&connection_path).map_err(|error| {
                    format!(
                        "Failed to read runtime service connection at {:?}: {error}",
                        connection_path
                    )
                })?,
            )
            .map_err(|error| {
                format!(
                    "Failed to parse runtime service connection at {:?}: {error}",
                    connection_path
                )
            })?;

            return Ok(Some(Self::localhost(
                connection.port,
                connection.auth_token,
            )));
        }

        let token_path = RuntimeServiceBootstrap::token_file_path(home_dir, default_port);
        if !token_path.exists() {
            return Ok(None);
        }

        let auth_token = fs_err::read_to_string(&token_path)
            .map_err(|error| {
                format!(
                    "Failed to read runtime service token at {:?}: {error}",
                    token_path
                )
            })?
            .trim()
            .to_string();
        if auth_token.is_empty() {
            return Err(format!(
                "Runtime service token file {:?} was empty",
                token_path
            ));
        }

        Ok(Some(Self::localhost(default_port, auth_token)))
    }

    #[must_use]
    pub fn health_url(&self) -> String {
        format!("http://{}:{}/health", self.host, self.port)
    }

    #[must_use]
    pub fn snapshot_url(&self) -> String {
        format!("http://{}:{}/runtime/snapshot", self.host, self.port)
    }

    #[must_use]
    pub fn hook_event_ingest_url(&self) -> String {
        format!(
            "http://{}:{}/runtime/ingest/hook-event",
            self.host, self.port
        )
    }

    #[must_use]
    pub fn shell_signal_ingest_url(&self) -> String {
        format!(
            "http://{}:{}/runtime/ingest/shell-signal",
            self.host, self.port
        )
    }

    pub fn probe_health(&self) -> Result<RuntimeServiceHealth, String> {
        self.get_json("/health")
    }

    pub fn fetch_snapshot(&self) -> Result<AppSnapshot, String> {
        self.get_json("/runtime/snapshot")
    }

    pub fn ingest_hook_event(
        &self,
        command: &IngestHookEventCommand,
    ) -> Result<MutationOutcome, String> {
        self.post_json("/runtime/ingest/hook-event", command)
    }

    pub fn ingest_shell_signal(
        &self,
        command: &IngestShellSignalCommand,
    ) -> Result<MutationOutcome, String> {
        self.post_json("/runtime/ingest/shell-signal", command)
    }

    fn get_json<Response>(&self, path: &str) -> Result<Response, String>
    where
        Response: DeserializeOwned,
    {
        self.request_json::<(), Response>("GET", path, None)
    }

    fn post_json<Request, Response>(
        &self,
        path: &str,
        payload: &Request,
    ) -> Result<Response, String>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        self.request_json("POST", path, Some(payload))
    }

    fn request_json<Request, Response>(
        &self,
        method: &str,
        path: &str,
        payload: Option<&Request>,
    ) -> Result<Response, String>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        let body = payload
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| {
                format!("Failed to serialize runtime service payload for {path}: {error}")
            })?
            .unwrap_or_default();

        let mut stream = TcpStream::connect((self.host.as_str(), self.port))
            .map_err(|error| format!("Failed to connect to {}{}: {error}", self.host, path))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .map_err(|error| {
                format!(
                    "Failed to set read timeout for {}{}: {error}",
                    self.host, path
                )
            })?;

        let authorization = format!("Bearer {}", self.auth_token);
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}:{}\r\nAuthorization: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            self.host,
            self.port,
            authorization,
            body.len(),
            body
        );
        stream.write_all(request.as_bytes()).map_err(|error| {
            format!("Failed to write runtime service request to {path}: {error}")
        })?;
        let _ = stream.flush();

        let mut response = String::new();
        stream.read_to_string(&mut response).map_err(|error| {
            format!("Failed to read runtime service response from {path}: {error}")
        })?;

        let status = response
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|value| value.parse::<u16>().ok())
            .ok_or_else(|| format!("Invalid runtime service response from {path}"))?;
        let body = response
            .split_once("\r\n\r\n")
            .map(|(_, body)| body)
            .unwrap_or_default();

        if status != 200 {
            return Err(format!(
                "Runtime service request {method} {path} returned status {}: {}",
                status,
                body.trim()
            ));
        }

        serde_json::from_str::<Response>(body)
            .map_err(|error| format!("Invalid runtime service payload from {path}: {error}"))
    }
}

impl RuntimeServiceBootstrap {
    #[must_use]
    pub fn new(port: u16, auth_token: impl Into<String>) -> Self {
        Self {
            port,
            auth_token: auth_token.into(),
        }
    }

    #[must_use]
    pub fn port(&self) -> u16 {
        self.port
    }

    #[must_use]
    pub fn auth_token(&self) -> &str {
        &self.auth_token
    }

    #[must_use]
    pub fn authorization_header_value(&self) -> String {
        format!("Bearer {}", self.auth_token)
    }

    pub fn from_env(default_port: u16) -> Result<Option<Self>, String> {
        if !env_flag(RUNTIME_SERVICE_BOOTSTRAP_ENV) {
            return Ok(None);
        }

        let port = std::env::var(RUNTIME_SERVICE_PORT_ENV)
            .ok()
            .and_then(|value| value.trim().parse::<u16>().ok())
            .unwrap_or(default_port);

        let auth_token = std::env::var(RUNTIME_SERVICE_TOKEN_ENV)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                format!(
                    "{} must be set when {} is enabled",
                    RUNTIME_SERVICE_TOKEN_ENV, RUNTIME_SERVICE_BOOTSTRAP_ENV
                )
            })?;

        Ok(Some(Self::new(port, auth_token)))
    }

    #[must_use]
    pub fn is_authorized(&self, authorization: Option<&str>) -> bool {
        let expected = self.authorization_header_value();
        authorization
            .map(str::trim)
            .is_some_and(|header| header == expected)
    }

    #[must_use]
    pub fn health_report(&self) -> RuntimeServiceHealth {
        RuntimeServiceHealth {
            status: "ok".to_string(),
            pid: std::process::id(),
            version: format!("{}:{}", RUNTIME_SERVICE_VERSION, self.port),
            protocol_version: RUNTIME_SERVICE_PROTOCOL_VERSION,
            auth_mode: RUNTIME_SERVICE_AUTH_MODE.to_string(),
            service_mode: RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY.to_string(),
        }
    }

    #[must_use]
    pub fn token_file_path(home_dir: &Path, port: u16) -> PathBuf {
        home_dir
            .join(".capacitor")
            .join("runtime")
            .join(format!("runtime-service-{port}.token"))
    }

    #[must_use]
    pub fn connection_file_path(home_dir: &Path) -> PathBuf {
        home_dir
            .join(".capacitor")
            .join("runtime")
            .join("runtime-service.json")
    }

    pub fn write_token_file(&self, home_dir: &Path) -> Result<RuntimeServiceTokenGuard, String> {
        let path = Self::token_file_path(home_dir, self.port);
        let connection_path = Self::connection_file_path(home_dir);

        if let Some(parent) = path.parent() {
            fs_err::create_dir_all(parent)
                .map_err(|error| format!("Failed to create runtime service dir: {error}"))?;
        }

        fs_err::write(&path, &self.auth_token)
            .map_err(|error| format!("Failed to write runtime service token: {error}"))?;

        let connection = RuntimeServiceConnection {
            port: self.port,
            auth_token: self.auth_token.clone(),
        };
        fs_err::write(
            &connection_path,
            serde_json::to_string(&connection).map_err(|error| {
                format!("Failed to serialize runtime service connection: {error}")
            })?,
        )
        .map_err(|error| format!("Failed to write runtime service connection: {error}"))?;

        Ok(RuntimeServiceTokenGuard {
            paths: vec![path, connection_path],
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeServiceHealth {
    pub status: String,
    pub pid: u32,
    pub version: String,
    pub protocol_version: u32,
    pub auth_mode: String,
    pub service_mode: String,
}

pub struct RuntimeServiceTokenGuard {
    paths: Vec<PathBuf>,
}

impl Drop for RuntimeServiceTokenGuard {
    fn drop(&mut self) {
        for path in &self.paths {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn env_flag(key: &str) -> bool {
    std::env::var(key)
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::{RuntimeServiceBootstrap, RUNTIME_SERVICE_PROTOCOL_VERSION};

    #[test]
    fn bootstrap_requires_matching_bearer_token() {
        let bootstrap = RuntimeServiceBootstrap::new(7474, "secret-token");

        assert!(bootstrap.is_authorized(Some("Bearer secret-token")));
        assert!(!bootstrap.is_authorized(None));
        assert!(!bootstrap.is_authorized(Some("Bearer wrong-token")));
    }

    #[test]
    fn bootstrap_health_reports_authenticated_bootstrap_mode() {
        let bootstrap = RuntimeServiceBootstrap::new(7474, "secret-token");
        let health = bootstrap.health_report();

        assert_eq!(health.status, "ok");
        assert_eq!(health.protocol_version, RUNTIME_SERVICE_PROTOCOL_VERSION);
        assert_eq!(health.auth_mode, "bearer");
        assert_eq!(health.service_mode, "bootstrap_only");
        assert!(health.pid > 0);
        assert!(
            health.version.contains("runtime-service"),
            "version should identify the service shell: {}",
            health.version
        );
    }
}
