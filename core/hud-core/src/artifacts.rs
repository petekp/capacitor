//! Artifact discovery and parsing for Claude Code plugins.
//!
//! This module handles:
//! - Counting artifacts (skills, commands, agents)
//! - Parsing frontmatter from markdown files
//! - Collecting artifact metadata
//! - Frontmatter parsing is best-effort; missing fields default to empty strings.

use crate::patterns::{
    RE_FRONTMATTER, RE_FRONTMATTER_DESC, RE_FRONTMATTER_NAME, RE_MD_BOLD_ASTERISK,
    RE_MD_BOLD_UNDERSCORE, RE_MD_CODE, RE_MD_HEADING, RE_MD_ITALIC_ASTERISK,
    RE_MD_ITALIC_UNDERSCORE, RE_MD_LINK,
};
use crate::types::Artifact;
use fs_err as fs;
use std::path::Path;
use walkdir::WalkDir;

/// Counts artifacts of a given type in a directory.
///
/// For skills: counts directories containing SKILL.md or skill.md
/// For commands/agents: counts .md files
///
/// Returns u32 for FFI compatibility (usize is platform-dependent).
pub fn count_artifacts_in_dir(dir: &Path, artifact_type: &str) -> u32 {
    if !dir.exists() {
        return 0;
    }

    let count = match artifact_type {
        "skills" => WalkDir::new(dir)
            .min_depth(1)
            .max_depth(1)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_dir())
            .filter(|e| {
                let skill_md = e.path().join("SKILL.md");
                let skill_md_lower = e.path().join("skill.md");
                skill_md.exists() || skill_md_lower.exists()
            })
            .count(),
        "commands" | "agents" => WalkDir::new(dir)
            .min_depth(1)
            .max_depth(1)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "md"))
            .count(),
        _ => 0,
    };
    count as u32
}

/// Counts hooks in a plugin directory.
///
/// Returns u32 for FFI compatibility.
pub fn count_hooks_in_dir(dir: &Path) -> u32 {
    let hooks_json = dir.join("hooks").join("hooks.json");
    if hooks_json.exists() {
        1
    } else {
        0
    }
}

/// Parses YAML frontmatter from markdown content.
///
/// Returns (name, description) tuple if frontmatter exists.
pub fn parse_frontmatter(content: &str) -> Option<(String, String)> {
    let caps = RE_FRONTMATTER.captures(content)?;
    let frontmatter = caps.get(1)?.as_str();

    let name = RE_FRONTMATTER_NAME
        .captures(frontmatter)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    let description = RE_FRONTMATTER_DESC
        .captures(frontmatter)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    Some((name, description))
}

/// Strips markdown formatting from text.
pub fn strip_markdown(text: &str) -> String {
    let mut result = text.to_string();
    result = RE_MD_BOLD_ASTERISK.replace_all(&result, "$1").to_string();
    result = RE_MD_ITALIC_ASTERISK.replace_all(&result, "$1").to_string();
    result = RE_MD_BOLD_UNDERSCORE.replace_all(&result, "$1").to_string();
    result = RE_MD_ITALIC_UNDERSCORE
        .replace_all(&result, "$1")
        .to_string();
    result = RE_MD_CODE.replace_all(&result, "$1").to_string();
    result = RE_MD_HEADING.replace_all(&result, "").to_string();
    result = RE_MD_LINK.replace_all(&result, "$1").to_string();
    result
}

/// Collects all artifacts of a given type from a directory.
pub fn collect_artifacts_from_dir(dir: &Path, artifact_type: &str, source: &str) -> Vec<Artifact> {
    let mut artifacts = Vec::new();

    if !dir.exists() {
        return artifacts;
    }

    match artifact_type {
        "skill" => {
            for entry in WalkDir::new(dir)
                .min_depth(1)
                .max_depth(1)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                if entry.file_type().is_dir() {
                    let skill_md = entry.path().join("SKILL.md");
                    let skill_path = if skill_md.exists() {
                        skill_md
                    } else {
                        let skill_md_lower = entry.path().join("skill.md");
                        if skill_md_lower.exists() {
                            skill_md_lower
                        } else {
                            continue;
                        }
                    };

                    if let Ok(content) = fs::read_to_string(&skill_path) {
                        let (name, description) =
                            parse_frontmatter(&content).unwrap_or_else(|| {
                                (
                                    entry.file_name().to_string_lossy().to_string(),
                                    String::new(),
                                )
                            });
                        artifacts.push(Artifact {
                            artifact_type: "skill".to_string(),
                            name: if name.is_empty() {
                                entry.file_name().to_string_lossy().to_string()
                            } else {
                                name
                            },
                            description,
                            source: source.to_string(),
                            path: skill_path.to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
        "command" | "agent" => {
            for entry in WalkDir::new(dir)
                .min_depth(1)
                .max_depth(1)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                if entry.path().extension().is_some_and(|ext| ext == "md") {
                    if let Ok(content) = fs::read_to_string(entry.path()) {
                        let (name, description) =
                            parse_frontmatter(&content).unwrap_or_else(|| {
                                let file_stem = entry
                                    .path()
                                    .file_stem()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default();
                                (file_stem, String::new())
                            });
                        artifacts.push(Artifact {
                            artifact_type: artifact_type.to_string(),
                            name: if name.is_empty() {
                                entry
                                    .path()
                                    .file_stem()
                                    .map(|s| s.to_string_lossy().to_string())
                                    .unwrap_or_default()
                            } else {
                                name
                            },
                            description,
                            source: source.to_string(),
                            path: entry.path().to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
        _ => {}
    }

    artifacts
}
