//! Tests for checkpoint manifest generation.

use capacitor_core::method_runner::checkpoint_manifest::CheckpointManifest;

#[test]
fn manifest_serializes_to_review_format() {
    let manifest = CheckpointManifest::new("build-gate")
        .summary("Build phase complete. 3 files changed, all tests pass.")
        .artifact("Implementation diff", "artifacts/implementation.md", "text")
        .artifact("Architecture diagram", "artifacts/arch.png", "screenshot")
        .decision_hint_approve("Ship it", "All acceptance criteria met")
        .decision_hint_request_changes("Needs work", "See review notes");

    let json = manifest.to_json_pretty().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["version"], 1);
    assert_eq!(parsed["milestone_id"], "build-gate");
    assert_eq!(parsed["artifacts"].as_array().unwrap().len(), 2);
    assert!(parsed["decisions"]["approve"]["label"].is_string());
    assert!(parsed["decisions"]["request_changes"]["label"].is_string());
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
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(content["milestone_id"], "test-gate");
}
