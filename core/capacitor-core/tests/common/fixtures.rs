#![allow(dead_code)]

use std::path::PathBuf;

use capacitor_core::method_runner::adapters::FakeInteractiveIO;

pub fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

pub fn method_fixture_path(name: &str) -> PathBuf {
    crate_root().join("../../methods/fixtures").join(name)
}

pub fn method_library_path(name: &str) -> PathBuf {
    crate_root().join("../../methods/library").join(name)
}

pub fn read_method_fixture(name: &str) -> String {
    let path = method_fixture_path(name);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()))
}

pub fn read_method_library_file(name: &str) -> String {
    let path = method_library_path(name);
    std::fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!("failed to read library fixture {}: {error}", path.display())
    })
}

pub fn approved_interactive_io() -> FakeInteractiveIO {
    FakeInteractiveIO::new("approved")
}

pub fn minimal_dispatch_path() -> PathBuf {
    method_fixture_path("minimal-dispatch.yaml")
}

pub fn retry_dispatch_path() -> PathBuf {
    method_fixture_path("retry-dispatch.yaml")
}

pub fn interactive_only_path() -> PathBuf {
    method_fixture_path("interactive-only.yaml")
}

pub fn synthesis_only_path() -> PathBuf {
    method_fixture_path("synthesis-only.yaml")
}

pub fn pipeline_blocked_path() -> PathBuf {
    method_fixture_path("pipeline-blocked.yaml")
}
