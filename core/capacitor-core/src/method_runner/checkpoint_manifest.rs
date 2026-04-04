//! Checkpoint manifest generator.
//!
//! Produces JSON manifests compatible with the Swift UI's
//! `DelegationReviewManifest` format, bridging method runner
//! gates to the app's visual checkpoint experience.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct CheckpointManifest {
    pub version: u32,
    pub milestone_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub artifacts: Vec<ManifestArtifact>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decisions: Option<ManifestDecisions>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub swift_changes: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestArtifact {
    pub label: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artifact_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestDecisions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approve: Option<ManifestDecisionHint>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_changes: Option<ManifestDecisionHint>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestDecisionHint {
    pub label: String,
    pub description: String,
}

impl CheckpointManifest {
    pub fn new(milestone_id: &str) -> Self {
        Self {
            version: 1,
            milestone_id: milestone_id.to_string(),
            summary: None,
            artifacts: Vec::new(),
            decisions: None,
            swift_changes: None,
        }
    }

    pub fn summary(mut self, summary: &str) -> Self {
        self.summary = Some(summary.to_string());
        self
    }

    pub fn artifact(mut self, label: &str, path: &str, artifact_type: &str) -> Self {
        self.artifacts.push(ManifestArtifact {
            label: label.to_string(),
            path: path.to_string(),
            artifact_type: Some(artifact_type.to_string()),
            width: None,
            height: None,
        });
        self
    }

    pub fn decision_hint_approve(mut self, label: &str, description: &str) -> Self {
        let hints = self.decisions.get_or_insert(ManifestDecisions {
            approve: None,
            request_changes: None,
        });
        hints.approve = Some(ManifestDecisionHint {
            label: label.to_string(),
            description: description.to_string(),
        });
        self
    }

    pub fn decision_hint_request_changes(mut self, label: &str, description: &str) -> Self {
        let hints = self.decisions.get_or_insert(ManifestDecisions {
            approve: None,
            request_changes: None,
        });
        hints.request_changes = Some(ManifestDecisionHint {
            label: label.to_string(),
            description: description.to_string(),
        });
        self
    }

    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Write the manifest to `{relay_root}/adapter/review-manifest.json`.
    pub fn write_to(&self, relay_root: &std::path::Path) -> std::io::Result<()> {
        self.write_to_path(&relay_root.join("adapter").join("review-manifest.json"))
    }

    /// Write the manifest directly to the provided file path.
    pub(crate) fn write_to_path(&self, path: &std::path::Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = self
            .to_json_pretty()
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        std::fs::write(path, json)
    }
}
