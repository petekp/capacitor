//! SQLite persistence for capacitor-daemon.
//!
//! This is the single-writer store backing the daemon. We keep the schema
//! intentionally small in Phase 3: an append-only events table and a
//! materialized shell_state table for fast reads.

use capacitor_daemon_protocol::{EventEnvelope, EventType};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::process::get_process_start_time;
use crate::state::{ProcessLivenessRow, ShellEntry, ShellState};

pub struct Db {
    path: PathBuf,
}

impl Db {
    pub fn new(path: PathBuf) -> Result<Self, String> {
        let db = Self { path };
        db.init_schema()?;
        Ok(db)
    }

    pub fn insert_event(&self, event: &EventEnvelope) -> Result<(), String> {
        self.with_connection(|conn| {
            let payload = serde_json::to_string(event)
                .map_err(|err| format!("Failed to serialize event payload: {}", err))?;
            let event_type = serde_json::to_string(&event.event_type)
                .unwrap_or_else(|_| "unknown".to_string())
                .trim_matches('"')
                .to_string();

            conn.execute(
                "INSERT INTO events (id, recorded_at, event_type, session_id, pid, payload)\
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)\
                 ON CONFLICT(id) DO NOTHING",
                params![
                    event.event_id,
                    event.recorded_at,
                    event_type,
                    event.session_id,
                    event.pid,
                    payload
                ],
            )
            .map_err(|err| format!("Failed to insert event: {}", err))?;

            Ok(())
        })
    }

    pub fn upsert_shell_state(&self, event: &EventEnvelope) -> Result<(), String> {
        let (pid, cwd, tty) = match (event.pid, &event.cwd, &event.tty) {
            (Some(pid), Some(cwd), Some(tty)) => (pid, cwd, tty),
            _ => return Ok(()),
        };

        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO shell_state \
                    (pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
                 ON CONFLICT(pid) DO UPDATE SET \
                    cwd = excluded.cwd, \
                    tty = excluded.tty, \
                    parent_app = excluded.parent_app, \
                    tmux_session = excluded.tmux_session, \
                    tmux_client_tty = excluded.tmux_client_tty, \
                    updated_at = excluded.updated_at",
                params![
                    pid,
                    cwd,
                    tty,
                    event.parent_app,
                    event.tmux_session,
                    event.tmux_client_tty,
                    event.recorded_at
                ],
            )
            .map_err(|err| format!("Failed to upsert shell state: {}", err))?;

            Ok(())
        })
    }

    pub fn upsert_process_liveness(&self, event: &EventEnvelope) -> Result<(), String> {
        let pid = match event.pid {
            Some(pid) => pid,
            None => return Ok(()),
        };

        let proc_started = get_process_start_time(pid).map(|value| value as i64);

        self.with_connection(|conn| {
            conn.execute(
                "INSERT INTO process_liveness (pid, proc_started, last_seen_at) \
                 VALUES (?1, ?2, ?3) \
                 ON CONFLICT(pid) DO UPDATE SET \
                    proc_started = COALESCE(excluded.proc_started, process_liveness.proc_started), \
                    last_seen_at = excluded.last_seen_at",
                params![pid as i64, proc_started, event.recorded_at],
            )
            .map_err(|err| format!("Failed to upsert process liveness: {}", err))?;

            Ok(())
        })
    }

    pub fn get_process_liveness(&self, pid: u32) -> Result<Option<ProcessLivenessRow>, String> {
        self.with_connection(|conn| {
            conn.query_row(
                "SELECT pid, proc_started, last_seen_at FROM process_liveness WHERE pid = ?1",
                params![pid as i64],
                |row| {
                    Ok(ProcessLivenessRow {
                        pid: row.get::<_, i64>(0)? as u32,
                        proc_started: row.get::<_, Option<i64>>(1)?,
                        last_seen_at: row.get::<_, String>(2)?,
                    })
                },
            )
            .optional()
            .map_err(|err| format!("Failed to query process liveness: {}", err))
        })
    }

    pub fn ensure_process_liveness(&self) -> Result<(), String> {
        let count = self.with_connection(|conn| {
            conn.query_row("SELECT COUNT(*) FROM process_liveness", [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(|err| format!("Failed to count process_liveness rows: {}", err))
        })?;

        if count == 0 {
            self.rebuild_process_liveness_from_events()?;
        }

        Ok(())
    }

    pub fn rebuild_process_liveness_from_events(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            let entries: Vec<(i64, Option<i64>, String)> = {
                let mut stmt = conn
                    .prepare(
                        "SELECT pid, MAX(recorded_at) \
                         FROM events \
                         WHERE pid IS NOT NULL \
                         GROUP BY pid",
                    )
                    .map_err(|err| format!("Failed to prepare process replay query: {}", err))?;

                let rows = stmt
                    .query_map([], |row| {
                        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                    })
                    .map_err(|err| format!("Failed to read process replay rows: {}", err))?;

                let mut entries: Vec<(i64, Option<i64>, String)> = Vec::new();
                for row in rows {
                    let (pid, last_seen_at) =
                        row.map_err(|err| format!("Failed to decode process replay row: {}", err))?;
                    let proc_started = get_process_start_time(pid as u32).map(|value| value as i64);
                    entries.push((pid, proc_started, last_seen_at));
                }

                entries
            };

            let tx = conn
                .transaction()
                .map_err(|err| format!("Failed to start process replay transaction: {}", err))?;
            tx.execute("DELETE FROM process_liveness", [])
                .map_err(|err| format!("Failed to clear process_liveness table: {}", err))?;
            for (pid, proc_started, last_seen_at) in entries {
                tx.execute(
                    "INSERT INTO process_liveness (pid, proc_started, last_seen_at) \
                     VALUES (?1, ?2, ?3)",
                    params![pid, proc_started, last_seen_at],
                )
                .map_err(|err| format!("Failed to rebuild process_liveness table: {}", err))?;
            }
            tx.commit()
                .map_err(|err| format!("Failed to commit process replay: {}", err))?;

            Ok(())
        })
    }
    pub fn load_shell_state(&self) -> Result<ShellState, String> {
        self.with_connection(|conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at \
                     FROM shell_state",
                )
                .map_err(|err| format!("Failed to prepare shell_state query: {}", err))?;

            let rows = stmt
                .query_map([], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        ShellEntry {
                            cwd: row.get(1)?,
                            tty: row.get(2)?,
                            parent_app: row.get(3)?,
                            tmux_session: row.get(4)?,
                            tmux_client_tty: row.get(5)?,
                            updated_at: row.get(6)?,
                        },
                    ))
                })
                .map_err(|err| format!("Failed to read shell_state rows: {}", err))?;

            let mut state = ShellState::default();
            for row in rows {
                let (pid, entry) =
                    row.map_err(|err| format!("Failed to decode shell row: {}", err))?;
                state.shells.insert(pid.to_string(), entry);
            }

            Ok(state)
        })
    }

    pub fn rebuild_shell_state_from_events(&self) -> Result<ShellState, String> {
        self.with_connection(|conn| {
            let by_pid: HashMap<i64, ShellEntry> = {
                let shell_type = serde_json::to_string(&EventType::ShellCwd)
                    .unwrap_or_else(|_| "shell_cwd".to_string())
                    .trim_matches('"')
                    .to_string();

                let mut stmt = conn
                    .prepare(
                        "SELECT payload FROM events \
                     WHERE event_type = ?1 \
                     ORDER BY rowid ASC",
                    )
                    .map_err(|err| format!("Failed to prepare events replay query: {}", err))?;

                let rows = stmt
                    .query_map(params![shell_type], |row| row.get::<_, String>(0))
                    .map_err(|err| format!("Failed to read event payloads: {}", err))?;

                let mut by_pid: HashMap<i64, ShellEntry> = HashMap::new();
                for row in rows {
                    let payload =
                        row.map_err(|err| format!("Failed to decode event payload: {}", err))?;
                    let event: EventEnvelope = match serde_json::from_str(&payload) {
                        Ok(event) => event,
                        Err(err) => {
                            tracing::warn!(
                                error = %err,
                                "Skipping malformed event payload during replay"
                            );
                            continue;
                        }
                    };

                    let (pid, cwd, tty) = match (event.pid, event.cwd.as_ref(), event.tty.as_ref())
                    {
                        (Some(pid), Some(cwd), Some(tty)) => (pid as i64, cwd, tty),
                        _ => continue,
                    };

                    let entry = ShellEntry {
                        cwd: cwd.clone(),
                        tty: tty.clone(),
                        parent_app: event.parent_app.clone(),
                        tmux_session: event.tmux_session.clone(),
                        tmux_client_tty: event.tmux_client_tty.clone(),
                        updated_at: event.recorded_at.clone(),
                    };

                    by_pid.insert(pid, entry);
                }

                by_pid
            };

            let mut state = ShellState::default();
            for (pid, entry) in &by_pid {
                state.shells.insert(pid.to_string(), entry.clone());
            }

            let tx = conn.transaction().map_err(|err| {
                format!("Failed to start shell_state replay transaction: {}", err)
            })?;
            tx.execute("DELETE FROM shell_state", [])
                .map_err(|err| format!("Failed to clear shell_state table: {}", err))?;
            for (pid, entry) in by_pid {
                tx.execute(
                    "INSERT INTO shell_state \
                        (pid, cwd, tty, parent_app, tmux_session, tmux_client_tty, updated_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        pid,
                        entry.cwd,
                        entry.tty,
                        entry.parent_app,
                        entry.tmux_session,
                        entry.tmux_client_tty,
                        entry.updated_at
                    ],
                )
                .map_err(|err| format!("Failed to rebuild shell_state table: {}", err))?;
            }
            tx.commit()
                .map_err(|err| format!("Failed to commit shell_state replay: {}", err))?;

            Ok(state)
        })
    }

    fn init_schema(&self) -> Result<(), String> {
        self.with_connection(|conn| {
            conn.execute_batch(
                "BEGIN;
                 CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    recorded_at TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    session_id TEXT,
                    pid INTEGER,
                    payload TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS shell_state (
                    pid INTEGER PRIMARY KEY,
                    cwd TEXT NOT NULL,
                    tty TEXT NOT NULL,
                    parent_app TEXT,
                    tmux_session TEXT,
                    tmux_client_tty TEXT,
                    updated_at TEXT NOT NULL
                 );
                 CREATE TABLE IF NOT EXISTS process_liveness (
                    pid INTEGER PRIMARY KEY,
                    proc_started INTEGER,
                    last_seen_at TEXT NOT NULL
                 );
                 COMMIT;",
            )
            .map_err(|err| format!("Failed to initialize schema: {}", err))?;
            Ok(())
        })
    }

    fn with_connection<T>(
        &self,
        op: impl FnOnce(&mut Connection) -> Result<T, String>,
    ) -> Result<T, String> {
        let mut conn = self.open()?;
        op(&mut conn)
    }

    fn open(&self) -> Result<Connection, String> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("Failed to create daemon data dir: {}", err))?;
        }

        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_FULL_MUTEX;

        let conn = Connection::open_with_flags(&self.path, flags)
            .map_err(|err| format!("Failed to open sqlite db: {}", err))?;

        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|err| format!("Failed to enable WAL: {}", err))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|err| format!("Failed to set synchronous: {}", err))?;
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(|err| format!("Failed to set busy_timeout: {}", err))?;

        Ok(conn)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capacitor_daemon_protocol::{EventEnvelope, EventType};

    fn shell_event(
        event_id: &str,
        pid: u32,
        cwd: &str,
        tty: &str,
        recorded_at: &str,
    ) -> EventEnvelope {
        EventEnvelope {
            event_id: event_id.to_string(),
            recorded_at: recorded_at.to_string(),
            event_type: EventType::ShellCwd,
            session_id: None,
            pid: Some(pid),
            cwd: Some(cwd.to_string()),
            tool: None,
            file_path: None,
            parent_app: Some("Terminal".to_string()),
            tty: Some(tty.to_string()),
            tmux_session: None,
            tmux_client_tty: None,
            notification_type: None,
            stop_hook_active: None,
            metadata: None,
        }
    }

    #[test]
    fn rebuilds_shell_state_from_events() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        db.insert_event(&shell_event(
            "evt-1",
            123,
            "/repo",
            "/dev/ttys001",
            "2026-01-30T00:00:00Z",
        ))
        .expect("insert evt-1");
        db.insert_event(&shell_event(
            "evt-2",
            123,
            "/repo/app",
            "/dev/ttys001",
            "2026-01-30T00:01:00Z",
        ))
        .expect("insert evt-2");
        db.insert_event(&shell_event(
            "evt-3",
            456,
            "/repo/cli",
            "/dev/ttys002",
            "2026-01-30T00:02:00Z",
        ))
        .expect("insert evt-3");

        let state = db
            .rebuild_shell_state_from_events()
            .expect("rebuild shell state");

        assert_eq!(state.shells.len(), 2);
        let first = state.shells.get("123").expect("pid 123");
        assert_eq!(first.cwd, "/repo/app");
        assert_eq!(first.tty, "/dev/ttys001");
        assert_eq!(first.updated_at, "2026-01-30T00:01:00Z");

        let second = state.shells.get("456").expect("pid 456");
        assert_eq!(second.cwd, "/repo/cli");
        assert_eq!(second.tty, "/dev/ttys002");
        assert_eq!(second.updated_at, "2026-01-30T00:02:00Z");

        let loaded = db.load_shell_state().expect("load shell state");
        assert_eq!(loaded.shells.len(), 2);
        assert_eq!(loaded.shells.get("123").unwrap().cwd, "/repo/app");
        assert_eq!(loaded.shells.get("456").unwrap().cwd, "/repo/cli");
    }

    #[test]
    fn upserts_process_liveness_rows() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");
        let recorded_at = "2026-01-30T00:03:00Z";

        let event = shell_event(
            "evt-4",
            std::process::id(),
            "/tmp",
            "/dev/ttys007",
            recorded_at,
        );
        db.upsert_process_liveness(&event)
            .expect("upsert process liveness");

        let row = db
            .get_process_liveness(std::process::id())
            .expect("query process liveness")
            .expect("process row exists");

        assert_eq!(row.pid, std::process::id());
        assert_eq!(row.last_seen_at, recorded_at);
    }

    #[test]
    fn rebuilds_process_liveness_from_events() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let db_path = temp_dir.path().join("state.db");
        let db = Db::new(db_path).expect("db init");

        let alive_pid = std::process::id();
        let dead_pid = 999_999_999u32;

        db.insert_event(&shell_event(
            "evt-5",
            alive_pid,
            "/tmp",
            "/dev/ttys011",
            "2026-01-30T00:05:00Z",
        ))
        .expect("insert alive pid");
        db.insert_event(&shell_event(
            "evt-6",
            dead_pid,
            "/tmp",
            "/dev/ttys012",
            "2026-01-30T00:06:00Z",
        ))
        .expect("insert dead pid");

        db.rebuild_process_liveness_from_events()
            .expect("rebuild process liveness");

        let alive = db
            .get_process_liveness(alive_pid)
            .expect("query alive pid")
            .expect("alive pid row");
        assert_eq!(alive.last_seen_at, "2026-01-30T00:05:00Z");
        assert!(alive.proc_started.is_some());

        let dead = db
            .get_process_liveness(dead_pid)
            .expect("query dead pid")
            .expect("dead pid row");
        assert_eq!(dead.last_seen_at, "2026-01-30T00:06:00Z");
        assert!(dead.proc_started.is_none());
    }
}
