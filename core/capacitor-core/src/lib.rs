//! Canonical Capacitor core runtime.
//!
//! This crate is the long-term source of truth for runtime facts, ingest,
//! reducer/query state, and projections exposed through UniFFI.

uniffi::setup_scaffolding!();

mod core_diagnostics;
mod core_gc;
mod core_ideas;
mod core_ingest;
mod core_lifecycle;
mod core_query;
#[cfg(test)]
#[path = "core_runtime_tests.rs"]
mod tests;

pub mod domain;
pub mod ingest;
pub mod method_runner;
pub mod observation;
pub mod reduce;
pub mod runtime;
pub mod runtime_stats;
pub mod storage;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use chrono::{DateTime, Utc};
use domain::{
    AppSnapshot, IngestHookEventCommand, IngestOsLivenessCommand, IngestShellSignalCommand,
    MutateDelegationCommand, MutateProjectCommand, MutationOutcome, ResolveRoutingCommand,
    RoutingView,
};
use runtime::{
    artifacts::{count_artifacts_in_dir, count_hooks_in_dir},
    config::{load_hud_config_with_storage, resolve_symlink, save_hud_config_with_storage},
    projects::{has_project_indicators, load_projects_with_storage},
    sessions::ProjectStatus,
    setup::{DependencyStatus, HookStatus, InstallResult, SetupChecker, SetupStatus},
    storage::StorageConfig,
    types::{
        DashboardData, GlobalConfig, HookDiagnosticReport, HookIssue, HookTestResult, Plugin,
        PluginManifest, SuggestedProject,
    },
    validation::{create_claude_md, validate_project_path, ValidationResultFfi},
};
use storage::{InMemorySnapshotStorage, JsonFileSnapshotStorage, SnapshotStorage};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreRuntimeError {
    #[error("{message}")]
    General { message: String },
}

impl From<String> for CoreRuntimeError {
    fn from(message: String) -> Self {
        Self::General { message }
    }
}

impl From<&str> for CoreRuntimeError {
    fn from(message: &str) -> Self {
        Self::General {
            message: message.to_string(),
        }
    }
}

/// C2-Phase2 SWIFTJOIN (STEP 3): export the canonical PURE-STRING path matcher so
/// the Swift side can delegate matching-time normalization to the SAME Rust
/// implementation the reducers use, eliminating cross-language normalize drift.
///
/// This is intentionally the pure-string normalizer (`domain::identity::
/// normalize_path_for_matching`): it trims trailing slashes and lowercases on
/// macOS but does NOT touch the filesystem (no symlink resolution, no `.`/`..`
/// collapsing). FS-touching, capture-time canonicalization stays on whichever
/// side owns it (Rust `workspace_id` canonicalize; Swift `PathNormalizer` symlink
/// resolution) — see PathNormalizer for what Swift keeps vs delegates.
#[uniffi::export]
#[must_use]
pub fn normalize_path_for_matching(path: String) -> String {
    domain::normalize_path_for_matching(&path)
}

#[derive(uniffi::Object)]
pub struct CoreRuntime {
    state: Mutex<reduce::ReducerState>,
    snapshot_storage: Arc<dyn SnapshotStorage>,
    app_storage: StorageConfig,
    version: AtomicU64,
    notifier: VersionNotifier,
}

pub(crate) struct VersionNotifier {
    lock: Mutex<()>,
    condvar: Condvar,
}

impl VersionNotifier {
    fn new() -> Self {
        Self {
            lock: Mutex::new(()),
            condvar: Condvar::new(),
        }
    }

    fn notify(&self) {
        // If the mutex is poisoned, skip notification. The version counter has
        // already been bumped via AtomicU64, so the next poll will still observe
        // the change. Panicking here would cross the FFI boundary into Swift.
        let Ok(_guard) = self.lock.lock() else {
            return;
        };
        self.condvar.notify_all();
    }

    /// Wait until version differs from `since_version` or timeout.
    /// Returns the new version, or None on timeout.
    fn wait_for_change(
        &self,
        version: &AtomicU64,
        since_version: u64,
        timeout: std::time::Duration,
    ) -> Option<u64> {
        let current = version.load(Ordering::Relaxed);
        if current != since_version {
            return Some(current);
        }

        let deadline = std::time::Instant::now() + timeout;
        // If the mutex is poisoned, return None so the caller treats it like a
        // timeout and re-polls. This avoids a panic that would cross the FFI
        // boundary into Swift.
        let mut guard = match self.lock.lock() {
            Ok(g) => g,
            Err(_) => return None,
        };

        loop {
            let current = version.load(Ordering::Relaxed);
            if current != since_version {
                return Some(current);
            }

            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }

            let (next_guard, wait_result) = match self.condvar.wait_timeout(guard, remaining) {
                Ok(result) => result,
                Err(_) => return None,
            };
            guard = next_guard;

            if wait_result.timed_out() {
                let current = version.load(Ordering::Relaxed);
                return (current != since_version).then_some(current);
            }
        }
    }
}

impl CoreRuntime {
    fn from_storage(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Result<Arc<Self>, CoreRuntimeError> {
        Self::from_storage_inner(snapshot_storage, app_storage, false)
    }

    fn from_storage_with_transcript_cold_start(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Result<Arc<Self>, CoreRuntimeError> {
        Self::from_storage_inner(snapshot_storage, app_storage, true)
    }

    fn from_storage_inner(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
        cold_start_transcript_scan: bool,
    ) -> Result<Arc<Self>, CoreRuntimeError> {
        let loaded = snapshot_storage
            .load_snapshot()
            .map_err(CoreRuntimeError::from)?;

        let state = if let Some(snapshot) = loaded {
            reduce::ReducerState::from_snapshot(snapshot)
        } else if cold_start_transcript_scan {
            let mut state = reduce::ReducerState::default();
            let discoveries = observation::transcript::scan_for_sessions(app_storage.claude_root());
            for discovery in discoveries {
                let _ = state.apply_transcript_discovery(discovery);
            }
            state
        } else {
            reduce::ReducerState::default()
        };

        Ok(Arc::new(Self {
            state: Mutex::new(state),
            snapshot_storage,
            app_storage,
            version: AtomicU64::new(0),
            notifier: VersionNotifier::new(),
        }))
    }

    fn lock_state(
        &self,
    ) -> Result<std::sync::MutexGuard<'_, reduce::ReducerState>, CoreRuntimeError> {
        self.state
            .lock()
            .map_err(|_| CoreRuntimeError::from("runtime state lock poisoned"))
    }

    fn bump_version_and_notify(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
        self.notifier.notify();
    }

    /// Single mutation epilogue shared by every shaped state mutator.
    ///
    /// Locks the reducer state once, runs `mutate` to produce a
    /// [`MutationOutcome`], applies ONE documented rule — bump the change
    /// version and wake long-pollers **only when `outcome.ok`** — then
    /// snapshots, drops the lock, and persists. A rejected mutation
    /// (`outcome.ok == false`) changed no state, so it must neither advance the
    /// change counter nor wake any waiter. See `core_ingest.rs::try_commit` for
    /// the rollback variant used by run mutations with an external commit hook.
    fn commit<F>(&self, mutate: F) -> Result<MutationOutcome, CoreRuntimeError>
    where
        F: FnOnce(&mut reduce::ReducerState) -> MutationOutcome,
    {
        let mut state = self.lock_state()?;
        let outcome = mutate(&mut state);
        if outcome.ok {
            self.bump_version_and_notify();
        }
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    /// Rollback-aware [`commit`] for mutators with an external commit hook.
    ///
    /// Shares the exact epilogue and the bump-on-ok rule of [`commit`]; the
    /// `mutate` closure owns the rollback decision (it holds `&mut ReducerState`
    /// and can restore a prior clone before returning an `ok:false` outcome).
    /// Because the closure returns the *final* outcome, a rollback path that
    /// returns `ok:false` is automatically excluded from the version bump.
    fn try_commit<F>(&self, mutate: F) -> Result<MutationOutcome, CoreRuntimeError>
    where
        F: FnOnce(&mut reduce::ReducerState) -> MutationOutcome,
    {
        self.commit(mutate)
    }

    fn persist_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), CoreRuntimeError> {
        self.snapshot_storage
            .save_snapshot(snapshot)
            .map_err(CoreRuntimeError::from)
    }

    fn setup_checker(&self) -> SetupChecker {
        SetupChecker::new(self.app_storage.clone())
    }

    fn list_plugins_internal(&self) -> Result<Vec<Plugin>, CoreRuntimeError> {
        let registry_path = self
            .app_storage
            .claude_root()
            .join("plugins")
            .join("installed_plugins.json");
        if !registry_path.exists() {
            return Ok(Vec::new());
        }

        let content = fs_err::read_to_string(&registry_path)
            .map_err(|e| CoreRuntimeError::from(format!("Failed to read plugin registry: {e}")))?;

        #[derive(serde::Deserialize)]
        struct Registry {
            plugins: HashMap<String, Vec<PluginInfo>>,
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct PluginInfo {
            install_path: String,
        }

        let registry: Registry = serde_json::from_str(&content)
            .map_err(|e| CoreRuntimeError::from(format!("Failed to parse plugin registry: {e}")))?;

        let settings_path = self.app_storage.claude_root().join("settings.json");
        let enabled_plugins: HashMap<String, bool> = if settings_path.exists() {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Settings {
                enabled_plugins: Option<HashMap<String, bool>>,
            }

            fs_err::read_to_string(&settings_path)
                .ok()
                .and_then(|c| serde_json::from_str::<Settings>(&c).ok())
                .and_then(|s| s.enabled_plugins)
                .unwrap_or_default()
        } else {
            HashMap::new()
        };

        let mut plugins = Vec::new();

        for (id, installs) in registry.plugins {
            if let Some(install) = installs.first() {
                let plugin_path = PathBuf::from(&install.install_path);

                let manifest_path = plugin_path.join(".claude-plugin").join("plugin.json");
                let manifest: Option<PluginManifest> = fs_err::read_to_string(&manifest_path)
                    .ok()
                    .and_then(|c| serde_json::from_str(&c).ok());

                let name = manifest
                    .as_ref()
                    .map(|m| m.name.clone())
                    .unwrap_or_else(|| id.clone());
                let description = manifest
                    .as_ref()
                    .and_then(|m| m.description.clone())
                    .unwrap_or_default();

                let enabled = enabled_plugins.get(&id).copied().unwrap_or(true);

                plugins.push(Plugin {
                    id: id.clone(),
                    name,
                    description,
                    enabled,
                    path: install.install_path.clone(),
                    skill_count: count_artifacts_in_dir(&plugin_path.join("skills"), "skills"),
                    command_count: count_artifacts_in_dir(
                        &plugin_path.join("commands"),
                        "commands",
                    ),
                    agent_count: count_artifacts_in_dir(&plugin_path.join("agents"), "agents"),
                    hook_count: count_hooks_in_dir(&plugin_path),
                });
            }
        }

        plugins.sort_by_key(|plugin| plugin.name.to_lowercase());
        Ok(plugins)
    }

    fn test_runtime_service_health(&self) -> bool {
        runtime::state::snapshot::runtime_health().unwrap_or(false)
    }
}

fn heartbeat_status(
    age_secs: u64,
    threshold_secs: u64,
    grace_secs: u64,
    has_active_session: bool,
) -> runtime::types::HookHealthStatus {
    if age_secs <= threshold_secs {
        return runtime::types::HookHealthStatus::Healthy;
    }

    if has_active_session && age_secs <= grace_secs {
        return runtime::types::HookHealthStatus::Healthy;
    }

    runtime::types::HookHealthStatus::Stale {
        last_seen_secs: age_secs,
    }
}

fn hook_event_age_secs(timestamp: Option<&str>) -> Option<u64> {
    let timestamp = timestamp?;
    let parsed = chrono::DateTime::parse_from_rfc3339(timestamp).ok()?;
    let parsed = parsed.with_timezone(&Utc);
    let age = Utc::now().signed_duration_since(parsed).num_seconds();
    if age < 0 {
        Some(0)
    } else {
        Some(age as u64)
    }
}

fn has_active_runtime_session(
    snapshot: Option<&runtime::state::snapshot::RuntimeSessionsSnapshot>,
    max_age_secs: u64,
) -> bool {
    let snapshot = match snapshot {
        Some(snapshot) => snapshot,
        None => return false,
    };

    let now = Utc::now();
    snapshot
        .sessions()
        .iter()
        .any(|record| runtime_session_is_active_for_health(record, now, max_age_secs))
}

fn runtime_session_is_active_for_health(
    record: &runtime::state::snapshot::RuntimeSessionRecord,
    now: DateTime<Utc>,
    max_age_secs: u64,
) -> bool {
    if !matches!(
        record.state.to_ascii_lowercase().as_str(),
        "working" | "waiting" | "compacting"
    ) {
        return false;
    }

    let last_activity = record
        .last_activity_at
        .as_deref()
        .and_then(parse_rfc3339_utc)
        .or_else(|| parse_rfc3339_utc(&record.updated_at))
        .or_else(|| parse_rfc3339_utc(&record.state_changed_at));

    let recently_active = last_activity
        .map(|timestamp| now.signed_duration_since(timestamp).num_seconds() <= max_age_secs as i64)
        .unwrap_or(false);

    let is_alive = record.is_alive.unwrap_or(recently_active);
    is_alive && recently_active
}

fn parse_rfc3339_utc(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|timestamp| timestamp.with_timezone(&Utc))
}
