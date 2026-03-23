//! Handoff parser and ingestion for the method runner.
//!
//! Parses markdown handoff documents from workers, extracting canonical
//! sections (Files Changed, Tests Run, Verdict, etc.) into structured data.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::method_runner::storage::MethodRunPaths;

// ---------------------------------------------------------------------------
// Canonical heading constants
// ---------------------------------------------------------------------------

pub const FILES_CHANGED: &str = "Files Changed";
pub const TESTS_RUN: &str = "Tests Run";
pub const VERIFICATION: &str = "Verification";
pub const VERDICT: &str = "Verdict";
pub const COMPLETION_CLAIM: &str = "Completion Claim";
pub const ISSUES_FOUND: &str = "Issues Found";
pub const NEXT_STEPS: &str = "Next Steps";

pub const VALID_VERDICTS: &[&str] = &["CLEAN", "ISSUES FOUND"];
pub const VALID_COMPLETION_CLAIMS: &[&str] = &["COMPLETE", "PARTIAL"];

// ---------------------------------------------------------------------------
// Parsed handoff
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedHandoff {
    pub worker_id: String,
    pub verdict: Option<String>,
    pub completion_claim: Option<String>,
    pub files_changed: Option<String>,
    pub tests_run: Option<String>,
    pub verification: Option<String>,
    pub issues_found: Option<String>,
    pub next_steps: Option<String>,
    pub raw_content: String,
    pub parse_warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum HandoffParseError {
    #[error("no canonical headings found in handoff content")]
    NoHeadingsFound,

    #[error("invalid encoding in handoff content")]
    InvalidEncoding,

    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),
}

// ---------------------------------------------------------------------------
// Ingest result
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct IngestResult {
    pub canonical_path: PathBuf,
    pub parsed: ParsedHandoff,
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Parse handoff markdown content into structured sections.
///
/// Splits on "### " markers, extracts canonical sections, and validates
/// verdict/completion claim values. Handles edge cases gracefully:
/// - Missing section -> None + warning
/// - Duplicate heading -> keeps first + warning
/// - No headings at all -> error
/// - Empty section -> Some("") + warning
/// - Invalid verdict/completion claim value -> keeps raw + warning
/// - Extra (unknown) headings -> ignored + warning
pub fn parse_handoff(content: &str, worker_id: &str) -> Result<ParsedHandoff, HandoffParseError> {
    let mut handoff = ParsedHandoff {
        worker_id: worker_id.to_string(),
        verdict: None,
        completion_claim: None,
        files_changed: None,
        tests_run: None,
        verification: None,
        issues_found: None,
        next_steps: None,
        raw_content: content.to_string(),
        parse_warnings: Vec::new(),
    };

    // Split by "### " markers
    let sections = extract_sections(content);

    if sections.is_empty() {
        return Err(HandoffParseError::NoHeadingsFound);
    }

    let canonical_headings = [
        FILES_CHANGED,
        TESTS_RUN,
        VERIFICATION,
        VERDICT,
        COMPLETION_CLAIM,
        ISSUES_FOUND,
        NEXT_STEPS,
    ];

    let mut seen_headings: Vec<String> = Vec::new();

    for (heading, body) in &sections {
        let body_trimmed = body.trim().to_string();

        // Check for duplicates
        if seen_headings.contains(heading) {
            handoff
                .parse_warnings
                .push(format!("duplicate heading '{}', keeping first", heading));
            continue;
        }
        seen_headings.push(heading.clone());

        // Check for unknown headings
        if !canonical_headings.iter().any(|h| h == heading) {
            handoff
                .parse_warnings
                .push(format!("unknown heading '{}', ignoring", heading));
            continue;
        }

        // Empty section warning
        if body_trimmed.is_empty() {
            handoff
                .parse_warnings
                .push(format!("empty section '{}'", heading));
        }

        match heading.as_str() {
            h if h == FILES_CHANGED => handoff.files_changed = Some(body_trimmed),
            h if h == TESTS_RUN => handoff.tests_run = Some(body_trimmed),
            h if h == VERIFICATION => handoff.verification = Some(body_trimmed),
            h if h == VERDICT => {
                if !VALID_VERDICTS.contains(&body_trimmed.as_str()) && !body_trimmed.is_empty() {
                    handoff.parse_warnings.push(format!(
                        "invalid verdict value '{}', keeping raw",
                        body_trimmed
                    ));
                }
                handoff.verdict = Some(body_trimmed);
            }
            h if h == COMPLETION_CLAIM => {
                if !VALID_COMPLETION_CLAIMS.contains(&body_trimmed.as_str())
                    && !body_trimmed.is_empty()
                {
                    handoff.parse_warnings.push(format!(
                        "invalid completion claim value '{}', keeping raw",
                        body_trimmed
                    ));
                }
                handoff.completion_claim = Some(body_trimmed);
            }
            h if h == ISSUES_FOUND => handoff.issues_found = Some(body_trimmed),
            h if h == NEXT_STEPS => handoff.next_steps = Some(body_trimmed),
            _ => {}
        }
    }

    // Warn about missing canonical sections
    for heading in &canonical_headings {
        if !seen_headings.iter().any(|h| h == heading) {
            handoff
                .parse_warnings
                .push(format!("missing section '{}'", heading));
        }
    }

    Ok(handoff)
}

/// Extract heading->body pairs from markdown content split by "### " markers.
fn extract_sections(content: &str) -> Vec<(String, String)> {
    let mut sections = Vec::new();
    let mut current_heading: Option<String> = None;
    let mut current_body = String::new();

    for line in content.lines() {
        if let Some(heading_text) = line.strip_prefix("### ") {
            // Save previous section
            if let Some(heading) = current_heading.take() {
                sections.push((heading, current_body.clone()));
            }
            current_heading = Some(heading_text.trim().to_string());
            current_body.clear();
        } else if current_heading.is_some() {
            if !current_body.is_empty() {
                current_body.push('\n');
            }
            current_body.push_str(line);
        }
    }

    // Save last section
    if let Some(heading) = current_heading {
        sections.push((heading, current_body));
    }

    sections
}

// ---------------------------------------------------------------------------
// Ingestion
// ---------------------------------------------------------------------------

/// Ingest a handoff from a source file:
/// 1. Copy to canonical path
/// 2. Parse content
/// 3. Write parsed JSON to attempt_dir/parsed-handoffs/worker_id.json
pub fn ingest_handoff(
    paths: &MethodRunPaths,
    phase_id: &str,
    step_id: &str,
    attempt: u32,
    worker_id: &str,
    source_path: &Path,
) -> Result<IngestResult, HandoffParseError> {
    let content = std::fs::read_to_string(source_path)?;

    // 1. Copy to canonical path
    let canonical_path = paths.canonical_handoff(phase_id, step_id, attempt, worker_id);
    if let Some(parent) = canonical_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(source_path, &canonical_path)?;

    // 2. Parse
    let parsed = parse_handoff(&content, worker_id)?;

    // 3. Write parsed JSON
    let attempt_dir = paths.attempt_dir(phase_id, step_id, attempt);
    let parsed_dir = attempt_dir.join("parsed-handoffs");
    std::fs::create_dir_all(&parsed_dir)?;
    let parsed_path = parsed_dir.join(format!("{worker_id}.json"));
    let json = serde_json::to_string_pretty(&parsed).map_err(std::io::Error::other)?;
    std::fs::write(&parsed_path, json)?;

    Ok(IngestResult {
        canonical_path,
        parsed,
    })
}
