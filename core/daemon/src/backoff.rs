use chrono::{DateTime, Utc};
use fs_err as fs;
use serde::{Deserialize, Serialize};
use std::cmp;
use std::path::Path;
use std::thread;
use std::time::Duration as StdDuration;
use tracing::warn;

const WINDOW_SECS: i64 = 120;
const MAX_STARTS: usize = 3;
const BACKOFF_STEP_SECS: u64 = 10;
const BACKOFF_MAX_SECS: u64 = 60;

#[derive(Default, Serialize, Deserialize)]
struct BackoffState {
    starts: Vec<String>,
}

pub fn apply_startup_backoff(path: &Path) {
    let now = Utc::now();
    let mut state = load_state(path).unwrap_or_default();
    let backoff_secs = compute_backoff(now, &mut state);

    if let Err(err) = save_state(path, &state) {
        warn!(error = %err, "Failed to persist daemon backoff state");
    }

    if let Some(secs) = backoff_secs {
        warn!(
            count = state.starts.len(),
            backoff_secs = secs,
            "Daemon start backoff engaged"
        );
        thread::sleep(StdDuration::from_secs(secs));
    }
}

fn compute_backoff(now: DateTime<Utc>, state: &mut BackoffState) -> Option<u64> {
    state.starts.retain(|value| {
        parse_timestamp(value)
            .map(|timestamp| now.signed_duration_since(timestamp).num_seconds() <= WINDOW_SECS)
            .unwrap_or(false)
    });

    state.starts.push(now.to_rfc3339());

    if state.starts.len() <= MAX_STARTS {
        return None;
    }

    let extra = state.starts.len().saturating_sub(MAX_STARTS) as u64;
    let backoff = BACKOFF_STEP_SECS.saturating_mul(extra);
    Some(cmp::min(backoff, BACKOFF_MAX_SECS))
}

fn parse_timestamp(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn load_state(path: &Path) -> Result<BackoffState, String> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Ok(BackoffState::default())
        }
        Err(err) => return Err(format!("Failed to read backoff state: {}", err)),
    };

    serde_json::from_slice(&data).map_err(|err| format!("Failed to parse backoff state: {}", err))
}

fn save_state(path: &Path, state: &BackoffState) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Failed to create daemon backoff dir: {}", err))?;
    }

    let payload = serde_json::to_vec_pretty(state)
        .map_err(|err| format!("Failed to serialize backoff state: {}", err))?;
    let tmp_path = path.with_extension("tmp");
    fs::write(&tmp_path, payload)
        .map_err(|err| format!("Failed to write backoff state: {}", err))?;
    fs::rename(&tmp_path, path)
        .map_err(|err| format!("Failed to commit backoff state: {}", err))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn compute_backoff_after_threshold() {
        let now = Utc::now();
        let mut state = BackoffState {
            starts: vec![
                (now - Duration::seconds(10)).to_rfc3339(),
                (now - Duration::seconds(20)).to_rfc3339(),
                (now - Duration::seconds(30)).to_rfc3339(),
            ],
        };

        let backoff = compute_backoff(now, &mut state);
        assert_eq!(backoff, Some(BACKOFF_STEP_SECS));
    }

    #[test]
    fn compute_backoff_resets_when_window_expires() {
        let now = Utc::now();
        let mut state = BackoffState {
            starts: vec![
                (now - Duration::seconds(WINDOW_SECS + 10)).to_rfc3339(),
                (now - Duration::seconds(WINDOW_SECS + 20)).to_rfc3339(),
            ],
        };

        let backoff = compute_backoff(now, &mut state);
        assert_eq!(backoff, None);
        assert_eq!(state.starts.len(), 1);
    }
}
