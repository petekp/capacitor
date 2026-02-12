CREATE TABLE IF NOT EXISTS feedback_submissions (
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
  raw_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feedback_submissions_submitted_at
  ON feedback_submissions(submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_feedback_submissions_channel
  ON feedback_submissions(channel);

CREATE TABLE IF NOT EXISTS telemetry_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at TEXT NOT NULL DEFAULT (datetime('now')),
  event_type TEXT NOT NULL,
  message TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  feedback_id TEXT,
  payload_json TEXT NOT NULL,
  raw_json TEXT NOT NULL,
  source_ip TEXT,
  user_agent TEXT
);

CREATE INDEX IF NOT EXISTS idx_telemetry_events_occurred_at
  ON telemetry_events(occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_telemetry_events_event_type
  ON telemetry_events(event_type);

CREATE INDEX IF NOT EXISTS idx_telemetry_events_feedback_id
  ON telemetry_events(feedback_id)
  WHERE feedback_id IS NOT NULL;
