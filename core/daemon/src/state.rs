//! In-memory state managed by the daemon.
//!
//! Phase 3 persists an append-only event log plus a materialized shell CWD
//! table, keeping shell state fast to query while other state remains event-only.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

use crate::db::Db;
use crate::process::get_process_start_time;

pub struct SharedState {
    db: Db,
    shell_state: Mutex<ShellState>,
}

impl SharedState {
    pub fn new(db: Db) -> Self {
        let shell_state = match db.load_shell_state() {
            Ok(state) if !state.shells.is_empty() => state,
            Ok(state) => match db.rebuild_shell_state_from_events() {
                Ok(rebuilt) if !rebuilt.shells.is_empty() => rebuilt,
                Ok(_) => state,
                Err(err) => {
                    tracing::warn!(error = %err, "Failed to rebuild shell_state from events");
                    state
                }
            },
            Err(err) => {
                tracing::warn!(error = %err, "Failed to load shell_state table");
                db.rebuild_shell_state_from_events().unwrap_or_default()
            }
        };
        if let Err(err) = db.ensure_process_liveness() {
            tracing::warn!(error = %err, "Failed to ensure process liveness table");
        }
        Self {
            db,
            shell_state: Mutex::new(shell_state),
        }
    }

    pub fn update_from_event(&self, event: &EventEnvelope) {
        if let Err(err) = self.db.insert_event(event) {
            tracing::warn!(error = %err, "Failed to persist daemon event");
            return;
        }

        if let Err(err) = self.db.upsert_process_liveness(event) {
            tracing::warn!(error = %err, "Failed to update process liveness");
        }

        if event.event_type == EventType::ShellCwd {
            if let Err(err) = self.db.upsert_shell_state(event) {
                tracing::warn!(error = %err, "Failed to update shell_state table");
                return;
            }

            self.update_shell_state_cache(event);
        }
    }

    pub fn shell_state_snapshot(&self) -> ShellState {
        self.shell_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default()
    }

    pub fn process_liveness_snapshot(&self, pid: u32) -> Result<Option<ProcessLiveness>, String> {
        let row = self.db.get_process_liveness(pid)?;
        Ok(row.map(|row| {
            let current_start = get_process_start_time(pid);
            let stored_start = row.proc_started.map(|value| value as u64);
            let identity_matches = match (stored_start, current_start) {
                (Some(stored), Some(current)) => Some(stored.abs_diff(current) <= 2),
                _ => None,
            };

            ProcessLiveness {
                pid: row.pid,
                proc_started: stored_start,
                last_seen_at: row.last_seen_at,
                current_start_time: current_start,
                is_alive: current_start.is_some(),
                identity_matches,
            }
        }))
    }

    fn update_shell_state_cache(&self, event: &EventEnvelope) {
        let (pid, cwd, tty) = match (event.pid, &event.cwd, &event.tty) {
            (Some(pid), Some(cwd), Some(tty)) => (pid, cwd, tty),
            _ => return,
        };

        let entry = ShellEntry {
            cwd: cwd.clone(),
            tty: tty.clone(),
            parent_app: event.parent_app.clone(),
            tmux_session: event.tmux_session.clone(),
            tmux_client_tty: event.tmux_client_tty.clone(),
            updated_at: event.recorded_at.clone(),
        };

        if let Ok(mut state) = self.shell_state.lock() {
            state.shells.insert(pid.to_string(), entry);
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ProcessLivenessRow {
    pub pid: u32,
    pub proc_started: Option<i64>,
    pub last_seen_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProcessLiveness {
    pub pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proc_started: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_start_time: Option<u64>,
    pub last_seen_at: String,
    pub is_alive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity_matches: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ShellState {
    pub version: u32,
    pub shells: HashMap<String, ShellEntry>,
}

impl Default for ShellState {
    fn default() -> Self {
        Self {
            version: 1,
            shells: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_app: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_client_tty: Option<String>,
    pub updated_at: String,
}
