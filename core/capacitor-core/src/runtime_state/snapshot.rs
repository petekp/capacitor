//! Runtime snapshot helpers for session liveness checks.
//!
//! The canonical core runtime snapshot is authoritative; callers should not
//! fall back to bespoke local derivations.

use crate::domain::AppSnapshot;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::path::PathBuf;

const ENABLE_ENV: &str = "CAPACITOR_CORE_ENABLED";
const SNAPSHOT_ENV: &str = "CAPACITOR_CORE_SNAPSHOT";
const DEFAULT_SNAPSHOT_RELATIVE_PATH: &str = ".capacitor/runtime/app_snapshot.json";

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

    pub fn latest_for_project(&self, project_path: &str) -> Option<&RuntimeSessionRecord> {
        let home_dir = dirs::home_dir().map(|path| path.to_string_lossy().to_string());
        let mut best: Option<&RuntimeSessionRecord> = None;

        for session in &self.sessions {
            let matches = crate::runtime_state::path_utils::path_is_parent_or_self_excluding_home(
                project_path,
                &session.project_path,
                home_dir.as_deref(),
            );

            if !matches {
                continue;
            }

            let is_newer = match best {
                None => true,
                Some(existing) => is_more_recent(session, existing),
            };

            if is_newer {
                best = Some(session);
            }
        }

        best
    }
}

pub fn sessions_snapshot() -> Option<RuntimeSessionsSnapshot> {
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
            is_alive: Some(true),
        })
        .collect();

    Some(RuntimeSessionsSnapshot { sessions })
}

pub(crate) fn runtime_health() -> Option<bool> {
    if !runtime_enabled() {
        return None;
    }

    Some(load_runtime_snapshot().ok().flatten().is_some())
}

pub(crate) fn runtime_enabled() -> bool {
    env_flag(ENABLE_ENV).unwrap_or(true)
}

fn load_runtime_snapshot() -> Result<Option<AppSnapshot>, String> {
    let snapshot_path = snapshot_path()?;
    if !snapshot_path.exists() {
        return Ok(None);
    }

    let payload = std::fs::read_to_string(&snapshot_path)
        .map_err(|err| format!("Failed reading runtime snapshot: {err}"))?;

    let snapshot = serde_json::from_str::<AppSnapshot>(&payload)
        .map_err(|err| format!("Failed parsing runtime snapshot: {err}"))?;

    Ok(Some(snapshot))
}

fn snapshot_path() -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var(SNAPSHOT_ENV) {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }

    let home = dirs::home_dir().ok_or_else(|| "Cannot determine home directory".to_string())?;
    Ok(home.join(DEFAULT_SNAPSHOT_RELATIVE_PATH))
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

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
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

fn is_more_recent(left: &RuntimeSessionRecord, right: &RuntimeSessionRecord) -> bool {
    let left_ts = parse_rfc3339(&left.updated_at).or_else(|| parse_rfc3339(&left.state_changed_at));
    let right_ts =
        parse_rfc3339(&right.updated_at).or_else(|| parse_rfc3339(&right.state_changed_at));

    match (left_ts, right_ts) {
        (Some(left), Some(right)) => left > right,
        (Some(_), None) => true,
        (None, Some(_)) => false,
        (None, None) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

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
        ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    fn make_session_record(
        session_id: &str,
        project_path: &str,
        updated_at: &str,
    ) -> RuntimeSessionRecord {
        RuntimeSessionRecord {
            session_id: session_id.to_string(),
            pid: 123,
            state: "working".to_string(),
            cwd: project_path.to_string(),
            project_path: project_path.to_string(),
            updated_at: updated_at.to_string(),
            state_changed_at: updated_at.to_string(),
            last_event: None,
            last_activity_at: None,
            tools_in_flight: 0,
            ready_reason: None,
            is_alive: Some(true),
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
    fn latest_for_project_matches_subpath() {
        let snapshot = RuntimeSessionsSnapshot {
            sessions: vec![make_session_record(
                "session-1",
                "/Users/pete/Code/assistant-ui/packages/web",
                "2026-02-01T00:00:00Z",
            )],
        };

        let selected = snapshot
            .latest_for_project("/Users/pete/Code/assistant-ui")
            .expect("expected parent project to match child session path");

        assert_eq!(
            selected.project_path,
            "/Users/pete/Code/assistant-ui/packages/web"
        );
    }

    #[test]
    fn latest_for_project_does_not_match_parent_path() {
        let snapshot = RuntimeSessionsSnapshot {
            sessions: vec![make_session_record(
                "session-1",
                "/Users/pete/Code/assistant-ui",
                "2026-02-01T00:00:00Z",
            )],
        };

        let selected = snapshot.latest_for_project("/Users/pete/Code/assistant-ui/packages/web");

        assert!(selected.is_none());
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
}
