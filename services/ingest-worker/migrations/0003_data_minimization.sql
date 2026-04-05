-- Data minimization: make raw_json nullable and add received_at index.
--
-- D1/SQLite does not support ALTER COLUMN. The standard pattern is:
-- create new table → copy data → drop old → rename new.

-- === feedback_submissions ===
CREATE TABLE feedback_submissions_new (
  feedback_id TEXT PRIMARY KEY,
  submitted_at TEXT NOT NULL,
  received_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_received_at TEXT,
  feedback_text TEXT NOT NULL,
  app_version TEXT,
  build_number TEXT,
  channel TEXT,
  os_version TEXT,
  include_telemetry INTEGER NOT NULL DEFAULT 0,
  include_project_paths INTEGER NOT NULL DEFAULT 0,
  daemon_enabled INTEGER,
  daemon_healthy INTEGER,
  daemon_version TEXT,
  active_source TEXT,
  project_count INTEGER,
  session_total INTEGER,
  session_working INTEGER,
  session_ready INTEGER,
  session_waiting INTEGER,
  session_compacting INTEGER,
  session_idle INTEGER,
  session_with_attached INTEGER,
  session_thinking INTEGER,
  activation_has_trace INTEGER NOT NULL DEFAULT 0,
  activation_trace_digest TEXT,
  source_ip TEXT,
  user_agent TEXT,
  raw_json TEXT,
  runtime_enabled INTEGER,
  runtime_healthy INTEGER,
  runtime_version TEXT
);

INSERT INTO feedback_submissions_new
  SELECT feedback_id, submitted_at, received_at, last_received_at,
         feedback_text, app_version, build_number, channel, os_version,
         include_telemetry, include_project_paths,
         daemon_enabled, daemon_healthy, daemon_version,
         active_source, project_count,
         session_total, session_working, session_ready, session_waiting,
         session_compacting, session_idle, session_with_attached, session_thinking,
         activation_has_trace, activation_trace_digest,
         source_ip, user_agent, raw_json,
         runtime_enabled, runtime_healthy, runtime_version
  FROM feedback_submissions;

DROP TABLE feedback_submissions;
ALTER TABLE feedback_submissions_new RENAME TO feedback_submissions;

CREATE INDEX IF NOT EXISTS idx_feedback_submissions_submitted_at
  ON feedback_submissions(submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_submissions_channel
  ON feedback_submissions(channel);

-- === telemetry_events ===
CREATE TABLE telemetry_events_new (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at TEXT NOT NULL DEFAULT (datetime('now')),
  event_type TEXT NOT NULL,
  message TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  feedback_id TEXT,
  payload_json TEXT NOT NULL,
  raw_json TEXT,
  source_ip TEXT,
  user_agent TEXT
);

INSERT INTO telemetry_events_new
  SELECT id, received_at, event_type, message, occurred_at,
         feedback_id, payload_json, raw_json, source_ip, user_agent
  FROM telemetry_events;

DROP TABLE telemetry_events;
ALTER TABLE telemetry_events_new RENAME TO telemetry_events;

CREATE INDEX IF NOT EXISTS idx_telemetry_events_occurred_at
  ON telemetry_events(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_telemetry_events_event_type
  ON telemetry_events(event_type);
CREATE INDEX IF NOT EXISTS idx_telemetry_events_feedback_id
  ON telemetry_events(feedback_id)
  WHERE feedback_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_telemetry_events_received_at
  ON telemetry_events(received_at);
