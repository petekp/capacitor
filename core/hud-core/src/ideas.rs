//! Idea Capture - Markdown-based idea storage and management.
//!
//! This module implements the Idea Capture feature which stores ideas in
//! global storage at `~/.capacitor/projects/{encoded-path}/ideas.md`.
//!
//! ## Design Principles
//!
//! - **Markdown-native**: Ideas are stored in markdown files that Claude can naturally read/edit
//! - **ULID identifiers**: 26-character sortable IDs for stable references
//! - **Graceful degradation**: Missing files are created, missing fields use defaults
//! - **Bidirectional sync**: HUD writes, Claude updates, HUD detects changes via file watcher
//! - **Global storage**: All Capacitor data lives in `~/.capacitor/` for separation of concerns
//! - **User-editable**: Parsing is best-effort to avoid breaking hand-edited markdown

use crate::error::{HudError, Result};
use crate::storage::StorageConfig;
use crate::types::Idea;
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use tempfile::NamedTempFile;

/// Order file structure - just an array of idea IDs in display order
#[derive(Debug, Serialize, Deserialize, Default)]
struct IdeasOrder {
    /// Ordered list of idea IDs (first = top of queue)
    order: Vec<String>,
}

// Version marker for the ideas file format
const IDEAS_FILE_VERSION: &str = "<!-- hud-ideas-v1 -->";

// Default sections structure
const IDEAS_FILE_HEADER: &str = r#"<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

"#;

// ─────────────────────────────────────────────────────────────────────────────
// Safety Helpers (treating external input as hostile)
// ─────────────────────────────────────────────────────────────────────────────

/// Sanitizes a title string to prevent file corruption.
///
/// - Removes newlines and carriage returns (would corrupt markdown structure)
/// - Trims whitespace
/// - Replaces empty strings with "Untitled"
/// - Truncates extremely long titles (>100 chars) to prevent display issues
fn sanitize_title(title: &str) -> String {
    let sanitized = title
        .replace('\n', " ")
        .replace('\r', "")
        .trim()
        .to_string();

    if sanitized.is_empty() {
        return "Untitled".to_string();
    }

    // Truncate if extremely long (use chars() for UTF-8 safety)
    let char_count = sanitized.chars().count();
    if char_count > 100 {
        let truncated: String = sanitized.chars().take(97).collect();
        return format!("{}...", truncated);
    }

    sanitized
}

/// Writes content to a file atomically using temp file + rename.
///
/// This prevents data corruption if the write is interrupted (crash, power loss).
/// The rename operation is atomic on the same filesystem.
fn atomic_write(path: &Path, contents: &str) -> Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));

    let mut tmp = NamedTempFile::new_in(dir).map_err(|e| HudError::Io {
        context: format!("creating temp file in {}", dir.display()),
        source: e,
    })?;

    tmp.write_all(contents.as_bytes())
        .map_err(|e| HudError::Io {
            context: format!("writing temp file for {}", path.display()),
            source: e,
        })?;

    tmp.flush().map_err(|e| HudError::Io {
        context: format!("flushing temp file for {}", path.display()),
        source: e,
    })?;

    tmp.persist(path).map_err(|e| HudError::Io {
        context: format!("persisting temp file to {}", path.display()),
        source: e.error,
    })?;

    Ok(())
}

/// Captures a new idea by appending it to the project's ideas file.
///
/// The idea is appended to the `## 🟣 Untriaged` section with default metadata:
/// - Effort: unknown
/// - Status: open
/// - Triage: pending
/// - Related: None
///
/// Returns the generated ULID for the idea.
pub fn capture_idea(project_path: &str, idea_text: &str) -> Result<String> {
    capture_idea_with_storage(&StorageConfig::default(), project_path, idea_text)
}

pub(crate) fn capture_idea_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_text: &str,
) -> Result<String> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);
    ensure_ideas_file_exists(&ideas_file)?;

    // Generate ULID (26 chars, uppercase, sortable)
    let id = ulid::Ulid::new().to_string();
    let timestamp = Utc::now().to_rfc3339();

    // Use placeholder title - will be replaced async by AI-generated title
    let title = "...";

    // Build idea block
    let idea_block = format!(
        "\n### [#idea-{}] {}\n\
         - **Added:** {}\n\
         - **Effort:** unknown\n\
         - **Status:** open\n\
         - **Triage:** pending\n\
         - **Related:** None\n\
         \n\
         {}\n\
         \n\
         ---\n",
        id, title, timestamp, idea_text
    );

    // Append to Untriaged section
    append_to_untriaged(&ideas_file, &idea_block)?;

    Ok(id)
}

/// Loads all ideas from the project's ideas file.
///
/// Returns an empty vector if the file doesn't exist or has no ideas.
/// Uses graceful defaults for missing metadata fields.
pub fn load_ideas(project_path: &str) -> Result<Vec<Idea>> {
    load_ideas_with_storage(&StorageConfig::default(), project_path)
}

pub(crate) fn load_ideas_with_storage(
    storage: &StorageConfig,
    project_path: &str,
) -> Result<Vec<Idea>> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Ok(Vec::new());
    }

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    parse_ideas_file(&content)
}

/// Updates the status of an idea by ID.
///
/// Finds the idea block by its ULID and updates the `- **Status:** ` line.
pub fn update_idea_status(project_path: &str, idea_id: &str, new_status: &str) -> Result<()> {
    update_idea_status_with_storage(&StorageConfig::default(), project_path, idea_id, new_status)
}

pub(crate) fn update_idea_status_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_id: &str,
    new_status: &str,
) -> Result<()> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Err(HudError::FileNotFound(ideas_file));
    }

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    let updated = update_status_in_content(&content, idea_id, new_status)?;
    atomic_write(&ideas_file, &updated)?;

    Ok(())
}

/// Updates the effort estimate of an idea by ID.
pub fn update_idea_effort(project_path: &str, idea_id: &str, new_effort: &str) -> Result<()> {
    update_idea_effort_with_storage(&StorageConfig::default(), project_path, idea_id, new_effort)
}

pub(crate) fn update_idea_effort_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_id: &str,
    new_effort: &str,
) -> Result<()> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Err(HudError::FileNotFound(ideas_file));
    }

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    let updated = update_effort_in_content(&content, idea_id, new_effort)?;
    atomic_write(&ideas_file, &updated)?;

    Ok(())
}

/// Updates the triage status of an idea by ID.
pub fn update_idea_triage(project_path: &str, idea_id: &str, new_triage: &str) -> Result<()> {
    update_idea_triage_with_storage(&StorageConfig::default(), project_path, idea_id, new_triage)
}

pub(crate) fn update_idea_triage_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_id: &str,
    new_triage: &str,
) -> Result<()> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Err(HudError::FileNotFound(ideas_file));
    }

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    let updated = update_triage_in_content(&content, idea_id, new_triage)?;
    atomic_write(&ideas_file, &updated)?;

    Ok(())
}

/// Updates the title of an idea by ID.
///
/// This is used for async title generation - the idea is initially saved with
/// a placeholder title, then updated once the AI-generated title is ready.
/// The title is sanitized to prevent file corruption from malformed input.
pub fn update_idea_title(project_path: &str, idea_id: &str, new_title: &str) -> Result<()> {
    update_idea_title_with_storage(&StorageConfig::default(), project_path, idea_id, new_title)
}

pub(crate) fn update_idea_title_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_id: &str,
    new_title: &str,
) -> Result<()> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Err(HudError::FileNotFound(ideas_file));
    }

    // Sanitize title (external input from subprocess - treat as hostile)
    let safe_title = sanitize_title(new_title);

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    let updated = update_title_in_content(&content, idea_id, &safe_title)?;
    atomic_write(&ideas_file, &updated)?;

    Ok(())
}

/// Updates the description of an idea by ID.
///
/// This is used for sensemaking - the idea is initially saved with the raw user input,
/// then the description is updated with an AI-generated expansion.
pub fn update_idea_description(
    project_path: &str,
    idea_id: &str,
    new_description: &str,
) -> Result<()> {
    update_idea_description_with_storage(
        &StorageConfig::default(),
        project_path,
        idea_id,
        new_description,
    )
}

pub(crate) fn update_idea_description_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_id: &str,
    new_description: &str,
) -> Result<()> {
    let ideas_file = get_ideas_file_path_with_storage(storage, project_path);

    if !ideas_file.exists() {
        return Err(HudError::FileNotFound(ideas_file));
    }

    let content = fs::read_to_string(&ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;
    let updated = update_description_in_content(&content, idea_id, new_description)?;
    atomic_write(&ideas_file, &updated)?;

    Ok(())
}

/// Saves the display order of ideas for a project.
///
/// The order is stored separately from idea content in `~/.capacitor/projects/{encoded}/ideas-order.json`.
/// This prevents churning the ideas markdown file on every reorder.
///
/// Ideas not in the order list will be appended at the end when loading.
/// IDs in the order list that don't exist will be ignored when loading.
pub fn save_ideas_order(project_path: &str, idea_ids: Vec<String>) -> Result<()> {
    save_ideas_order_with_storage(&StorageConfig::default(), project_path, idea_ids)
}

pub(crate) fn save_ideas_order_with_storage(
    storage: &StorageConfig,
    project_path: &str,
    idea_ids: Vec<String>,
) -> Result<()> {
    let order_file = get_order_file_path_with_storage(storage, project_path);

    // Ensure .claude directory exists
    if let Some(parent) = order_file.parent() {
        fs::create_dir_all(parent).map_err(|e| HudError::Io {
            context: format!("creating directory: {}", parent.display()),
            source: e,
        })?;
    }

    let order = IdeasOrder { order: idea_ids };
    let json = serde_json::to_string_pretty(&order).map_err(|e| HudError::Json {
        context: "serializing ideas order".to_string(),
        source: e,
    })?;

    atomic_write(&order_file, &json)?;
    Ok(())
}

/// Loads the display order of ideas for a project.
///
/// Returns an empty vector if the order file doesn't exist (graceful degradation).
/// The caller should sort ideas by this order, appending any ideas not in the list.
pub fn load_ideas_order(project_path: &str) -> Result<Vec<String>> {
    load_ideas_order_with_storage(&StorageConfig::default(), project_path)
}

pub(crate) fn load_ideas_order_with_storage(
    storage: &StorageConfig,
    project_path: &str,
) -> Result<Vec<String>> {
    let order_file = get_order_file_path_with_storage(storage, project_path);

    if !order_file.exists() {
        return Ok(Vec::new());
    }

    let content = fs::read_to_string(&order_file).map_err(|e| HudError::Io {
        context: format!("reading order file: {}", order_file.display()),
        source: e,
    })?;

    let order: IdeasOrder = serde_json::from_str(&content).map_err(|e| HudError::Json {
        context: "parsing ideas order".to_string(),
        source: e,
    })?;

    Ok(order.order)
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal Helper Functions
// ─────────────────────────────────────────────────────────────────────────────

fn get_ideas_file_path_with_storage(storage: &StorageConfig, project_path: &str) -> PathBuf {
    storage.project_ideas_file(project_path)
}

fn get_order_file_path_with_storage(storage: &StorageConfig, project_path: &str) -> PathBuf {
    storage.project_order_file(project_path)
}

/// Ensures the ideas file exists with proper structure.
fn ensure_ideas_file_exists(ideas_file: &Path) -> Result<()> {
    if ideas_file.exists() {
        return Ok(());
    }

    // Create .claude directory if needed
    if let Some(parent) = ideas_file.parent() {
        fs::create_dir_all(parent).map_err(|e| HudError::Io {
            context: format!("creating directory: {}", parent.display()),
            source: e,
        })?;
    }

    // Initialize file with header (atomic write for safety)
    atomic_write(ideas_file, IDEAS_FILE_HEADER)?;

    Ok(())
}

/// Appends an idea block to the Untriaged section.
fn append_to_untriaged(ideas_file: &Path, idea_block: &str) -> Result<()> {
    let mut content = fs::read_to_string(ideas_file).map_err(|e| HudError::Io {
        context: format!("reading ideas file: {}", ideas_file.display()),
        source: e,
    })?;

    // Find the Untriaged section
    let untriaged_marker = "## 🟣 Untriaged";

    if let Some(pos) = content.find(untriaged_marker) {
        // Find the end of the Untriaged section (next ## heading or EOF)
        let section_start = pos + untriaged_marker.len();
        let rest_of_file = &content[section_start..];

        if let Some(next_section) = rest_of_file.find("\n## ") {
            // Insert before next section
            let insert_pos = section_start + next_section;
            content.insert_str(insert_pos, idea_block);
        } else {
            // Append to end of file
            content.push_str(idea_block);
        }
    } else {
        // No Untriaged section exists, create it
        content.push_str(&format!("\n{}\n{}", untriaged_marker, idea_block));
    }

    atomic_write(ideas_file, &content)?;
    Ok(())
}

/// Parses ideas from markdown content.
///
/// The parser is careful to only parse metadata in the contiguous block
/// immediately following the idea heading. Once a blank line or non-metadata
/// line is encountered, subsequent `- **Key:** value` lines are treated as
/// description content (prevents metadata injection from descriptions).
fn parse_ideas_file(content: &str) -> Result<Vec<Idea>> {
    let mut ideas = Vec::new();

    // Check version marker
    if !content.trim_start().starts_with(IDEAS_FILE_VERSION) {
        // Could add migration logic here in the future
        // For now, just warn and try to parse anyway
    }

    // Regex patterns
    let id_regex = Regex::new(r"### \[#idea-([A-Z0-9]{26})\] (.+)").unwrap();
    let meta_regex = Regex::new(r"- \*\*(.+?):\*\* (.+)").unwrap();

    let mut current_idea: Option<IdeaBuilder> = None;
    let mut description_lines: Vec<String> = Vec::new();
    let mut in_metadata_block = false;

    for line in content.lines() {
        if let Some(caps) = id_regex.captures(line) {
            // Save previous idea if exists
            if let Some(builder) = current_idea.take() {
                let description = description_lines.join("\n").trim().to_string();
                ideas.push(builder.build(description));
                description_lines.clear();
            }

            // Start new idea
            let id = caps.get(1).unwrap().as_str().to_string();
            let title = caps.get(2).unwrap().as_str().to_string();
            current_idea = Some(IdeaBuilder::new(id, title));
            in_metadata_block = true;
        } else if in_metadata_block {
            if let Some(caps) = meta_regex.captures(line) {
                // Parse metadata only while in metadata block
                if let Some(builder) = current_idea.as_mut() {
                    let key = caps.get(1).unwrap().as_str();
                    let value = caps.get(2).unwrap().as_str();
                    builder.set_metadata(key, value);
                }
            } else if line.trim().is_empty() {
                // Blank line ends metadata block, start of description
                in_metadata_block = false;
            } else {
                // Non-metadata, non-blank line ends metadata block
                in_metadata_block = false;
                if !line.trim().starts_with("---") && !line.starts_with("##") {
                    description_lines.push(line.to_string());
                }
            }
        } else if line.trim().starts_with("---") {
            // Delimiter - marks end of idea (saved when next starts or EOF)
        } else if line.starts_with("##") {
            // Section header - skip
        } else if !line.trim().is_empty() && current_idea.is_some() {
            // Description line
            description_lines.push(line.to_string());
        }
    }

    // Save last idea
    if let Some(builder) = current_idea {
        let description = description_lines.join("\n").trim().to_string();
        ideas.push(builder.build(description));
    }

    Ok(ideas)
}

/// Updates a metadata field in an idea block by ID.
///
/// Uses heading-anchored matching to avoid false positives from markers appearing
/// in descriptions (e.g., "related to [#idea-XYZ]" would not trigger a match).
fn update_metadata_in_content(
    content: &str,
    idea_id: &str,
    field_name: &str,
    new_value: &str,
) -> Result<String> {
    let heading_prefix = format!("### [#idea-{}]", idea_id);
    let field_prefix = format!("- **{}:**", field_name);

    let mut found_heading = false;
    let mut in_target_idea = false;
    let mut field_updated = false;
    let mut updated_lines = Vec::new();

    for line in content.lines() {
        if line.starts_with(&heading_prefix) {
            found_heading = true;
            in_target_idea = true;
            updated_lines.push(line.to_string());
        } else if in_target_idea && line.trim().starts_with(&field_prefix) {
            updated_lines.push(format!("- **{}:** {}", field_name, new_value));
            field_updated = true;
            in_target_idea = false;
        } else if in_target_idea && line.trim().starts_with("---") {
            updated_lines.push(line.to_string());
            in_target_idea = false;
        } else if in_target_idea && line.starts_with("### ") {
            in_target_idea = false;
            updated_lines.push(line.to_string());
        } else {
            updated_lines.push(line.to_string());
        }
    }

    if !found_heading {
        return Err(HudError::IdeaNotFound {
            id: idea_id.to_string(),
        });
    }

    if !field_updated {
        return Err(HudError::IdeaFieldNotFound {
            id: idea_id.to_string(),
            field: field_name.to_string(),
        });
    }

    // Preserve trailing newline if original had one
    let mut result = updated_lines.join("\n");
    if content.ends_with('\n') && !result.ends_with('\n') {
        result.push('\n');
    }

    Ok(result)
}

/// Updates the status field in an idea block.
fn update_status_in_content(content: &str, idea_id: &str, new_status: &str) -> Result<String> {
    update_metadata_in_content(content, idea_id, "Status", new_status)
}

/// Updates the effort field in an idea block.
fn update_effort_in_content(content: &str, idea_id: &str, new_effort: &str) -> Result<String> {
    update_metadata_in_content(content, idea_id, "Effort", new_effort)
}

/// Updates the triage field in an idea block.
fn update_triage_in_content(content: &str, idea_id: &str, new_triage: &str) -> Result<String> {
    update_metadata_in_content(content, idea_id, "Triage", new_triage)
}

/// Updates the title in an idea heading by ID.
///
/// Replaces the entire heading line `### [#idea-ID] Old Title` with `### [#idea-ID] New Title`.
/// The title should already be sanitized before calling this function.
fn update_title_in_content(content: &str, idea_id: &str, new_title: &str) -> Result<String> {
    let heading_prefix = format!("### [#idea-{}]", idea_id);
    let mut found = false;
    let mut updated_lines = Vec::new();

    for line in content.lines() {
        if line.starts_with(&heading_prefix) {
            updated_lines.push(format!("### [#idea-{}] {}", idea_id, new_title));
            found = true;
        } else {
            updated_lines.push(line.to_string());
        }
    }

    if !found {
        return Err(HudError::IdeaNotFound {
            id: idea_id.to_string(),
        });
    }

    // Preserve trailing newline if original had one
    let mut result = updated_lines.join("\n");
    if content.ends_with('\n') && !result.ends_with('\n') {
        result.push('\n');
    }

    Ok(result)
}

/// Updates the description content in an idea block by ID.
///
/// Finds the idea by its ULID and replaces the description text (everything
/// after the metadata block until `---` or the next heading).
/// The description is sanitized to prevent file corruption.
fn update_description_in_content(
    content: &str,
    idea_id: &str,
    new_description: &str,
) -> Result<String> {
    let heading_prefix = format!("### [#idea-{}]", idea_id);
    let mut found_heading = false;
    let mut in_target_idea = false;
    let mut in_metadata = false;
    let mut description_replaced = false;
    let mut updated_lines = Vec::new();

    for line in content.lines() {
        if line.starts_with(&heading_prefix) {
            // Found our idea
            found_heading = true;
            in_target_idea = true;
            in_metadata = true;
            updated_lines.push(line.to_string());
        } else if in_target_idea && in_metadata {
            // In metadata block - keep lines until blank line
            updated_lines.push(line.to_string());
            if line.trim().is_empty() {
                // End of metadata, insert new description
                in_metadata = false;
                if !new_description.trim().is_empty() {
                    updated_lines.push(new_description.trim().to_string());
                    updated_lines.push(String::new()); // blank line before ---
                }
                description_replaced = true;
            }
        } else if in_target_idea && !description_replaced {
            // Skip old description lines until we hit --- or next heading
            if line.trim() == "---" || line.starts_with("### ") || line.starts_with("## ") {
                in_target_idea = false;
                updated_lines.push(line.to_string());
            }
            // Otherwise skip the old description line
        } else {
            updated_lines.push(line.to_string());
        }
    }

    if !found_heading {
        return Err(HudError::IdeaNotFound {
            id: idea_id.to_string(),
        });
    }

    // Preserve trailing newline if original had one
    let mut result = updated_lines.join("\n");
    if content.ends_with('\n') && !result.ends_with('\n') {
        result.push('\n');
    }

    Ok(result)
}

// ─────────────────────────────────────────────────────────────────────────────
// Idea Builder (Internal)
// ─────────────────────────────────────────────────────────────────────────────

/// Helper for building ideas while parsing.
struct IdeaBuilder {
    id: String,
    title: String,
    added: Option<String>,
    effort: Option<String>,
    status: Option<String>,
    triage: Option<String>,
    related: Option<String>,
}

impl IdeaBuilder {
    fn new(id: String, title: String) -> Self {
        Self {
            id,
            title,
            added: None,
            effort: None,
            status: None,
            triage: None,
            related: None,
        }
    }

    fn set_metadata(&mut self, key: &str, value: &str) {
        let key_lower = key.to_ascii_lowercase();
        let value_trimmed = value.trim();

        match key_lower.as_str() {
            "added" => self.added = Some(value_trimmed.to_string()),
            "effort" => self.effort = Some(value_trimmed.to_ascii_lowercase()),
            "status" => self.status = Some(value_trimmed.to_ascii_lowercase()),
            "triage" => self.triage = Some(value_trimmed.to_ascii_lowercase()),
            "related" => {
                let val_lower = value_trimmed.to_ascii_lowercase();
                if val_lower == "none" {
                    self.related = None;
                } else {
                    self.related = Some(value_trimmed.to_string());
                }
            }
            _ => {}
        }
    }

    fn build(self, description: String) -> Idea {
        Idea {
            id: self.id,
            title: self.title,
            description,
            added: self.added.unwrap_or_else(|| Utc::now().to_rfc3339()),
            effort: self.effort.unwrap_or_else(|| "unknown".to_string()),
            status: self.status.unwrap_or_else(|| "open".to_string()),
            triage: self.triage.unwrap_or_else(|| "pending".to_string()),
            related: self.related,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_capture_and_load_idea() {
        let temp_dir = TempDir::new().unwrap();
        let project_path = temp_dir.path().to_str().unwrap();

        // Capture an idea
        let id = capture_idea(project_path, "Test idea for feature X").unwrap();
        assert_eq!(id.len(), 26); // ULID length

        // Load ideas
        let ideas = load_ideas(project_path).unwrap();
        assert_eq!(ideas.len(), 1);
        assert_eq!(ideas[0].id, id);
        // Title is initially a placeholder "..." (replaced async by AI-generated title)
        assert_eq!(ideas[0].title, "...");
        assert_eq!(ideas[0].status, "open");
        assert_eq!(ideas[0].triage, "pending");
    }

    #[test]
    fn test_update_idea_status() {
        let temp_dir = TempDir::new().unwrap();
        let project_path = temp_dir.path().to_str().unwrap();

        let id = capture_idea(project_path, "Another test").unwrap();
        update_idea_status(project_path, &id, "in-progress").unwrap();

        let ideas = load_ideas(project_path).unwrap();
        assert_eq!(ideas[0].status, "in-progress");
    }

    #[test]
    fn test_parse_ideas_file() {
        let content = r#"<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

### [#idea-01JQXYZ8K6TQFH2M5NWQR9SV7X] Test idea
- **Added:** 2026-01-14T15:23:42Z
- **Effort:** small
- **Status:** open
- **Triage:** pending
- **Related:** None

This is a test idea with multiple lines
of description text.

---
"#;

        let ideas = parse_ideas_file(content).unwrap();
        assert_eq!(ideas.len(), 1);
        assert_eq!(ideas[0].id, "01JQXYZ8K6TQFH2M5NWQR9SV7X");
        assert_eq!(ideas[0].title, "Test idea");
        assert_eq!(ideas[0].effort, "small");
        assert!(ideas[0].description.contains("multiple lines"));
    }
}
