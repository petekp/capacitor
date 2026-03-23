mod method_runner;

use std::fs;
use std::path::PathBuf;

use capacitor_core::method_runner::storage::MethodRunPaths;

#[test]
fn method_runner_fixtures_are_readable_from_the_crate_root() {
    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_paths = [
        "../../methods/fixtures/minimal-dispatch.yaml",
        "../../methods/fixtures/pipeline-blocked.yaml",
        "../../methods/fixtures/synthesis-only.yaml",
        "../../methods/fixtures/interactive-only.yaml",
        "../../methods/fixtures/mixed-actions.yaml",
        "../../methods/library/spec-hardening.yaml",
    ];

    for relative_path in fixture_paths {
        let path = crate_root.join(relative_path);
        let content = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        assert!(
            !content.trim().is_empty(),
            "expected fixture {} to contain content",
            path.display()
        );
    }
}

#[test]
fn method_run_paths_match_the_canonical_layout() {
    let paths = MethodRunPaths::new("/tmp/method-run-smoke");

    assert_eq!(
        paths.definition_snapshot(),
        PathBuf::from("/tmp/method-run-smoke/.method/definition.snapshot.yaml")
    );
    assert_eq!(
        paths.events_log(),
        PathBuf::from("/tmp/method-run-smoke/.method/events.ndjson")
    );
    assert_eq!(
        paths.state_json(),
        PathBuf::from("/tmp/method-run-smoke/.method/state.json")
    );
    assert_eq!(
        paths.lock_file(),
        PathBuf::from("/tmp/method-run-smoke/.method/locks/run.lock")
    );
    assert_eq!(
        paths.step_dir("research", "draft"),
        PathBuf::from("/tmp/method-run-smoke/.method/steps/research/draft")
    );
    assert_eq!(
        paths.attempt_dir("research", "draft", 1),
        PathBuf::from("/tmp/method-run-smoke/.method/steps/research/draft/attempts/001")
    );
    assert_eq!(
        paths.worker_relay_root("research", "draft", 1, "primary"),
        PathBuf::from(
            "/tmp/method-run-smoke/.method/steps/research/draft/attempts/001/relay/workers/primary"
        )
    );
    assert_eq!(
        paths.canonical_handoff("research", "draft", 1, "primary"),
        PathBuf::from(
            "/tmp/method-run-smoke/.method/artifacts/handoffs/research--draft--001--primary.md"
        )
    );
    assert_eq!(
        paths.output_record("requirements_doc"),
        PathBuf::from("/tmp/method-run-smoke/.method/artifacts/outputs/requirements_doc.json")
    );
}
