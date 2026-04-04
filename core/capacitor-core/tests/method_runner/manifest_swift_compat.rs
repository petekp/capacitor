//! Verify manifest JSON matches Swift DelegationReviewManifest decoder expectations.

use capacitor_core::method_runner::checkpoint_manifest::CheckpointManifest;
use std::fs;

#[test]
fn manifest_matches_swift_decoder_expectations() {
    let manifest = CheckpointManifest::new("build-gate")
        .summary("Build complete. 5 files changed.")
        .artifact("Implementation", "artifacts/impl.md", "text")
        .artifact("Screenshot", "artifacts/screen.png", "screenshot")
        .artifact("Architecture", "artifacts/arch.png", "mermaid")
        .decision_hint_approve("Ship it", "All tests pass")
        .decision_hint_request_changes("Needs work", "See issues");

    let json = manifest.to_json_pretty().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Swift decoder expects these exact field names (snake_case):
    assert!(parsed["version"].is_number(), "version must be number");
    assert!(
        parsed["milestone_id"].is_string(),
        "milestone_id must be string"
    );
    assert!(parsed["summary"].is_string(), "summary must be string");

    let artifacts = parsed["artifacts"].as_array().unwrap();
    for artifact in artifacts {
        assert!(artifact["label"].is_string(), "artifact.label required");
        assert!(artifact["path"].is_string(), "artifact.path required");
        // artifact_type is optional but when present must be string
        if !artifact["artifact_type"].is_null() {
            assert!(artifact["artifact_type"].is_string());
        }
    }

    // Decisions use snake_case field names matching Swift CodingKeys
    let decisions = &parsed["decisions"];
    assert!(decisions["approve"]["label"].is_string());
    assert!(decisions["approve"]["description"].is_string());
    assert!(decisions["request_changes"]["label"].is_string());
    assert!(decisions["request_changes"]["description"].is_string());

    // Verify artifact_type values match Swift's ArtifactType enum cases
    let types: Vec<&str> = artifacts
        .iter()
        .filter_map(|a| a["artifact_type"].as_str())
        .collect();
    let valid_types = [
        "text",
        "screenshot",
        "recording",
        "mermaid",
        "mermaid_diagram",
    ];
    for t in &types {
        assert!(valid_types.contains(t), "invalid artifact_type: {}", t);
    }
}

#[test]
fn manifest_writes_to_relay_root() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay");

    let manifest = CheckpointManifest::new("test-gate").summary("Test checkpoint");
    manifest.write_to(&relay_root).unwrap();

    let path = relay_root.join("adapter/review-manifest.json");
    assert!(path.exists(), "manifest file must be written");

    let content: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(content["milestone_id"], "test-gate");
}
