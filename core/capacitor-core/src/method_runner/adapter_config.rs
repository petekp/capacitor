//! Configuration and preflight validation for real subprocess adapters.
//!
//! `AdapterConfig` is constructed once per run. It validates that required
//! binaries exist, probes the codex version, and provides shared helpers
//! for environment allowlisting and preflight persistence.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::method_runner::adapters::AdapterError;

// ---------------------------------------------------------------------------
// Environment allowlist
// ---------------------------------------------------------------------------

/// Keys allowed in subprocess environments. Everything else is stripped.
const ENV_ALLOWLIST: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "SHELL",
    "LANG",
    "LC_ALL",
    "TERM",
    "TMPDIR",
    "XDG_RUNTIME_DIR",
    "CAPACITOR_EXECUTION_ROOT",
    "CIRCUIT_PLUGIN_SKILL_DIR",
    "CIRCUIT_PLUGIN_CODEX_DIR",
];

/// Build a filtered environment from the current process, keeping only
/// allowlisted keys plus any explicit overrides.
pub fn build_allowed_env(overrides: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = ENV_ALLOWLIST
        .iter()
        .filter_map(|key| std::env::var(key).ok().map(|val| (key.to_string(), val)))
        .collect();

    for (key, val) in overrides {
        // Override if already present, otherwise append
        if let Some(entry) = env.iter_mut().find(|(k, _)| k == key) {
            entry.1 = val.to_string();
        } else {
            env.push((key.to_string(), val.to_string()));
        }
    }

    env
}

// ---------------------------------------------------------------------------
// AdapterConfig
// ---------------------------------------------------------------------------

/// Validated configuration for real subprocess adapters.
///
/// Construction validates that both `script_path` (compose-prompt.sh) and
/// `codex_path` (codex binary) exist and are executable-shaped. The codex
/// version is probed opportunistically — failure to probe is not fatal.
#[derive(Debug, Clone)]
pub struct AdapterConfig {
    /// Absolute path to `compose-prompt.sh`.
    pub script_path: PathBuf,
    /// Absolute path to the `codex` binary.
    pub codex_path: PathBuf,
    /// Project root directory (becomes cwd for worker subprocesses).
    pub project_root: PathBuf,
    /// Default timeout for worker subprocesses.
    pub default_timeout: Duration,
    /// Grace period after SIGTERM before escalating to SIGKILL.
    pub kill_grace_period: Duration,
    /// Probed codex version string, if available.
    pub codex_version: Option<String>,
    /// Additional adapter-owned env overrides passed to subprocesses.
    /// Per INV-7, these are layered on top of the allowlisted environment.
    pub env_overrides: Vec<(String, String)>,
}

impl AdapterConfig {
    /// Construct and validate a new adapter configuration.
    ///
    /// Fails immediately if `script_path` or `codex_path` do not exist.
    pub fn new(
        script_path: PathBuf,
        codex_path: PathBuf,
        project_root: PathBuf,
        default_timeout: Duration,
        kill_grace_period: Duration,
    ) -> Result<Self, AdapterError> {
        // Validate compose-prompt script exists
        if !script_path.exists() {
            return Err(AdapterError::SpawnFailed(format!(
                "compose-prompt script not found: {}",
                script_path.display()
            )));
        }

        // Validate codex binary exists
        if !codex_path.exists() {
            return Err(AdapterError::SpawnFailed(format!(
                "codex binary not found: {}",
                codex_path.display()
            )));
        }

        // Probe codex version (best-effort)
        let codex_version = probe_codex_version(&codex_path);

        Ok(Self {
            script_path,
            codex_path,
            project_root,
            default_timeout,
            kill_grace_period,
            codex_version,
            env_overrides: Vec::new(),
        })
    }
}

// ---------------------------------------------------------------------------
// Codex version probe
// ---------------------------------------------------------------------------

/// Best-effort probe of `codex --version`. Returns None on any failure.
fn probe_codex_version(codex_path: &Path) -> Option<String> {
    let output = Command::new(codex_path)
        .arg("--version")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if version.is_empty() {
        None
    } else {
        Some(version)
    }
}

// ---------------------------------------------------------------------------
// Preflight persistence
// ---------------------------------------------------------------------------

/// Write `adapter/preflight.json` under `relay_root` if it doesn't already exist.
/// Called lazily on the first real adapter invocation.
pub fn write_preflight_if_needed(relay_root: &Path, config: &AdapterConfig) -> std::io::Result<()> {
    let adapter_dir = relay_root.join("adapter");
    let preflight_path = adapter_dir.join("preflight.json");

    if preflight_path.exists() {
        return Ok(());
    }

    std::fs::create_dir_all(&adapter_dir)?;

    let preflight = serde_json::json!({
        "script_path": config.script_path.to_string_lossy(),
        "codex_path": config.codex_path.to_string_lossy(),
        "codex_version": config.codex_version,
        "project_root": config.project_root.to_string_lossy(),
        "default_timeout_secs": config.default_timeout.as_secs_f64(),
        "kill_grace_period_secs": config.kill_grace_period.as_secs_f64(),
    });

    std::fs::write(&preflight_path, serde_json::to_string_pretty(&preflight)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_env_allowlist_filters_ambient() {
        // Set a non-allowlisted variable
        std::env::set_var("__ADAPTER_TEST_JUNK", "should_not_appear");

        let env = build_allowed_env(&[]);
        let keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();

        assert!(
            !keys.contains(&"__ADAPTER_TEST_JUNK"),
            "non-allowlisted key must not appear"
        );

        // PATH should be present (it's almost always set)
        assert!(keys.contains(&"PATH"), "PATH should be in allowlist");

        std::env::remove_var("__ADAPTER_TEST_JUNK");
    }

    #[test]
    fn test_env_overrides_append_and_replace() {
        let env = build_allowed_env(&[("CUSTOM_KEY", "custom_val"), ("PATH", "/override")]);

        let custom = env.iter().find(|(k, _)| k == "CUSTOM_KEY");
        assert!(custom.is_some(), "override should be appended");
        assert_eq!(custom.unwrap().1, "custom_val");

        let path = env.iter().find(|(k, _)| k == "PATH");
        assert!(path.is_some(), "PATH should still be present");
        assert_eq!(path.unwrap().1, "/override", "PATH should be overridden");
    }

    #[test]
    fn test_env_allowlist_keeps_capacitor_execution_root() {
        std::env::set_var("CAPACITOR_EXECUTION_ROOT", "/tmp/execution-root");

        let env = build_allowed_env(&[]);
        let execution_root = env.iter().find(|(k, _)| k == "CAPACITOR_EXECUTION_ROOT");

        assert!(
            execution_root.is_some(),
            "CAPACITOR_EXECUTION_ROOT should be preserved"
        );
        assert_eq!(
            execution_root.unwrap().1,
            "/tmp/execution-root",
            "CAPACITOR_EXECUTION_ROOT should keep its value"
        );

        std::env::remove_var("CAPACITOR_EXECUTION_ROOT");
    }
}
