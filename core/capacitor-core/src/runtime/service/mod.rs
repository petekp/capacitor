use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::domain::{
    AppSnapshot, IngestHookEventCommand, IngestShellSignalCommand, MutateRunCommand,
    MutationOutcome, SCHEMA_VERSION,
};

pub const RUNTIME_SERVICE_BOOTSTRAP_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_BOOTSTRAP";
pub const RUNTIME_SERVICE_PORT_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_PORT";
pub const RUNTIME_SERVICE_TOKEN_ENV: &str = "CAPACITOR_RUNTIME_SERVICE_TOKEN";
pub const RUNTIME_SERVICE_PROTOCOL_VERSION: u32 = 1;
pub const RUNTIME_SERVICE_DEFAULT_PORT: u16 = 7474;
pub const RUNTIME_SERVICE_VERSION: &str = "runtime-service-prototype-v1";
pub const RUNTIME_SERVICE_AUTH_MODE: &str = "bearer";
pub const RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY: &str = "bootstrap_only";

/// Verify that a credential file has restrictive permissions (owner-only).
/// Rejects files readable by group or others to prevent token theft.
fn verify_credential_file_permissions(path: &Path) -> Result<(), String> {
    let metadata = std::fs::metadata(path).map_err(|error| {
        format!(
            "Failed to read metadata for credential file {:?}: {error}",
            path
        )
    })?;
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(format!(
            "Credential file {:?} has unsafe permissions {:o} (expected 0600 or stricter)",
            path, mode
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct RuntimeServiceConnection {
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

    pub(crate) fn from_env() -> Result<Option<Self>, String> {
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
            verify_credential_file_permissions(&connection_path)?;
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

        verify_credential_file_permissions(&token_path)?;
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

    #[must_use]
    pub(crate) fn run_mutate_url(&self) -> String {
        format!("http://{}:{}/runtime/run/mutate", self.host, self.port)
    }

    #[must_use]
    pub(crate) fn auth_token(&self) -> &str {
        &self.auth_token
    }

    pub(crate) fn probe_health(&self) -> Result<RuntimeServiceHealth, String> {
        let health: RuntimeServiceHealth = self.get_json("/health")?;
        health.validate_bootstrap_contract()?;
        Ok(health)
    }

    pub(crate) fn fetch_snapshot(&self) -> Result<AppSnapshot, String> {
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

    pub fn mutate_run(&self, command: &MutateRunCommand) -> Result<MutationOutcome, String> {
        self.post_json("/runtime/run/mutate", command)
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
        let url = format!("http://{}:{}{}", self.host, self.port, path);
        let authorization = format!("Bearer {}", self.auth_token);

        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(5))
            .build();

        let request = match method {
            "GET" => agent.get(&url),
            "POST" => agent.post(&url),
            _ => return Err(format!("Unsupported HTTP method: {method}")),
        }
        .set("Authorization", &authorization)
        .set("Content-Type", "application/json");

        let response = if let Some(payload) = payload {
            request.send_json(payload)
        } else {
            request.call()
        }
        .map_err(|error| format!("Runtime service request {method} {path} failed: {error}"))?;

        response
            .into_json::<Response>()
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
    pub(crate) fn authorization_header_value(&self) -> String {
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
            schema_version: SCHEMA_VERSION,
            auth_mode: RUNTIME_SERVICE_AUTH_MODE.to_string(),
            service_mode: RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY.to_string(),
        }
    }

    #[must_use]
    pub(crate) fn token_file_path(home_dir: &Path, port: u16) -> PathBuf {
        home_dir
            .join(".capacitor")
            .join("runtime")
            .join(format!("runtime-service-{port}.token"))
    }

    #[must_use]
    pub(crate) fn connection_file_path(home_dir: &Path) -> PathBuf {
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
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700)).map_err(
                |error| format!("Failed to set runtime service dir permissions: {error}"),
            )?;
        }

        fs_err::write(&path, &self.auth_token)
            .map_err(|error| format!("Failed to write runtime service token: {error}"))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("Failed to set token file permissions: {error}"))?;
        verify_credential_file_permissions(&path)?;

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
        std::fs::set_permissions(&connection_path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("Failed to set connection file permissions: {error}"))?;
        verify_credential_file_permissions(&connection_path)?;

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
    pub schema_version: u32,
    pub auth_mode: String,
    pub service_mode: String,
}

impl RuntimeServiceHealth {
    pub(crate) fn validate_bootstrap_contract(&self) -> Result<(), String> {
        if self.status != "ok" {
            return Err(format!(
                "Unexpected runtime service health status {:?}; expected \"ok\"",
                self.status
            ));
        }

        if self.protocol_version != RUNTIME_SERVICE_PROTOCOL_VERSION {
            return Err(format!(
                "Unexpected runtime service protocol version {}; expected {}",
                self.protocol_version, RUNTIME_SERVICE_PROTOCOL_VERSION
            ));
        }

        if self.schema_version < SCHEMA_VERSION {
            return Err(format!(
                "Unexpected runtime service schema version {}; expected at least {}",
                self.schema_version, SCHEMA_VERSION
            ));
        }

        if self.auth_mode != RUNTIME_SERVICE_AUTH_MODE {
            return Err(format!(
                "Unexpected runtime service auth mode {:?}; expected {:?}",
                self.auth_mode, RUNTIME_SERVICE_AUTH_MODE
            ));
        }

        if self.service_mode != RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY {
            return Err(format!(
                "Unexpected runtime service mode {:?}; expected {:?}",
                self.service_mode, RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY
            ));
        }

        Ok(())
    }
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
    use super::{
        RuntimeServiceBootstrap, RuntimeServiceHealth, RUNTIME_SERVICE_AUTH_MODE,
        RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY, RUNTIME_SERVICE_PROTOCOL_VERSION,
    };
    use crate::domain::SCHEMA_VERSION;

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
        assert_eq!(health.schema_version, SCHEMA_VERSION);
        assert_eq!(health.auth_mode, "bearer");
        assert_eq!(health.service_mode, "bootstrap_only");
        assert!(health.pid > 0);
        assert!(
            health.version.contains("runtime-service"),
            "version should identify the service shell: {}",
            health.version
        );
    }

    #[test]
    fn validate_bootstrap_contract_accepts_expected_health_shape() {
        let health = RuntimeServiceHealth {
            status: "ok".to_string(),
            pid: 4242,
            version: "runtime-service-test".to_string(),
            protocol_version: RUNTIME_SERVICE_PROTOCOL_VERSION,
            schema_version: SCHEMA_VERSION,
            auth_mode: RUNTIME_SERVICE_AUTH_MODE.to_string(),
            service_mode: RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY.to_string(),
        };

        assert!(health.validate_bootstrap_contract().is_ok());
    }

    #[test]
    fn validate_bootstrap_contract_rejects_mismatched_auth_mode() {
        let health = RuntimeServiceHealth {
            status: "ok".to_string(),
            pid: 4242,
            version: "runtime-service-test".to_string(),
            protocol_version: RUNTIME_SERVICE_PROTOCOL_VERSION,
            schema_version: SCHEMA_VERSION,
            auth_mode: "none".to_string(),
            service_mode: RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY.to_string(),
        };

        let error = health
            .validate_bootstrap_contract()
            .expect_err("mismatched auth mode should fail");
        assert!(error.contains("auth mode"), "unexpected error: {error}");
    }

    #[test]
    fn validate_bootstrap_contract_rejects_older_schema_version() {
        let health = RuntimeServiceHealth {
            status: "ok".to_string(),
            pid: 4242,
            version: "runtime-service-test".to_string(),
            protocol_version: RUNTIME_SERVICE_PROTOCOL_VERSION,
            schema_version: SCHEMA_VERSION.saturating_sub(1),
            auth_mode: RUNTIME_SERVICE_AUTH_MODE.to_string(),
            service_mode: RUNTIME_SERVICE_MODE_BOOTSTRAP_ONLY.to_string(),
        };

        let error = health
            .validate_bootstrap_contract()
            .expect_err("older schema version should fail");
        assert!(
            error.contains("schema version"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn write_token_file_sets_restrictive_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let bootstrap = RuntimeServiceBootstrap::new(7474, "test-token");
        let _guard = bootstrap.write_token_file(temp.path()).unwrap();

        let token_path = temp
            .path()
            .join(".capacitor/runtime/runtime-service-7474.token");
        let metadata = std::fs::metadata(&token_path).unwrap();
        assert_eq!(
            metadata.permissions().mode() & 0o777,
            0o600,
            "Token file should be 0600"
        );

        let dir_path = temp.path().join(".capacitor/runtime");
        let dir_metadata = std::fs::metadata(&dir_path).unwrap();
        assert_eq!(
            dir_metadata.permissions().mode() & 0o777,
            0o700,
            "Runtime dir should be 0700"
        );

        let conn_path = temp.path().join(".capacitor/runtime/runtime-service.json");
        let conn_metadata = std::fs::metadata(&conn_path).unwrap();
        assert_eq!(
            conn_metadata.permissions().mode() & 0o777,
            0o600,
            "Connection file should be 0600"
        );
    }

    #[test]
    fn write_token_file_verify_credential_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let bootstrap = RuntimeServiceBootstrap::new(7474, "test-token");

        let _guard = bootstrap
            .write_token_file(temp.path())
            .expect("write_token_file should verify credential permissions");

        let token_path = temp
            .path()
            .join(".capacitor/runtime/runtime-service-7474.token");
        let connection_path = temp.path().join(".capacitor/runtime/runtime-service.json");

        assert!(token_path.exists(), "Token file should exist");
        assert!(connection_path.exists(), "Connection file should exist");
        assert!(
            super::verify_credential_file_permissions(&token_path).is_ok(),
            "Token file should pass credential verification"
        );
        assert!(
            super::verify_credential_file_permissions(&connection_path).is_ok(),
            "Connection file should pass credential verification"
        );

        let token_metadata = std::fs::metadata(&token_path).unwrap();
        assert_eq!(
            token_metadata.permissions().mode() & 0o777,
            0o600,
            "Token file should be 0600"
        );

        let connection_metadata = std::fs::metadata(&connection_path).unwrap();
        assert_eq!(
            connection_metadata.permissions().mode() & 0o777,
            0o600,
            "Connection file should be 0600"
        );
    }

    #[test]
    fn verify_credential_file_permissions_rejects_group_readable() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let file_path = temp.path().join("test-cred");
        std::fs::write(&file_path, "secret").unwrap();

        // 0644 (group/other readable) → must reject
        std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            super::verify_credential_file_permissions(&file_path).is_err(),
            "Should reject 0644"
        );

        // 0600 (owner-only) → must accept
        std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            super::verify_credential_file_permissions(&file_path).is_ok(),
            "Should accept 0600"
        );

        // 0640 (group readable) → must reject
        std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o640)).unwrap();
        assert!(
            super::verify_credential_file_permissions(&file_path).is_err(),
            "Should reject 0640"
        );
    }

    #[test]
    fn request_json_times_out_on_unresponsive_server() {
        use super::RuntimeServiceEndpoint;
        use std::net::TcpListener;

        // Bind to get a valid port, then drop the listener so the connection
        // is refused immediately. This validates the ureq error path without
        // blocking for the full 5-second timeout.
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().port()
        };

        let endpoint = RuntimeServiceEndpoint::localhost(port, "test-token");

        let start = std::time::Instant::now();
        let result: Result<serde_json::Value, String> = endpoint.get_json("/health");
        let elapsed = start.elapsed();

        assert!(result.is_err());
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "Should timeout within 10s, took {:?}",
            elapsed
        );
    }
}
