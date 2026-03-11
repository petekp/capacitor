ALTER TABLE feedback_submissions RENAME COLUMN daemon_enabled TO runtime_enabled;
ALTER TABLE feedback_submissions RENAME COLUMN daemon_healthy TO runtime_healthy;
ALTER TABLE feedback_submissions RENAME COLUMN daemon_version TO runtime_version;
