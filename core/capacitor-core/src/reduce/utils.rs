use std::cmp::Ordering;

use chrono::{DateTime, Utc};

use crate::domain::normalize_path_for_matching;

use super::STALE_EVENT_GRACE_SECS;

pub(super) fn compare_timestamp_strings(left: &str, right: &str) -> Ordering {
    match (parse_rfc3339(left), parse_rfc3339(right)) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

pub(super) fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

pub(super) fn paths_match(left: &str, right: &str) -> bool {
    let shell_path = normalize_path_for_matching(left);
    let project_path = normalize_path_for_matching(right);

    if shell_path == project_path {
        return true;
    }

    shell_path
        .strip_prefix(project_path.as_str())
        .is_some_and(|rest| rest.starts_with('/'))
}

pub(super) fn is_timestamp_stale(current_updated_at: &str, incoming_recorded_at: &str) -> bool {
    let Some(incoming_time) = parse_rfc3339(incoming_recorded_at) else {
        return false;
    };
    let Some(current_time) = parse_rfc3339(current_updated_at) else {
        return false;
    };

    current_time
        .signed_duration_since(incoming_time)
        .num_seconds()
        > STALE_EVENT_GRACE_SECS
}

pub(super) fn trimmed_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}
