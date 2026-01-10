use serde::{Deserialize, Serialize};

use super::policy::{Candidate, PathMatch, SelectionPolicy};
use super::ParentApp;

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct DecisionTraceFfi {
    pub prefer_tmux: bool,
    pub policy_order: Vec<String>,
    pub candidates: Vec<CandidateTraceFfi>,
    pub selected_pid: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct CandidateTraceFfi {
    pub pid: u32,
    pub cwd: String,
    pub tty: String,
    pub parent_app: ParentApp,
    pub is_live: bool,
    pub has_tmux: bool,
    pub match_type: String,
    pub match_rank: u8,
    pub updated_at: String,
    pub rank_key: Vec<String>,
}

impl DecisionTraceFfi {
    pub(crate) fn from_shell_candidates(
        policy: &SelectionPolicy,
        candidates: &[Candidate<'_>],
        selected_pid: Option<u32>,
    ) -> Self {
        let policy_order = policy.policy_order();
        let candidate_traces = candidates
            .iter()
            .map(|candidate| CandidateTraceFfi::from_candidate(candidate, policy))
            .collect();

        Self {
            prefer_tmux: policy.prefer_tmux,
            policy_order,
            candidates: candidate_traces,
            selected_pid,
        }
    }
}

pub(crate) fn format_decision_trace(trace: &DecisionTraceFfi) -> String {
    let mut lines: Vec<String> = Vec::new();
    let selected = trace
        .selected_pid
        .map(|pid| pid.to_string())
        .unwrap_or_else(|| "nil".to_string());

    lines.push(format!(
        "ActivationTrace preferTmux={} selectedPid={}",
        trace.prefer_tmux, selected
    ));
    lines.push(format!(
        "ActivationTrace policyOrder={}",
        trace.policy_order.join(" | ")
    ));

    for candidate in &trace.candidates {
        lines.push(format!(
            "ActivationTrace candidate pid={} match={} rank={} live={} tmux={} updatedAt={} parent={:?}",
            candidate.pid,
            candidate.match_type,
            candidate.match_rank,
            candidate.is_live,
            candidate.has_tmux,
            candidate.updated_at,
            candidate.parent_app
        ));
        lines.push(format!(
            "ActivationTrace rankKey={}",
            candidate.rank_key.join(", ")
        ));
    }

    lines.join("\n")
}

impl CandidateTraceFfi {
    fn from_candidate(candidate: &Candidate<'_>, policy: &SelectionPolicy) -> Self {
        let match_rank = candidate.match_type.rank();
        let tmux_key = if policy.prefer_tmux {
            if candidate.has_tmux {
                "tmux=1".to_string()
            } else {
                "tmux=0".to_string()
            }
        } else {
            "tmux=ignored".to_string()
        };

        let timestamp_key = format!(
            "updated_at={}",
            candidate
                .timestamp
                .map(|ts| ts.to_rfc3339())
                .unwrap_or_else(|| "invalid".to_string())
        );

        let rank_key = vec![
            format!("live={}", candidate.is_live as u8),
            format!("path_rank={}", match_rank),
            tmux_key,
            timestamp_key,
            format!("pid={}", candidate.pid),
        ];

        Self {
            pid: candidate.pid,
            cwd: candidate.shell.cwd.clone(),
            tty: candidate.shell.tty.clone(),
            parent_app: candidate.shell.parent_app,
            is_live: candidate.is_live,
            has_tmux: candidate.has_tmux,
            match_type: match_label(candidate.match_type),
            match_rank,
            updated_at: candidate.shell.updated_at.clone(),
            rank_key,
        }
    }
}

fn match_label(match_type: PathMatch) -> String {
    match_type.label().to_string()
}
