-- Weekly alpha triage report (last 7 days)

-- 1) Summary counts
SELECT
  COUNT(*) AS feedback_count,
  SUM(CASE WHEN include_project_paths = 1 THEN 1 ELSE 0 END) AS feedback_with_project_paths,
  MIN(submitted_at) AS first_feedback_at,
  MAX(submitted_at) AS last_feedback_at
FROM feedback_submissions
WHERE datetime(submitted_at) >= datetime('now', '-7 days');

-- 2) Latest feedback submissions
SELECT
  feedback_id,
  submitted_at,
  channel,
  include_project_paths,
  SUBSTR(REPLACE(feedback_text, '\n', ' '), 1, 140) AS feedback_preview
FROM feedback_submissions
WHERE datetime(submitted_at) >= datetime('now', '-7 days')
ORDER BY datetime(submitted_at) DESC
LIMIT 50;

-- 3) Top telemetry event types
SELECT
  event_type,
  COUNT(*) AS event_count
FROM telemetry_events
WHERE datetime(occurred_at) >= datetime('now', '-7 days')
GROUP BY event_type
ORDER BY event_count DESC, event_type ASC
LIMIT 20;

-- 4) Quick feedback delivery outcomes (from telemetry payload)
SELECT
  feedback_id,
  occurred_at,
  CAST(json_extract(payload_json, '$.issue_opened') AS INTEGER) AS issue_opened,
  CAST(json_extract(payload_json, '$.endpoint_attempted') AS INTEGER) AS endpoint_attempted,
  CAST(json_extract(payload_json, '$.endpoint_succeeded') AS INTEGER) AS endpoint_succeeded
FROM telemetry_events
WHERE event_type = 'quick_feedback_submitted'
  AND datetime(occurred_at) >= datetime('now', '-7 days')
ORDER BY datetime(occurred_at) DESC
LIMIT 100;
