use chrono::{DateTime, Utc};
use std::cmp::Ordering;
use std::collections::HashMap;

use crate::domain::normalize_path_for_matching;
use crate::runtime_types::ParentApp;

use super::ShellEntryFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PathMatch {
    Exact,
    Child,
    Parent,
}

impl PathMatch {
    pub(crate) fn rank(self) -> u8 {
        match self {
            Self::Exact => 2,
            Self::Child => 1,
            Self::Parent => 0,
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Exact => "exact",
            Self::Child => "child",
            Self::Parent => "parent",
        }
    }
}

pub(crate) const POLICY_TABLE: [&str; 6] = [
    "live shells beat dead shells",
    "path specificity: exact > child > parent",
    "tmux preference (only when attached and path specificity ties)",
    "known parent app beats unknown parent app",
    "most recent timestamp wins (invalid timestamps lose)",
    "higher PID breaks ties deterministically",
];

#[derive(Clone)]
pub(crate) struct Candidate<'a> {
    pub(crate) pid: u32,
    pub(crate) shell: &'a ShellEntryFfi,
    pub(crate) is_live: bool,
    pub(crate) has_tmux: bool,
    pub(crate) has_known_parent: bool,
    pub(crate) match_type: PathMatch,
    pub(crate) timestamp: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct SelectionPolicy {
    pub(crate) prefer_tmux: bool,
}

impl SelectionPolicy {
    pub(crate) fn policy_order(&self) -> Vec<String> {
        let mut rows = POLICY_TABLE
            .iter()
            .map(|row| row.to_string())
            .collect::<Vec<_>>();
        if !self.prefer_tmux {
            rows.push("tmux preference disabled (no attached client)".to_string());
        }
        rows
    }

    pub(crate) fn compare(&self, candidate: &Candidate<'_>, best: &Candidate<'_>) -> Ordering {
        candidate
            .is_live
            .cmp(&best.is_live)
            .then_with(|| candidate.match_type.rank().cmp(&best.match_type.rank()))
            .then_with(|| {
                if self.prefer_tmux && candidate.match_type.rank() == best.match_type.rank() {
                    candidate.has_tmux.cmp(&best.has_tmux)
                } else {
                    Ordering::Equal
                }
            })
            .then_with(|| candidate.has_known_parent.cmp(&best.has_known_parent))
            .then_with(|| compare_timestamp(candidate.timestamp, best.timestamp))
            .then_with(|| candidate.pid.cmp(&best.pid))
    }
}

pub(crate) struct SelectionOutcome<'a> {
    pub(crate) best: Option<Candidate<'a>>,
    pub(crate) candidates: Vec<Candidate<'a>>,
}

pub(crate) fn select_best_shell<'a>(
    shells: &'a HashMap<String, ShellEntryFfi>,
    project_path: &str,
    home_dir: &str,
    policy: &SelectionPolicy,
    emit_trace: bool,
) -> SelectionOutcome<'a> {
    let project_path_normalized = normalize_path_for_matching(project_path);
    let home_dir_normalized = normalize_path_for_matching(home_dir);
    let mut best: Option<Candidate<'a>> = None;
    let mut candidates: Vec<Candidate<'a>> = Vec::new();

    for (pid_str, shell) in shells {
        let shell_path = normalize_path_for_matching(&shell.cwd);
        let Some(match_type) =
            match_type_excluding_home(&shell_path, &project_path_normalized, &home_dir_normalized)
        else {
            continue;
        };

        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        let candidate = Candidate {
            pid,
            shell,
            is_live: shell.is_live,
            has_tmux: shell.tmux_session.is_some(),
            has_known_parent: shell.parent_app != ParentApp::Unknown,
            match_type,
            timestamp: parse_timestamp(&shell.updated_at),
        };

        if emit_trace {
            candidates.push(candidate.clone());
        }

        let replace = match best.as_ref() {
            None => true,
            Some(current_best) => policy.compare(&candidate, current_best) == Ordering::Greater,
        };

        if replace {
            best = Some(candidate);
        }
    }

    if emit_trace {
        candidates.sort_by(|a, b| policy.compare(b, a));
    }

    SelectionOutcome { best, candidates }
}

/// Parse an RFC3339 timestamp string into a DateTime<Utc>.
/// Returns None if parsing fails (malformed timestamp).
fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn compare_timestamp(candidate: Option<DateTime<Utc>>, best: Option<DateTime<Utc>>) -> Ordering {
    match (candidate, best) {
        (Some(c), Some(b)) => c.cmp(&b),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

pub(crate) fn match_type_excluding_home(
    shell_path: &str,
    project_path: &str,
    home_dir: &str,
) -> Option<PathMatch> {
    if shell_path == project_path {
        return Some(PathMatch::Exact);
    }

    // Keep managed worktrees isolated: parent repo shells should not match
    // into /.capacitor/worktrees/<name>, and different managed worktrees should
    // not match each other.
    if !paths_share_managed_worktree(shell_path, project_path) {
        return None;
    }

    let (shorter, longer) = if shell_path.len() < project_path.len() {
        (shell_path, project_path)
    } else {
        (project_path, shell_path)
    };

    // HOME is too broad to be a useful parent - exclude it from parent matching
    if shorter == home_dir {
        return None;
    }

    longer
        .strip_prefix(shorter)
        .is_some_and(|rest| rest.starts_with('/'))
        .then(|| {
            if shorter == project_path {
                PathMatch::Child
            } else {
                PathMatch::Parent
            }
        })
}

const MANAGED_WORKTREES_MARKER: &str = "/.capacitor/worktrees/";

fn paths_share_managed_worktree(a: &str, b: &str) -> bool {
    match (managed_worktree_root(a), managed_worktree_root(b)) {
        (None, None) => true,
        (Some(a_root), Some(b_root)) => a_root == b_root,
        _ => false,
    }
}

fn managed_worktree_root(path: &str) -> Option<&str> {
    let marker_index = path.find(MANAGED_WORKTREES_MARKER)?;
    let root_start = marker_index + MANAGED_WORKTREES_MARKER.len();
    let remainder = &path[root_start..];
    let worktree_name_end = remainder.find('/').unwrap_or(remainder.len());
    if worktree_name_end == 0 {
        return None;
    }

    let root_end = root_start + worktree_name_end;
    Some(&path[..root_end])
}
